import CodexTrafficLightCore
import Foundation

private var failureCount = 0

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard !condition() else { return }
    failureCount += 1
    fputs("FAIL: \(message) (\(file):\(line))\n", stderr)
}

private func testTaskStartsThinkingAndCompletesGreen() {
    var reducer = SessionStateReducer()

    reducer.apply(.taskStarted(turnID: "turn-1"), sessionID: "session-1")
    expect(reducer.state == .thinking, "a started task should be thinking")

    reducer.apply(.taskCompleted(turnID: "turn-1"), sessionID: "session-1")
    expect(reducer.state == .completed, "a completed task should latch green")
}

private func testToolCallsKeepExecutingUntilEveryResultArrives() {
    var reducer = SessionStateReducer()
    reducer.apply(.taskStarted(turnID: "turn-1"), sessionID: "session-1")

    reducer.apply(.toolStarted(callID: "call-1"), sessionID: "session-1")
    reducer.apply(.toolStarted(callID: "call-2"), sessionID: "session-1")
    expect(reducer.state == .executing, "outstanding calls should execute")

    reducer.apply(.toolFinished(callID: "call-1"), sessionID: "session-1")
    expect(reducer.state == .executing, "one remaining call should keep executing")

    reducer.apply(.toolFinished(callID: "call-2"), sessionID: "session-1")
    expect(reducer.state == .thinking, "all call results should return to thinking")
}

private func testErrorHasPriorityOverOtherActiveTasks() {
    var reducer = SessionStateReducer()
    reducer.apply(.taskStarted(turnID: "turn-a"), sessionID: "session-a")
    reducer.apply(.taskStarted(turnID: "turn-b"), sessionID: "session-b")
    reducer.apply(.toolStarted(callID: "call-b"), sessionID: "session-b")

    reducer.apply(.taskFailed(turnID: "turn-a"), sessionID: "session-a")

    expect(reducer.state == .error, "error should outrank another executing task")
}

private func testNewTaskClearsErrorLatch() {
    var reducer = SessionStateReducer()
    reducer.apply(.taskStarted(turnID: "turn-a"), sessionID: "session-a")
    reducer.apply(.taskFailed(turnID: "turn-a"), sessionID: "session-a")
    expect(reducer.state == .error, "failed task should latch error")

    reducer.apply(.taskStarted(turnID: "turn-b"), sessionID: "session-b")

    expect(reducer.state == .thinking, "new task should clear the prior error")
}

private func testInterruptedTurnReturnsToIdle() {
    var reducer = SessionStateReducer()
    reducer.apply(.taskStarted(turnID: "turn-1"), sessionID: "session-1")

    reducer.apply(
        .taskAborted(turnID: "turn-1", reason: "interrupted"),
        sessionID: "session-1"
    )

    expect(reducer.state == .idle, "user interruption should be idle")
}

private func testNonInterruptionAbortLatchesErrorUntilAcknowledged() {
    var reducer = SessionStateReducer()
    reducer.apply(.taskStarted(turnID: "turn-1"), sessionID: "session-1")
    reducer.apply(
        .taskAborted(turnID: "turn-1", reason: "model_error"),
        sessionID: "session-1"
    )
    expect(reducer.state == .error, "non-interruption abort should be error")

    reducer.acknowledgeError()

    expect(reducer.state == .idle, "acknowledgement should clear error")
}

private func testInactiveTurnReturnsToIdle() {
    var reducer = SessionStateReducer()
    reducer.apply(.taskStarted(turnID: "turn-1"), sessionID: "session-1")

    reducer.apply(
        .taskAborted(turnID: "turn-1", reason: "inactive"),
        sessionID: "session-1"
    )

    expect(reducer.state == .idle, "inactive Claude turn should return to idle")
}

private func testReasoningDoesNotEndAnOutstandingToolCall() {
    var reducer = SessionStateReducer()
    reducer.apply(.taskStarted(turnID: "turn-1"), sessionID: "session-1")
    reducer.apply(.toolStarted(callID: "call-1"), sessionID: "session-1")

    reducer.apply(.reasoning, sessionID: "session-1")

    expect(reducer.state == .executing, "reasoning should not clear a tool call")
}

private func parseLine(_ json: String, with parser: SessionLineParser) -> ParsedSessionLine? {
    do {
        return try parser.parse(Data(json.utf8))
    } catch {
        expect(false, "valid JSON should parse: \(error)")
        return nil
    }
}

private func testParserReadsOnlyMetadataIdentity() {
    let parser = SessionLineParser()
    let json = #"{"timestamp":"2026-08-06T08:00:00Z","type":"session_meta","payload":{"id":"session-1","originator":"Codex Desktop","base_instructions":"ignored private content"}}"#

    let parsed = parseLine(json, with: parser)

    expect(
        parsed == .metadata(
            timestamp: "2026-08-06T08:00:00Z",
            sessionID: "session-1",
            originator: "Codex Desktop"
        ),
        "metadata should contain only timestamp, session ID, and originator"
    )
}

private func testParserMapsTaskAndToolEvents() {
    let parser = SessionLineParser()
    let cases: [(String, ParsedSessionLine)] = [
        (
            #"{"timestamp":"01","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
            .event(timestamp: "01", .taskStarted(turnID: "turn-1"))
        ),
        (
            #"{"timestamp":"02","type":"event_msg","payload":{"type":"agent_reasoning","text":"ignored"}}"#,
            .event(timestamp: "02", .reasoning)
        ),
        (
            #"{"timestamp":"03","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call-1","input":"ignored"}}"#,
            .event(timestamp: "03", .toolStarted(callID: "call-1"))
        ),
        (
            #"{"timestamp":"04","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-1","output":"ignored"}}"#,
            .event(timestamp: "04", .toolFinished(callID: "call-1"))
        ),
        (
            #"{"timestamp":"05","type":"response_item","payload":{"type":"function_call","call_id":"call-2"}}"#,
            .event(timestamp: "05", .toolStarted(callID: "call-2"))
        ),
        (
            #"{"timestamp":"06","type":"response_item","payload":{"type":"function_call_output","call_id":"call-2"}}"#,
            .event(timestamp: "06", .toolFinished(callID: "call-2"))
        ),
        (
            #"{"timestamp":"07","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","last_agent_message":"ignored"}}"#,
            .event(timestamp: "07", .taskCompleted(turnID: "turn-1"))
        ),
        (
            #"{"timestamp":"08","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-2","reason":"interrupted"}}"#,
            .event(timestamp: "08", .taskAborted(turnID: "turn-2", reason: "interrupted"))
        ),
        (
            #"{"timestamp":"09","type":"event_msg","payload":{"type":"task_failed","turn_id":"turn-3"}}"#,
            .event(timestamp: "09", .taskFailed(turnID: "turn-3"))
        ),
    ]

    for (json, expected) in cases {
        expect(parseLine(json, with: parser) == expected, "event should map to \(expected)")
    }
}

private func testParserIgnoresUnknownRecordsAndRejectsMalformedJSON() {
    let parser = SessionLineParser()
    let unknown = #"{"timestamp":"01","type":"event_msg","payload":{"type":"token_count"}}"#
    expect(parseLine(unknown, with: parser) == .ignored, "unknown event should be ignored")

    do {
        _ = try parser.parse(Data("{".utf8))
        expect(false, "malformed JSON should throw")
    } catch {
        // Expected.
    }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-traffic-light-tests-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    } catch {
        expect(false, "temporary-directory test failed: \(error)")
    }
}

private func append(_ string: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(string.utf8))
}

private func testMonitorFiltersOriginatorAndTailsNewEvents() {
    withTemporaryDirectory { root in
        let desktop = root.appendingPathComponent("desktop.jsonl")
        let cli = root.appendingPathComponent("cli.jsonl")
        try (#"{"timestamp":"00","type":"session_meta","payload":{"id":"desktop","originator":"Codex Desktop"}}"# + "\n" +
            #"{"timestamp":"02","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"# + "\n")
            .write(to: desktop, atomically: true, encoding: .utf8)
        try (#"{"timestamp":"00","type":"session_meta","payload":{"id":"cli","originator":"codex_cli_rs"}}"# + "\n" +
            #"{"timestamp":"01","type":"event_msg","payload":{"type":"task_started","turn_id":"ignored"}}"# + "\n")
            .write(to: cli, atomically: true, encoding: .utf8)

        let monitor = SessionLogMonitor(rootURL: root)
        let first = try monitor.poll()
        expect(
            first == [
                MonitoredSessionEvent(
                    timestamp: "02",
                    sessionID: "desktop",
                    event: .taskStarted(turnID: "turn-1")
                ),
            ],
            "only Codex Desktop events should be emitted"
        )

        try append(
            #"{"timestamp":"03","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call-1"}}"# + "\n",
            to: desktop
        )
        let second = try monitor.poll()
        expect(
            second.map(\.event) == [.toolStarted(callID: "call-1")],
            "later bytes should be tailed once"
        )
        let third = try monitor.poll()
        expect(third.isEmpty, "unchanged files should not repeat events")
    }
}

private func testMonitorBuffersPartialLinesAndRecoversAfterMalformedLine() {
    withTemporaryDirectory { root in
        let file = root.appendingPathComponent("session.jsonl")
        let metadata = #"{"timestamp":"00","type":"session_meta","payload":{"id":"desktop","originator":"Codex Desktop"}}"# + "\n"
        let partial = #"{"timestamp":"01","type":"event_msg","payload":{"type":"task_started""#
        try (metadata + partial).write(to: file, atomically: true, encoding: .utf8)

        let monitor = SessionLogMonitor(rootURL: root)
        let incompleteResult = try monitor.poll()
        expect(incompleteResult.isEmpty, "an incomplete line should remain buffered")

        try append(
            #", "turn_id":"turn-1"}}"# + "\n" +
                "{malformed}\n" +
                #"{"timestamp":"02","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call-1"}}"# + "\n",
            to: file
        )
        let completedResult = try monitor.poll()
        expect(
            completedResult.map(\.event) == [
                .taskStarted(turnID: "turn-1"),
                .toolStarted(callID: "call-1"),
            ],
            "completed partial and post-malformed lines should emit"
        )
    }
}

private func testMonitorSortsFilesByTimestampAndRestartsAfterTruncation() {
    withTemporaryDirectory { root in
        let firstFile = root.appendingPathComponent("first.jsonl")
        let secondFile = root.appendingPathComponent("second.jsonl")
        let firstMetadata = #"{"timestamp":"00","type":"session_meta","payload":{"id":"first","originator":"Codex Desktop"}}"# + "\n"
        let secondMetadata = #"{"timestamp":"00","type":"session_meta","payload":{"id":"second","originator":"Codex Desktop"}}"# + "\n"
        try (firstMetadata + #"{"timestamp":"03","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-first-with-a-long-name"}}"# + "\n")
            .write(to: firstFile, atomically: true, encoding: .utf8)
        try (secondMetadata + #"{"timestamp":"02","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-second"}}"# + "\n")
            .write(to: secondFile, atomically: true, encoding: .utf8)

        let monitor = SessionLogMonitor(rootURL: root)
        let initialResult = try monitor.poll()
        expect(
            initialResult.map(\.timestamp) == ["02", "03"],
            "events from files should be sorted chronologically"
        )

        try (firstMetadata + #"{"timestamp":"04","type":"event_msg","payload":{"type":"task_started","turn_id":"new"}}"# + "\n")
            .write(to: firstFile, atomically: true, encoding: .utf8)
        let truncatedResult = try monitor.poll()
        expect(
            truncatedResult.map(\.event) == [.taskStarted(turnID: "new")],
            "a shorter replacement should reset the file cursor"
        )
    }
}

private func testLampFramesMatchEveryTrafficLightState() {
    expect(
        TrafficLightAnimation.litLamps(for: .thinking, phase: 0) == [.red],
        "thinking phase zero should light red"
    )
    expect(
        TrafficLightAnimation.litLamps(for: .thinking, phase: 1) == [.yellow],
        "thinking phase one should light yellow"
    )
    expect(
        TrafficLightAnimation.litLamps(for: .thinking, phase: 2) == [.green],
        "thinking phase two should light green"
    )
    expect(
        TrafficLightAnimation.litLamps(for: .executing, phase: 0).isEmpty,
        "executing even phase should dim yellow"
    )
    expect(
        TrafficLightAnimation.litLamps(for: .executing, phase: 1) == [.yellow],
        "executing odd phase should light yellow"
    )
    expect(
        TrafficLightAnimation.litLamps(for: .completed, phase: 0) == [.green],
        "completed should keep green lit"
    )
    expect(
        TrafficLightAnimation.litLamps(for: .error, phase: 0).isEmpty,
        "error even phase should dim red"
    )
    expect(
        TrafficLightAnimation.litLamps(for: .error, phase: 1) == [.red],
        "error odd phase should light red"
    )
    expect(
        TrafficLightAnimation.litLamps(for: .idle, phase: 0).isEmpty,
        "idle should keep all lamps dim"
    )
}

private func testSourceStatesAggregateByPriority() {
    expect(
        TrafficLightState.aggregate([.completed, .thinking]) == .thinking,
        "thinking should outrank another source's completion"
    )
    expect(
        TrafficLightState.aggregate([.executing, .error]) == .error,
        "error should outrank another source's execution"
    )
    expect(
        TrafficLightState.aggregate([.idle, .completed]) == .completed,
        "completion should outrank idle"
    )
}

private func parseClaudeLine(
    _ json: String,
    with parser: ClaudeSessionLineParser
) -> ParsedClaudeSessionLine? {
    do {
        return try parser.parse(Data(json.utf8))
    } catch {
        expect(false, "valid Claude JSON should parse: \(error)")
        return nil
    }
}

private func testClaudeParserMapsPromptParallelToolsAndCompletion() {
    let parser = ClaudeSessionLineParser()
    let prompt = #"{"type":"user","timestamp":"01","sessionId":"claude-1","uuid":"user-1","promptId":"prompt-1","isSidechain":false,"message":{"role":"user","content":"anonymous prompt"}}"#
    let tools = #"{"type":"assistant","timestamp":"02","sessionId":"claude-1","uuid":"assistant-1","isSidechain":false,"message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"tool-1","name":"Read","input":{}},{"type":"tool_use","id":"tool-2","name":"Bash","input":{}}]}}"#
    let results = #"{"type":"user","timestamp":"03","sessionId":"claude-1","uuid":"user-2","isSidechain":false,"toolUseResult":{},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","is_error":false,"content":"ignored"},{"type":"tool_result","tool_use_id":"tool-2","is_error":true,"content":"ignored"}]}}"#
    let completed = #"{"type":"assistant","timestamp":"04","sessionId":"claude-1","uuid":"assistant-2","isSidechain":false,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"ignored"}]}}"#

    expect(
        parseClaudeLine(prompt, with: parser)?.signals == [.taskStarted(turnID: "prompt-1")],
        "Claude user prompt should start thinking"
    )
    expect(
        parseClaudeLine(tools, with: parser)?.signals == [
            .toolStarted(callID: "tool-1"),
            .toolStarted(callID: "tool-2"),
        ],
        "all parallel Claude tool uses should start"
    )
    expect(
        parseClaudeLine(results, with: parser)?.signals == [
            .toolFinished(callID: "tool-1"),
            .toolFinished(callID: "tool-2"),
        ],
        "tool results, including recoverable failures, should finish calls"
    )
    expect(
        parseClaudeLine(completed, with: parser)?.signals == [.completed],
        "Claude end_turn should complete the task"
    )
}

private func testClaudeParserMapsOnlyTerminalErrorsToFailure() {
    let parser = ClaudeSessionLineParser()
    let transientError = #"{"type":"system","subtype":"api_error","timestamp":"01","sessionId":"claude-1","isSidechain":false,"level":"error","retryAttempt":1}"#
    let finalError = #"{"type":"assistant","timestamp":"02","sessionId":"claude-1","uuid":"assistant-error","isSidechain":false,"isApiErrorMessage":true,"error":"anonymous error","message":{"role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"ignored"}]}}"#
    let maxTokens = #"{"type":"assistant","timestamp":"03","sessionId":"claude-1","uuid":"assistant-max","isSidechain":false,"message":{"role":"assistant","stop_reason":"max_tokens","content":[{"type":"thinking","thinking":"ignored"}]}}"#

    expect(
        parseClaudeLine(transientError, with: parser) == nil,
        "retryable system api_error should not latch red"
    )
    expect(
        parseClaudeLine(finalError, with: parser)?.signals == [.failed],
        "final Claude API error should latch red"
    )
    expect(
        parseClaudeLine(maxTokens, with: parser)?.signals == [.failed],
        "max_tokens termination should latch red"
    )
}

private func testClaudeParserIgnoresMetaAndSidechainRecords() {
    let parser = ClaudeSessionLineParser()
    let sidechain = #"{"type":"user","timestamp":"01","sessionId":"claude-1","uuid":"sidechain","promptId":"prompt-side","isSidechain":true,"message":{"role":"user","content":"ignored"}}"#
    let meta = #"{"type":"user","timestamp":"02","sessionId":"claude-1","uuid":"meta","promptId":"prompt-meta","isSidechain":false,"isMeta":true,"message":{"role":"user","content":"ignored"}}"#
    let compact = #"{"type":"user","timestamp":"03","sessionId":"claude-1","uuid":"compact","promptId":"prompt-compact","isSidechain":false,"isCompactSummary":true,"message":{"role":"user","content":"ignored"}}"#

    expect(parseClaudeLine(sidechain, with: parser) == nil, "sidechain should be ignored")
    expect(parseClaudeLine(meta, with: parser) == nil, "meta user message should be ignored")
    expect(parseClaudeLine(compact, with: parser) == nil, "compact summary should be ignored")
}

private func testClaudeMonitorTailsMainSessionsAndTracksCurrentTurn() {
    withTemporaryDirectory { root in
        let project = root.appendingPathComponent("project", isDirectory: true)
        let subagents = project.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let main = project.appendingPathComponent("claude-1.jsonl")
        let subagent = subagents.appendingPathComponent("agent-1.jsonl")

        let prompt = #"{"type":"user","timestamp":"01","sessionId":"claude-1","uuid":"user-1","promptId":"prompt-1","isSidechain":false,"message":{"role":"user","content":"anonymous prompt"}}"# + "\n"
        let tools = #"{"type":"assistant","timestamp":"02","sessionId":"claude-1","uuid":"assistant-1","isSidechain":false,"message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"tool-1"},{"type":"tool_use","id":"tool-2"}]}}"# + "\n"
        try (prompt + tools).write(to: main, atomically: true, encoding: .utf8)
        try prompt.replacingOccurrences(of: "claude-1", with: "subagent-1")
            .write(to: subagent, atomically: true, encoding: .utf8)

        let monitor = ClaudeSessionLogMonitor(rootURL: root)
        let first = try monitor.poll()
        expect(
            first == [
                MonitoredSessionEvent(
                    timestamp: "01",
                    sessionID: "claude-1",
                    event: .taskStarted(turnID: "prompt-1")
                ),
                MonitoredSessionEvent(
                    timestamp: "02",
                    sessionID: "claude-1",
                    event: .toolStarted(callID: "tool-1")
                ),
                MonitoredSessionEvent(
                    timestamp: "02",
                    sessionID: "claude-1",
                    event: .toolStarted(callID: "tool-2")
                ),
            ],
            "Claude monitor should emit main-session prompt and parallel tools only"
        )

        let results = #"{"type":"user","timestamp":"03","sessionId":"claude-1","uuid":"user-2","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1"},{"type":"tool_result","tool_use_id":"tool-2"}]}}"# + "\n"
        let completed = #"{"type":"assistant","timestamp":"04","sessionId":"claude-1","uuid":"assistant-2","isSidechain":false,"message":{"role":"assistant","stop_reason":"end_turn","content":[]}}"# + "\n"
        try append(results + completed, to: main)

        let second = try monitor.poll()
        expect(
            second.map(\.event) == [
                .toolFinished(callID: "tool-1"),
                .toolFinished(callID: "tool-2"),
                .taskCompleted(turnID: "prompt-1"),
            ],
            "Claude completion should finish tools and the current prompt"
        )
        let third = try monitor.poll()
        expect(third.isEmpty, "unchanged Claude logs should not repeat events")
    }
}

private func testClaudeMonitorMapsTerminalFailureToCurrentTurn() {
    withTemporaryDirectory { root in
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let main = project.appendingPathComponent("claude-error.jsonl")
        let prompt = #"{"type":"user","timestamp":"01","sessionId":"claude-error","uuid":"user-1","promptId":"prompt-error","isSidechain":false,"message":{"role":"user","content":"anonymous prompt"}}"# + "\n"
        let failed = #"{"type":"assistant","timestamp":"02","sessionId":"claude-error","uuid":"assistant-error","isSidechain":false,"isApiErrorMessage":true,"error":"anonymous error","message":{"role":"assistant","stop_reason":"stop_sequence","content":[]}}"# + "\n"
        try (prompt + failed).write(to: main, atomically: true, encoding: .utf8)

        let monitor = ClaudeSessionLogMonitor(rootURL: root)
        let events = try monitor.poll()
        expect(
            events.map(\.event) == [
                .taskStarted(turnID: "prompt-error"),
                .taskFailed(turnID: "prompt-error"),
            ],
            "Claude terminal failure should fail the current prompt"
        )
    }
}

private func testClaudeMonitorExpiresStaleThinkingButNotExecuting() {
    withTemporaryDirectory { root in
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let thinking = project.appendingPathComponent("stale-thinking.jsonl")
        let executing = project.appendingPathComponent("stale-executing.jsonl")
        let oldPrompt = #"{"type":"user","timestamp":"2020-01-01T00:00:00.000Z","sessionId":"stale-thinking","uuid":"user-1","promptId":"prompt-thinking","isSidechain":false,"message":{"role":"user","content":"anonymous prompt"}}"# + "\n"
        let executingPrompt = oldPrompt
            .replacingOccurrences(of: "stale-thinking", with: "stale-executing")
            .replacingOccurrences(of: "prompt-thinking", with: "prompt-executing")
        let tool = #"{"type":"assistant","timestamp":"2020-01-01T00:00:01.000Z","sessionId":"stale-executing","uuid":"assistant-1","isSidechain":false,"message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"tool-1"}]}}"# + "\n"
        try oldPrompt.write(to: thinking, atomically: true, encoding: .utf8)
        try (executingPrompt + tool).write(to: executing, atomically: true, encoding: .utf8)

        let monitor = ClaudeSessionLogMonitor(rootURL: root)
        let events = try monitor.poll()

        expect(
            events.contains(
                MonitoredSessionEvent(
                    timestamp: "2020-01-01T00:00:00.000Z",
                    sessionID: "stale-thinking",
                    event: .taskStarted(turnID: "prompt-thinking")
                )
            ),
            "stale Claude prompt should first be observed"
        )
        expect(
            events.contains(where: {
                $0.sessionID == "stale-thinking"
                    && $0.event == .taskAborted(turnID: "prompt-thinking", reason: "inactive")
            }),
            "stale thinking should expire to idle"
        )
        expect(
            !events.contains(where: {
                $0.sessionID == "stale-executing"
                    && $0.event == .taskAborted(turnID: "prompt-executing", reason: "inactive")
            }),
            "an outstanding Claude tool should not expire"
        )
    }
}

testTaskStartsThinkingAndCompletesGreen()
testToolCallsKeepExecutingUntilEveryResultArrives()
testErrorHasPriorityOverOtherActiveTasks()
testNewTaskClearsErrorLatch()
testInterruptedTurnReturnsToIdle()
testNonInterruptionAbortLatchesErrorUntilAcknowledged()
testInactiveTurnReturnsToIdle()
testReasoningDoesNotEndAnOutstandingToolCall()
testParserReadsOnlyMetadataIdentity()
testParserMapsTaskAndToolEvents()
testParserIgnoresUnknownRecordsAndRejectsMalformedJSON()
testMonitorFiltersOriginatorAndTailsNewEvents()
testMonitorBuffersPartialLinesAndRecoversAfterMalformedLine()
testMonitorSortsFilesByTimestampAndRestartsAfterTruncation()
testLampFramesMatchEveryTrafficLightState()
testSourceStatesAggregateByPriority()
testClaudeParserMapsPromptParallelToolsAndCompletion()
testClaudeParserMapsOnlyTerminalErrorsToFailure()
testClaudeParserIgnoresMetaAndSidechainRecords()
testClaudeMonitorTailsMainSessionsAndTracksCurrentTurn()
testClaudeMonitorMapsTerminalFailureToCurrentTurn()
testClaudeMonitorExpiresStaleThinkingButNotExecuting()

guard failureCount == 0 else {
    fputs("\(failureCount) test assertion(s) failed\n", stderr)
    exit(1)
}

print("CodexTrafficLightCoreTests: all assertions passed")
