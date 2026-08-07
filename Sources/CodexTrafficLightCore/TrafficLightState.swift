public enum TrafficLightState: Equatable, Sendable {
    case idle
    case thinking
    case executing
    case completed
    case error

    public static func aggregate(_ states: [TrafficLightState]) -> TrafficLightState {
        for state in [TrafficLightState.error, .executing, .thinking, .completed] {
            if states.contains(state) {
                return state
            }
        }
        return .idle
    }
}

public enum SessionEvent: Equatable, Sendable {
    case taskStarted(turnID: String)
    case reasoning
    case toolStarted(callID: String)
    case toolFinished(callID: String)
    case taskCompleted(turnID: String)
    case taskAborted(turnID: String, reason: String)
    case taskFailed(turnID: String?)
}
