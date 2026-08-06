public struct SessionStateReducer: Sendable {
    private struct TurnKey: Hashable, Sendable {
        let sessionID: String
        let turnID: String
    }

    private struct ActiveTurn: Sendable {
        var outstandingCalls: Set<String> = []
    }

    private var activeTurns: [TurnKey: ActiveTurn] = [:]
    private var currentTurnBySession: [String: TurnKey] = [:]
    private var terminalLatch: TrafficLightState?

    public init() {}

    public var state: TrafficLightState {
        if terminalLatch == .error {
            return .error
        }
        if activeTurns.values.contains(where: { !$0.outstandingCalls.isEmpty }) {
            return .executing
        }
        if !activeTurns.isEmpty {
            return .thinking
        }
        if terminalLatch == .completed {
            return .completed
        }
        return .idle
    }

    public mutating func apply(_ event: SessionEvent, sessionID: String) {
        switch event {
        case let .taskStarted(turnID):
            if let previousTurn = currentTurnBySession[sessionID] {
                activeTurns.removeValue(forKey: previousTurn)
            }
            let key = TurnKey(sessionID: sessionID, turnID: turnID)
            currentTurnBySession[sessionID] = key
            activeTurns[key] = ActiveTurn()
            terminalLatch = nil

        case .reasoning:
            break

        case let .toolStarted(callID):
            guard let key = currentTurnBySession[sessionID] else { return }
            activeTurns[key]?.outstandingCalls.insert(callID)

        case let .toolFinished(callID):
            guard let key = currentTurnBySession[sessionID] else { return }
            activeTurns[key]?.outstandingCalls.remove(callID)

        case let .taskCompleted(turnID):
            removeTurn(sessionID: sessionID, turnID: turnID)
            if terminalLatch != .error {
                terminalLatch = .completed
            }

        case let .taskAborted(turnID, reason):
            removeTurn(sessionID: sessionID, turnID: turnID)
            if reason != "interrupted" {
                terminalLatch = .error
            }

        case let .taskFailed(turnID):
            if let turnID {
                removeTurn(sessionID: sessionID, turnID: turnID)
            } else if let key = currentTurnBySession.removeValue(forKey: sessionID) {
                activeTurns.removeValue(forKey: key)
            }
            terminalLatch = .error
        }
    }

    public mutating func acknowledgeError() {
        if terminalLatch == .error {
            terminalLatch = nil
        }
    }

    private mutating func removeTurn(sessionID: String, turnID: String) {
        let key = TurnKey(sessionID: sessionID, turnID: turnID)
        activeTurns.removeValue(forKey: key)
        if currentTurnBySession[sessionID] == key {
            currentTurnBySession.removeValue(forKey: sessionID)
        }
    }
}
