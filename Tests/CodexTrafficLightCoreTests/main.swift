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

testTaskStartsThinkingAndCompletesGreen()
testToolCallsKeepExecutingUntilEveryResultArrives()
testErrorHasPriorityOverOtherActiveTasks()
testNewTaskClearsErrorLatch()
testInterruptedTurnReturnsToIdle()
testNonInterruptionAbortLatchesErrorUntilAcknowledged()
testReasoningDoesNotEndAnOutstandingToolCall()

guard failureCount == 0 else {
    fputs("\(failureCount) test assertion(s) failed\n", stderr)
    exit(1)
}

print("CodexTrafficLightCoreTests: all assertions passed")
