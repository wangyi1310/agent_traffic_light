import Foundation

public enum ClaudeSessionSignal: Equatable, Sendable {
    case taskStarted(turnID: String)
    case toolStarted(callID: String)
    case toolFinished(callID: String)
    case completed
    case failed
}

public struct ParsedClaudeSessionLine: Equatable, Sendable {
    public let timestamp: String
    public let sessionID: String
    public let signals: [ClaudeSessionSignal]

    public init(timestamp: String, sessionID: String, signals: [ClaudeSessionSignal]) {
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.signals = signals
    }
}

public struct ClaudeSessionLineParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> ParsedClaudeSessionLine? {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let timestamp = object["timestamp"] as? String,
            let sessionID = object["sessionId"] as? String,
            object["isSidechain"] as? Bool != true,
            object["isMeta"] as? Bool != true,
            object["isCompactSummary"] as? Bool != true,
            let recordType = object["type"] as? String,
            let message = object["message"] as? [String: Any]
        else {
            return nil
        }

        let signals: [ClaudeSessionSignal]
        switch recordType {
        case "user":
            signals = parseUser(object: object, message: message)
        case "assistant":
            signals = parseAssistant(object: object, message: message)
        default:
            return nil
        }

        guard !signals.isEmpty else { return nil }
        return ParsedClaudeSessionLine(
            timestamp: timestamp,
            sessionID: sessionID,
            signals: signals
        )
    }

    private func parseUser(
        object: [String: Any],
        message: [String: Any]
    ) -> [ClaudeSessionSignal] {
        guard message["role"] as? String == "user" else { return [] }

        if let content = message["content"] as? [[String: Any]] {
            let results = content.compactMap { block -> ClaudeSessionSignal? in
                guard
                    block["type"] as? String == "tool_result",
                    let callID = block["tool_use_id"] as? String
                else {
                    return nil
                }
                return .toolFinished(callID: callID)
            }
            if !results.isEmpty {
                return results
            }

            guard content.contains(where: isUserContent) else { return [] }
        } else {
            guard message["content"] is String else { return [] }
        }

        guard let turnID = (object["promptId"] as? String) ?? (object["uuid"] as? String) else {
            return []
        }
        return [.taskStarted(turnID: turnID)]
    }

    private func parseAssistant(
        object: [String: Any],
        message: [String: Any]
    ) -> [ClaudeSessionSignal] {
        guard message["role"] as? String == "assistant" else { return [] }

        if object["isApiErrorMessage"] as? Bool == true
            || (object["error"] as? String)?.isEmpty == false {
            return [.failed]
        }

        if let content = message["content"] as? [[String: Any]] {
            let tools = content.compactMap { block -> ClaudeSessionSignal? in
                guard
                    block["type"] as? String == "tool_use",
                    let callID = block["id"] as? String
                else {
                    return nil
                }
                return .toolStarted(callID: callID)
            }
            if !tools.isEmpty {
                return tools
            }
        }

        switch message["stop_reason"] as? String {
        case "end_turn", "refusal", "stop_sequence":
            return [.completed]
        case "max_tokens":
            return [.failed]
        default:
            return []
        }
    }

    private func isUserContent(_ block: [String: Any]) -> Bool {
        switch block["type"] as? String {
        case "text", "image":
            return true
        default:
            return false
        }
    }
}
