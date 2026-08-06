import Foundation

public enum ParsedSessionLine: Equatable, Sendable {
    case metadata(timestamp: String, sessionID: String, originator: String)
    case event(timestamp: String, SessionEvent)
    case ignored
}

public struct SessionLineParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> ParsedSessionLine {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let timestamp = object["timestamp"] as? String,
            let recordType = object["type"] as? String,
            let payload = object["payload"] as? [String: Any]
        else {
            return .ignored
        }

        if recordType == "session_meta" {
            guard
                let sessionID = payload["id"] as? String,
                let originator = payload["originator"] as? String
            else {
                return .ignored
            }
            return .metadata(
                timestamp: timestamp,
                sessionID: sessionID,
                originator: originator
            )
        }

        guard let payloadType = payload["type"] as? String else {
            return .ignored
        }

        switch recordType {
        case "event_msg":
            return parseEventMessage(payloadType, timestamp: timestamp, payload: payload)
        case "response_item":
            return parseResponseItem(payloadType, timestamp: timestamp, payload: payload)
        default:
            return .ignored
        }
    }

    private func parseEventMessage(
        _ type: String,
        timestamp: String,
        payload: [String: Any]
    ) -> ParsedSessionLine {
        switch type {
        case "task_started":
            return eventWithTurnID(timestamp: timestamp, payload: payload) {
                .taskStarted(turnID: $0)
            }
        case "agent_reasoning":
            return .event(timestamp: timestamp, .reasoning)
        case "task_complete":
            return eventWithTurnID(timestamp: timestamp, payload: payload) {
                .taskCompleted(turnID: $0)
            }
        case "turn_aborted":
            guard
                let turnID = payload["turn_id"] as? String,
                let reason = payload["reason"] as? String
            else {
                return .ignored
            }
            return .event(
                timestamp: timestamp,
                .taskAborted(turnID: turnID, reason: reason)
            )
        case "task_failed", "turn_failed", "error":
            return .event(
                timestamp: timestamp,
                .taskFailed(turnID: payload["turn_id"] as? String)
            )
        case "mcp_tool_call_begin", "patch_apply_begin":
            return eventWithCallID(timestamp: timestamp, payload: payload) {
                .toolStarted(callID: $0)
            }
        case "mcp_tool_call_end", "patch_apply_end":
            return eventWithCallID(timestamp: timestamp, payload: payload) {
                .toolFinished(callID: $0)
            }
        default:
            return .ignored
        }
    }

    private func parseResponseItem(
        _ type: String,
        timestamp: String,
        payload: [String: Any]
    ) -> ParsedSessionLine {
        switch type {
        case "custom_tool_call", "function_call":
            return eventWithCallID(timestamp: timestamp, payload: payload) {
                .toolStarted(callID: $0)
            }
        case "custom_tool_call_output", "function_call_output":
            return eventWithCallID(timestamp: timestamp, payload: payload) {
                .toolFinished(callID: $0)
            }
        default:
            return .ignored
        }
    }

    private func eventWithTurnID(
        timestamp: String,
        payload: [String: Any],
        makeEvent: (String) -> SessionEvent
    ) -> ParsedSessionLine {
        guard let turnID = payload["turn_id"] as? String else {
            return .ignored
        }
        return .event(timestamp: timestamp, makeEvent(turnID))
    }

    private func eventWithCallID(
        timestamp: String,
        payload: [String: Any],
        makeEvent: (String) -> SessionEvent
    ) -> ParsedSessionLine {
        guard let callID = payload["call_id"] as? String else {
            return .ignored
        }
        return .event(timestamp: timestamp, makeEvent(callID))
    }
}
