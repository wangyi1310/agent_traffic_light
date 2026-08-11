import Foundation

public enum CursorLogSignal: Equatable, Sendable {
    case taskStarted(turnID: String)
    case reasoning
    case toolStarted(callID: String)
    case completed(turnID: String)
    case aborted(turnID: String, reason: String)
    case failed(turnID: String?)
}

public struct ParsedCursorLogLine: Equatable, Sendable {
    public let timestamp: String
    public let sessionID: String?
    public let signal: CursorLogSignal

    public init(timestamp: String, sessionID: String?, signal: CursorLogSignal) {
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.signal = signal
    }
}

public struct CursorLogLineParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> ParsedCursorLogLine? {
        guard
            let line = String(data: data, encoding: .utf8),
            let jsonStart = line.firstIndex(of: "{")
        else {
            return nil
        }

        let prefix = line[..<jsonStart]
        guard prefix.count >= 23 else { return nil }
        let timestamp = String(prefix.prefix(23))
        let jsonData = Data(line[jsonStart...].utf8)
        guard
            let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let key = object["key"] as? String,
            let message = object["message"] as? String,
            let metadata = object["metadata"] as? [String: Any]
        else {
            return nil
        }

        let sessionID = string(metadata["composerId"])
            ?? string(metadata["conversation_id"])
        let turnID = string(metadata["requestId"])
            ?? string(metadata["request_id"])

        if key == "composer" {
            switch message {
            case "Chat submission started", "agent.turn.start":
                guard let turnID else { return nil }
                return ParsedCursorLogLine(
                    timestamp: timestamp,
                    sessionID: sessionID,
                    signal: .taskStarted(turnID: turnID)
                )
            case "Starting stream request":
                return ParsedCursorLogLine(
                    timestamp: timestamp,
                    sessionID: sessionID,
                    signal: .reasoning
                )
            case "Capabilities stopped submission at start-submit-chat":
                guard let turnID else { return nil }
                return ParsedCursorLogLine(
                    timestamp: timestamp,
                    sessionID: sessionID,
                    signal: .aborted(turnID: turnID, reason: "interrupted")
                )
            case "agent.turn.outcome":
                guard let turnID else { return nil }
                switch string(metadata["outcome"]) {
                case "success":
                    return ParsedCursorLogLine(
                        timestamp: timestamp,
                        sessionID: sessionID,
                        signal: .completed(turnID: turnID)
                    )
                case "cancelled", "canceled":
                    return ParsedCursorLogLine(
                        timestamp: timestamp,
                        sessionID: sessionID,
                        signal: .aborted(turnID: turnID, reason: "interrupted")
                    )
                default:
                    return ParsedCursorLogLine(
                        timestamp: timestamp,
                        sessionID: sessionID,
                        signal: .failed(turnID: turnID)
                    )
                }
            default:
                return nil
            }
        }

        if key == "agent_exec", message == "Shell stream: approval gate reached",
           let callID = string(metadata["toolCallId"]) {
            return ParsedCursorLogLine(
                timestamp: timestamp,
                sessionID: nil,
                signal: .toolStarted(callID: callID)
            )
        }

        return nil
    }

    private func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
}
