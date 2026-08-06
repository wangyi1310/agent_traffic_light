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

testTaskStartsThinkingAndCompletesGreen()
testToolCallsKeepExecutingUntilEveryResultArrives()
testErrorHasPriorityOverOtherActiveTasks()
testNewTaskClearsErrorLatch()
testInterruptedTurnReturnsToIdle()
testNonInterruptionAbortLatchesErrorUntilAcknowledged()
testReasoningDoesNotEndAnOutstandingToolCall()
testParserReadsOnlyMetadataIdentity()
testParserMapsTaskAndToolEvents()
testParserIgnoresUnknownRecordsAndRejectsMalformedJSON()
testMonitorFiltersOriginatorAndTailsNewEvents()
testMonitorBuffersPartialLinesAndRecoversAfterMalformedLine()
testMonitorSortsFilesByTimestampAndRestartsAfterTruncation()
testLampFramesMatchEveryTrafficLightState()

guard failureCount == 0 else {
    fputs("\(failureCount) test assertion(s) failed\n", stderr)
    exit(1)
}

print("CodexTrafficLightCoreTests: all assertions passed")
