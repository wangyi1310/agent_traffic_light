import CodexTrafficLightCore
import Foundation
import SQLite3

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

private func testMonitorKeepsTurnSessionAcrossMetadataChanges() {
    withTemporaryDirectory { root in
        let file = root.appendingPathComponent("forked-session.jsonl")
        let contents = #"{"timestamp":"00","type":"session_meta","payload":{"id":"original","originator":"Codex Desktop"}}"# + "\n" +
            #"{"timestamp":"01","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"# + "\n" +
            #"{"timestamp":"02","type":"session_meta","payload":{"id":"host","originator":"Codex Desktop"}}"# + "\n" +
            #"{"timestamp":"03","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"# + "\n"
        try contents.write(to: file, atomically: true, encoding: .utf8)

        let monitor = SessionLogMonitor(rootURL: root)
        let events = try monitor.poll()
        expect(
            events.map(\.sessionID) == ["original", "original"],
            "a terminal event should keep the session that started its turn"
        )

        var reducer = SessionStateReducer()
        for event in events {
            reducer.apply(event.event, sessionID: event.sessionID)
        }
        expect(
            reducer.state == .completed,
            "metadata changes should not leave the original turn active"
        )
    }
}

private func testMonitorIgnoresStaleFilesUntilTheyBecomeActiveAgain() {
    withTemporaryDirectory { root in
        let file = root.appendingPathComponent("stale.jsonl")
        let session = #"{"timestamp":"00","type":"session_meta","payload":{"id":"stale","originator":"Codex Desktop"}}"# + "\n" +
            #"{"timestamp":"01","type":"event_msg","payload":{"type":"task_started","turn_id":"old-turn"}}"# + "\n"
        try session.write(to: file, atomically: true, encoding: .utf8)

        let now = Date()
        let staleDate = Calendar.current.date(byAdding: .day, value: -3, to: now) ?? now
        try FileManager.default.setAttributes(
            [.modificationDate: staleDate],
            ofItemAtPath: file.path
        )

        let monitor = SessionLogMonitor(rootURL: root)
        let staleResult = try monitor.poll(now: now)
        expect(
            staleResult.isEmpty,
            "stale Codex session files should not reactivate historical turns"
        )

        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: file.path
        )
        let activeResult = try monitor.poll(now: now)
        expect(
            activeResult.map(\.event) == [.taskStarted(turnID: "old-turn")],
            "a stale session should be discovered again after new activity"
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

private func testClaudeMonitorMapsRuntimeApprovalToExecuting() {
    withTemporaryDirectory { root in
        let project = root.appendingPathComponent("project", isDirectory: true)
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("approval.jsonl")
        let runtimeSession = runtime.appendingPathComponent("current.json")
        let now = Date()
        let promptTimestamp = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(-60)
        )
        let prompt = """
        {"type":"user","timestamp":"\(promptTimestamp)","sessionId":"approval-session","uuid":"user-1","promptId":"prompt-1","isSidechain":false,"message":{"role":"user","content":"anonymous prompt"}}
        """ + "\n"
        try prompt.write(to: transcript, atomically: true, encoding: .utf8)
        let waiting = """
        {"pid":\(ProcessInfo.processInfo.processIdentifier),"sessionId":"approval-session","status":"waiting","waitingFor":"approve Bash","updatedAt":\(Int(now.timeIntervalSince1970 * 1_000))}
        """
        try waiting.write(to: runtimeSession, atomically: true, encoding: .utf8)

        let monitor = ClaudeSessionLogMonitor(
            rootURL: root,
            runtimeSessionsURL: runtime
        )
        let waitingEvents = try monitor.poll(now: now)
        expect(
            waitingEvents.map(\.event).contains(.toolStarted(callID: "runtime-approval")),
            "Claude approval wait should be executing"
        )
        expect(
            !waitingEvents.map(\.event).contains(
                .taskAborted(turnID: "prompt-1", reason: "inactive")
            ),
            "approval wait should not expire as inactive"
        )

        let resumedAt = now.addingTimeInterval(1)
        let idle = """
        {"pid":\(ProcessInfo.processInfo.processIdentifier),"sessionId":"approval-session","status":"idle","waitingFor":null,"updatedAt":\(Int(resumedAt.timeIntervalSince1970 * 1_000))}
        """
        try idle.write(to: runtimeSession, atomically: true, encoding: .utf8)
        let resumedEvents = try monitor.poll(now: resumedAt)
        expect(
            resumedEvents.map(\.event) == [.toolFinished(callID: "runtime-approval")],
            "leaving approval wait should finish the synthetic tool"
        )
    }
}

private func testClaudeApprovalSuppressesStaleThinkingTimeout() {
    withTemporaryDirectory { root in
        let project = root.appendingPathComponent("project", isDirectory: true)
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("stale-approval.jsonl")
        let runtimeSession = runtime.appendingPathComponent("current.json")
        let oldPrompt = #"{"type":"user","timestamp":"2020-01-01T00:00:00.000Z","sessionId":"stale-approval","uuid":"user-1","promptId":"prompt-1","isSidechain":false,"message":{"role":"user","content":"anonymous prompt"}}"# + "\n"
        try oldPrompt.write(to: transcript, atomically: true, encoding: .utf8)
        let now = Date()
        let waiting = """
        {"pid":\(ProcessInfo.processInfo.processIdentifier),"sessionId":"stale-approval","status":"waiting","waitingFor":"approve Bash","updatedAt":\(Int(now.timeIntervalSince1970 * 1_000))}
        """
        try waiting.write(to: runtimeSession, atomically: true, encoding: .utf8)

        let monitor = ClaudeSessionLogMonitor(
            rootURL: root,
            runtimeSessionsURL: runtime
        )
        let events = try monitor.poll(now: now)
        expect(
            !events.map(\.event).contains(
                .taskAborted(turnID: "prompt-1", reason: "inactive")
            ),
            "a live approval wait should suppress stale thinking timeout"
        )
    }
}

private func testClaudeMonitorResumesInactiveTurnWhenActivityReturns() {
    withTemporaryDirectory { root in
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("resumed.jsonl")
        let oldPrompt = #"{"type":"user","timestamp":"2020-01-01T00:00:00.000Z","sessionId":"resumed-session","uuid":"user-1","promptId":"prompt-1","isSidechain":false,"message":{"role":"user","content":"anonymous prompt"}}"# + "\n"
        try oldPrompt.write(to: transcript, atomically: true, encoding: .utf8)

        let monitor = ClaudeSessionLogMonitor(rootURL: root)
        var reducer = SessionStateReducer()
        for event in try monitor.poll() {
            reducer.apply(event.event, sessionID: event.sessionID)
        }
        expect(reducer.state == .idle, "stale Claude turn should first become idle")

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let tool = """
        {"type":"assistant","timestamp":"\(timestamp)","sessionId":"resumed-session","uuid":"assistant-1","isSidechain":false,"message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"tool-1","name":"Agent"}]}}
        """ + "\n"
        try append(tool, to: transcript)
        let resumedEvents = try monitor.poll()
        for event in resumedEvents {
            reducer.apply(event.event, sessionID: event.sessionID)
        }

        expect(
            resumedEvents.map(\.event).contains(.taskStarted(turnID: "prompt-1")),
            "new Claude activity should restore the inactive turn"
        )
        expect(reducer.state == .executing, "restored Claude tool should show executing")
    }
}

private func testClaudeRuntimeBusyRestoresInactiveTurn() {
    withTemporaryDirectory { root in
        let project = root.appendingPathComponent("project", isDirectory: true)
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("busy.jsonl")
        let runtimeSession = runtime.appendingPathComponent("current.json")
        let oldPrompt = #"{"type":"user","timestamp":"2020-01-01T00:00:00.000Z","sessionId":"busy-session","uuid":"user-1","promptId":"prompt-1","isSidechain":false,"message":{"role":"user","content":"anonymous prompt"}}"# + "\n"
        try oldPrompt.write(to: transcript, atomically: true, encoding: .utf8)

        let monitor = ClaudeSessionLogMonitor(
            rootURL: root,
            runtimeSessionsURL: runtime
        )
        var reducer = SessionStateReducer()
        for event in try monitor.poll() {
            reducer.apply(event.event, sessionID: event.sessionID)
        }
        expect(reducer.state == .idle, "stale runtime test turn should first become idle")

        let now = Date()
        let busy = """
        {"pid":\(ProcessInfo.processInfo.processIdentifier),"sessionId":"busy-session","status":"busy","waitingFor":null,"updatedAt":\(Int(now.timeIntervalSince1970 * 1_000))}
        """
        try busy.write(to: runtimeSession, atomically: true, encoding: .utf8)
        let events = try monitor.poll(now: now)
        for event in events {
            reducer.apply(event.event, sessionID: event.sessionID)
        }

        expect(
            events.map(\.event).contains(.taskStarted(turnID: "prompt-1")),
            "busy Claude runtime should restore an inactive turn"
        )
        expect(reducer.state == .thinking, "busy runtime without a tool should show thinking")
    }
}

private func parseCursorLine(
    _ line: String,
    with parser: CursorLogLineParser
) -> ParsedCursorLogLine? {
    do {
        return try parser.parse(Data(line.utf8))
    } catch {
        expect(false, "valid Cursor log JSON should parse: \(error)")
        return nil
    }
}

private func cursorLogLine(
    _ message: String,
    key: String = "composer",
    metadata: String,
    timestamp: String = "2026-08-11 10:00:00.000"
) -> String {
    "\(timestamp) [info] {\"level\":\"info\",\"key\":\"\(key)\",\"message\":\"\(message)\",\"metadata\":{\(metadata)}}"
}

private func cursorTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter.string(from: date)
}

private func testCursorParserMapsTurnToolAndOutcomes() {
    let parser = CursorLogLineParser()
    let start = cursorLogLine(
        "agent.turn.start",
        metadata: #""conversation_id":"cursor-1","request_id":"turn-1""#
    )
    let tool = cursorLogLine(
        "Shell stream: approval gate reached",
        key: "agent_exec",
        metadata: #""toolCallId":"tool-1","commandLength":"12""#
    )
    let reasoning = cursorLogLine(
        "Starting stream request",
        metadata: #""composerId":"cursor-1","requestId":"turn-1""#
    )
    let success = cursorLogLine(
        "agent.turn.outcome",
        metadata: #""conversation_id":"cursor-1","request_id":"turn-1","outcome":"success""#
    )
    let cancelled = cursorLogLine(
        "agent.turn.outcome",
        metadata: #""conversation_id":"cursor-1","request_id":"turn-2","outcome":"cancelled""#
    )
    let failed = cursorLogLine(
        "agent.turn.outcome",
        metadata: #""conversation_id":"cursor-1","request_id":"turn-3","outcome":"error""#
    )

    expect(
        parseCursorLine(start, with: parser) == ParsedCursorLogLine(
            timestamp: "2026-08-11 10:00:00.000",
            sessionID: "cursor-1",
            signal: .taskStarted(turnID: "turn-1")
        ),
        "Cursor turn start should map to thinking"
    )
    expect(
        parseCursorLine(tool, with: parser)?.signal == .toolStarted(callID: "tool-1"),
        "Cursor shell approval should start tool execution"
    )
    expect(
        parseCursorLine(reasoning, with: parser)?.signal == .reasoning,
        "Cursor stream restart should return to reasoning"
    )
    expect(
        parseCursorLine(success, with: parser)?.signal == .completed(turnID: "turn-1"),
        "Cursor success outcome should complete"
    )
    expect(
        parseCursorLine(cancelled, with: parser)?.signal
            == .aborted(turnID: "turn-2", reason: "interrupted"),
        "Cursor cancellation should become an interruption"
    )
    expect(
        parseCursorLine(failed, with: parser)?.signal == .failed(turnID: "turn-3"),
        "Cursor non-success outcome should fail"
    )
}

private func testCursorParserIgnoresUnrelatedStructuredLogs() {
    let parser = CursorLogLineParser()
    let unrelated = cursorLogLine(
        "Composer state loaded",
        metadata: #""composerId":"cursor-1""#
    )
    expect(
        parseCursorLine(unrelated, with: parser) == nil,
        "unrelated Cursor logs should not affect state"
    )
    let routineStreamCleanup = cursorLogLine(
        "Aborted current chat",
        metadata: #""composerId":"cursor-1","requestId":"turn-1""#
    )
    expect(
        parseCursorLine(routineStreamCleanup, with: parser) == nil,
        "Cursor stream cleanup should wait for the authoritative turn outcome"
    )
    expect(
        parseCursorLine("not structured JSON", with: parser) == nil,
        "plain Cursor logs should be ignored"
    )
}

private func testCursorMonitorTracksExecutionCompletionAndTailing() {
    withTemporaryDirectory { root in
        let window = root.appendingPathComponent("window1/exthost/anysphere.cursor-always-local")
        try FileManager.default.createDirectory(at: window, withIntermediateDirectories: true)
        let log = window.appendingPathComponent("Cursor Structured Logs.log")
        let start = cursorLogLine(
            "Chat submission started",
            metadata: #""composerId":"cursor-1","requestId":"turn-1""#,
            timestamp: "2026-08-11 10:00:00.000"
        )
        let tool = cursorLogLine(
            "Shell stream: approval gate reached",
            key: "agent_exec",
            metadata: #""toolCallId":"tool-1""#,
            timestamp: "2026-08-11 10:00:01.000"
        )
        try (start + "\n" + tool + "\n").write(
            to: log,
            atomically: true,
            encoding: .utf8
        )

        let monitor = CursorLogMonitor(rootURL: root)
        let first = try monitor.poll()
        expect(
            first.map(\.event) == [
                .taskStarted(turnID: "turn-1"),
                .toolStarted(callID: "tool-1"),
            ],
            "Cursor monitor should enter execution for the active window"
        )

        let reasoning = cursorLogLine(
            "Starting stream request",
            metadata: #""composerId":"cursor-1","requestId":"turn-1""#,
            timestamp: "2026-08-11 10:00:02.000"
        )
        let completed = cursorLogLine(
            "agent.turn.outcome",
            metadata: #""conversation_id":"cursor-1","request_id":"turn-1","outcome":"success""#,
            timestamp: "2026-08-11 10:00:03.000"
        )
        try append(reasoning + "\n" + completed + "\n", to: log)

        let second = try monitor.poll()
        expect(
            second.map(\.event) == [
                .toolFinished(callID: "tool-1"),
                .reasoning,
                .taskCompleted(turnID: "turn-1"),
            ],
            "Cursor stream continuation should finish the tool and then complete"
        )
        let third = try monitor.poll()
        expect(third.isEmpty, "unchanged Cursor logs should not repeat events")
    }
}

private func testCursorComposerStateParserFindsPendingInteractions() {
    let parser = CursorComposerStateParser()
    let waiting = #"{"fullConversationHeadersOnly":[{"grouping":{"capabilityType":30}},{"grouping":{"capabilityType":15,"toolFormerTool":51,"toolFormerStatus":"completed","toolCallCase":"askQuestionToolCall","toolCallId":"question-1"}},{"grouping":null}]}"#
    let resumed = #"{"fullConversationHeadersOnly":[{"grouping":{"capabilityType":15,"toolCallCase":"askQuestionToolCall","toolCallId":"question-1"}},{"grouping":{"capabilityType":30}}]}"#
    let shellWaiting = #"{"fullConversationHeadersOnly":[{"grouping":{"capabilityType":15,"toolFormerStatus":"loading","shellStatus":"running","toolCallCase":"shellToolCall","toolCallId":"shell-1"}}]}"#
    let shellCompleted = #"{"fullConversationHeadersOnly":[{"grouping":{"capabilityType":15,"toolFormerStatus":"completed","shellStatus":"success","toolCallCase":"shellToolCall","toolCallId":"shell-1"}}]}"#
    let shellCancelled = #"{"fullConversationHeadersOnly":[{"grouping":{"capabilityType":15,"toolFormerStatus":"cancelled","shellStatus":"running","toolCallCase":"shellToolCall","toolCallId":"shell-1"}}]}"#

    expect(
        parser.pendingInteractionCallID(from: Data(waiting.utf8)) == "question-1",
        "latest Cursor ask-question capability should be pending"
    )
    expect(
        parser.pendingInteractionCallID(from: Data(resumed.utf8)) == nil,
        "new Cursor reasoning after a question should clear waiting"
    )
    expect(
        parser.pendingInteractionCallID(from: Data(shellWaiting.utf8)) == "shell-1",
        "running Cursor shell should include safety approval waits"
    )
    expect(
        parser.pendingInteractionCallID(from: Data(shellCompleted.utf8)) == nil,
        "completed Cursor shell should not remain pending"
    )
    expect(
        parser.pendingInteractionCallID(from: Data(shellCancelled.utf8)) == nil,
        "cancelled Cursor shell should not remain pending"
    )
}

private func writeCursorComposerState(
    databaseURL: URL,
    sessionID: String,
    json: String
) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
        throw CocoaError(.fileWriteUnknown)
    }
    defer { sqlite3_close(database) }
    let escapedJSON = json.replacingOccurrences(of: "'", with: "''")
    let statements = """
    CREATE TABLE IF NOT EXISTS cursorDiskKV (key TEXT UNIQUE, value BLOB);
    INSERT OR REPLACE INTO cursorDiskKV (key, value)
    VALUES ('composerData:\(sessionID)', '\(escapedJSON)');
    """
    guard sqlite3_exec(database, statements, nil, nil, nil) == SQLITE_OK else {
        throw CocoaError(.fileWriteUnknown)
    }
}

private func testCursorMonitorMapsQuestionWaitAndResume() {
    withTemporaryDirectory { root in
        let window = root.appendingPathComponent("window1", isDirectory: true)
        try FileManager.default.createDirectory(at: window, withIntermediateDirectories: true)
        let log = window.appendingPathComponent("Cursor Structured Logs.log")
        let startedAt = Date()
        let start = cursorLogLine(
            "Chat submission started",
            metadata: #""composerId":"cursor-question","requestId":"turn-1""#,
            timestamp: cursorTimestamp(startedAt)
        )
        try (start + "\n").write(to: log, atomically: true, encoding: .utf8)

        let database = root.appendingPathComponent("state.vscdb")
        let waiting = #"{"fullConversationHeadersOnly":[{"grouping":{"capabilityType":15,"toolCallCase":"askQuestionToolCall","toolCallId":"question-1"}}]}"#
        try writeCursorComposerState(
            databaseURL: database,
            sessionID: "cursor-question",
            json: waiting
        )

        let monitor = CursorLogMonitor(
            rootURL: root,
            stateDatabaseURL: database,
            inactivityTimeout: 1
        )
        let waitingEvents = try monitor.poll(now: startedAt)
        expect(
            waitingEvents.map(\.event) == [
                .taskStarted(turnID: "turn-1"),
                .toolStarted(callID: "question-1"),
            ],
            "Cursor question should enter the yellow waiting state"
        )
        let stillWaiting = try monitor.poll(now: startedAt.addingTimeInterval(10))
        expect(
            stillWaiting.isEmpty,
            "pending Cursor question should prevent inactivity expiration"
        )

        let resumed = #"{"fullConversationHeadersOnly":[{"grouping":{"capabilityType":15,"toolCallCase":"askQuestionToolCall","toolCallId":"question-1"}},{"grouping":{"capabilityType":30}}]}"#
        try writeCursorComposerState(
            databaseURL: database,
            sessionID: "cursor-question",
            json: resumed
        )
        let resumedEvents = try monitor.poll(now: startedAt.addingTimeInterval(10))
        expect(
            resumedEvents.map(\.event) == [.toolFinished(callID: "question-1")],
            "Cursor should leave yellow waiting after the user continues"
        )
    }
}

private func testCursorMonitorMapsShellSafetyWaitAndResume() {
    withTemporaryDirectory { root in
        let log = root.appendingPathComponent("Cursor Structured Logs.log")
        let startedAt = Date()
        let start = cursorLogLine(
            "Chat submission started",
            metadata: #""composerId":"cursor-shell","requestId":"turn-1""#,
            timestamp: cursorTimestamp(startedAt)
        )
        try (start + "\n").write(to: log, atomically: true, encoding: .utf8)

        let database = root.appendingPathComponent("state.vscdb")
        let waiting = #"{"fullConversationHeadersOnly":[{"grouping":{"capabilityType":15,"toolFormerStatus":"loading","shellStatus":"running","toolCallCase":"shellToolCall","toolCallId":"shell-1"}}]}"#
        try writeCursorComposerState(
            databaseURL: database,
            sessionID: "cursor-shell",
            json: waiting
        )

        let monitor = CursorLogMonitor(
            rootURL: root,
            stateDatabaseURL: database,
            inactivityTimeout: 1
        )
        let waitingEvents = try monitor.poll(now: startedAt)
        expect(
            waitingEvents.map(\.event) == [
                .taskStarted(turnID: "turn-1"),
                .toolStarted(callID: "shell-1"),
            ],
            "Cursor shell safety approval should enter the yellow waiting state"
        )
        let stillWaiting = try monitor.poll(now: startedAt.addingTimeInterval(10))
        expect(
            stillWaiting.isEmpty,
            "pending Cursor shell approval should prevent inactivity expiration"
        )

        let completed = #"{"fullConversationHeadersOnly":[{"grouping":{"capabilityType":15,"toolFormerStatus":"completed","shellStatus":"success","toolCallCase":"shellToolCall","toolCallId":"shell-1"}}]}"#
        try writeCursorComposerState(
            databaseURL: database,
            sessionID: "cursor-shell",
            json: completed
        )
        let resumedEvents = try monitor.poll(now: startedAt.addingTimeInterval(10))
        expect(
            resumedEvents.map(\.event) == [.toolFinished(callID: "shell-1")],
            "Cursor should leave yellow after shell approval completes"
        )
    }
}

private func testCursorMonitorExpiresTurnWithoutTerminalEvent() {
    withTemporaryDirectory { root in
        let log = root.appendingPathComponent("Cursor Structured Logs.log")
        let startedAt = Date()
        let start = cursorLogLine(
            "Chat submission started",
            metadata: #""composerId":"cursor-stale","requestId":"turn-stale""#,
            timestamp: cursorTimestamp(startedAt)
        )
        try (start + "\n").write(to: log, atomically: true, encoding: .utf8)

        let monitor = CursorLogMonitor(
            rootURL: root,
            inactivityTimeout: 60
        )
        let initial = try monitor.poll(now: startedAt)
        expect(
            initial.map(\.event) == [.taskStarted(turnID: "turn-stale")],
            "Cursor start without a terminal event should begin thinking"
        )

        let beforeTimeout = try monitor.poll(now: startedAt.addingTimeInterval(59))
        expect(beforeTimeout.isEmpty, "Cursor turn should remain active before timeout")

        let expired = try monitor.poll(now: startedAt.addingTimeInterval(61))
        expect(
            expired.map(\.event) == [
                .taskAborted(turnID: "turn-stale", reason: "inactive"),
            ],
            "Cursor turn without a terminal event should expire to idle"
        )

        let resumedAt = startedAt.addingTimeInterval(62)
        let reasoning = cursorLogLine(
            "Starting stream request",
            metadata: #""composerId":"cursor-stale","requestId":"turn-stale""#,
            timestamp: cursorTimestamp(resumedAt)
        )
        try append(reasoning + "\n", to: log)
        let resumed = try monitor.poll(now: resumedAt)
        expect(
            resumed.map(\.event) == [
                .taskStarted(turnID: "turn-stale"),
                .reasoning,
            ],
            "new Cursor activity should restore an inactive turn"
        )
    }
}

private func testCursorMonitorDoesNotExpireOutstandingTool() {
    withTemporaryDirectory { root in
        let log = root.appendingPathComponent("Cursor Structured Logs.log")
        let startedAt = Date()
        let start = cursorLogLine(
            "Chat submission started",
            metadata: #""composerId":"cursor-tool","requestId":"turn-tool""#,
            timestamp: cursorTimestamp(startedAt)
        )
        let tool = cursorLogLine(
            "Shell stream: approval gate reached",
            key: "agent_exec",
            metadata: #""toolCallId":"tool-pending""#,
            timestamp: cursorTimestamp(startedAt)
        )
        try (start + "\n" + tool + "\n").write(
            to: log,
            atomically: true,
            encoding: .utf8
        )

        let monitor = CursorLogMonitor(rootURL: root, inactivityTimeout: 1)
        _ = try monitor.poll(now: startedAt)
        let events = try monitor.poll(now: startedAt.addingTimeInterval(10))
        expect(
            events.isEmpty,
            "outstanding Cursor tool should prevent inactivity expiration"
        )
    }
}

private func testCursorMonitorExpiresTurnAfterLogLeavesScanRange() {
    withTemporaryDirectory { root in
        let log = root.appendingPathComponent("Cursor Structured Logs.log")
        let startedAt = Date()
        let start = cursorLogLine(
            "Chat submission started",
            metadata: #""composerId":"cursor-rotated","requestId":"turn-rotated""#,
            timestamp: cursorTimestamp(startedAt)
        )
        try (start + "\n").write(to: log, atomically: true, encoding: .utf8)

        let monitor = CursorLogMonitor(
            rootURL: root,
            inactivityTimeout: 60
        )
        _ = try monitor.poll(now: startedAt)

        let staleModificationDate = startedAt.addingTimeInterval(-3 * 24 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: staleModificationDate],
            ofItemAtPath: log.path
        )
        let expired = try monitor.poll(now: startedAt.addingTimeInterval(61))
        expect(
            expired.map(\.event) == [
                .taskAborted(turnID: "turn-rotated", reason: "inactive"),
            ],
            "Cursor turn should expire after its log leaves the scan range: \(expired)"
        )

        let repeated = try monitor.poll(now: startedAt.addingTimeInterval(62))
        expect(
            repeated.isEmpty,
            "removed Cursor logs should not repeat inactivity events: \(repeated)"
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
testMonitorKeepsTurnSessionAcrossMetadataChanges()
testMonitorIgnoresStaleFilesUntilTheyBecomeActiveAgain()
testLampFramesMatchEveryTrafficLightState()
testSourceStatesAggregateByPriority()
testClaudeParserMapsPromptParallelToolsAndCompletion()
testClaudeParserMapsOnlyTerminalErrorsToFailure()
testClaudeParserIgnoresMetaAndSidechainRecords()
testClaudeMonitorTailsMainSessionsAndTracksCurrentTurn()
testClaudeMonitorMapsTerminalFailureToCurrentTurn()
testClaudeMonitorExpiresStaleThinkingButNotExecuting()
testClaudeMonitorMapsRuntimeApprovalToExecuting()
testClaudeApprovalSuppressesStaleThinkingTimeout()
testClaudeMonitorResumesInactiveTurnWhenActivityReturns()
testClaudeRuntimeBusyRestoresInactiveTurn()
testCursorParserMapsTurnToolAndOutcomes()
testCursorParserIgnoresUnrelatedStructuredLogs()
testCursorMonitorTracksExecutionCompletionAndTailing()
testCursorComposerStateParserFindsPendingInteractions()
testCursorMonitorMapsQuestionWaitAndResume()
testCursorMonitorMapsShellSafetyWaitAndResume()
testCursorMonitorExpiresTurnWithoutTerminalEvent()
testCursorMonitorDoesNotExpireOutstandingTool()
testCursorMonitorExpiresTurnAfterLogLeavesScanRange()

guard failureCount == 0 else {
    fputs("\(failureCount) test assertion(s) failed\n", stderr)
    exit(1)
}

print("CodexTrafficLightCoreTests: all assertions passed")
