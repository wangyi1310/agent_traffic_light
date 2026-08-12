import Foundation
import SQLite3

public struct CursorComposerStateParser: Sendable {
    public init() {}

    public func pendingInteractionCallID(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let headers = object["fullConversationHeadersOnly"] as? [[String: Any]]
        else {
            return nil
        }

        for header in headers.reversed() {
            guard
                let grouping = header["grouping"] as? [String: Any],
                grouping["capabilityType"] != nil
            else {
                continue
            }
            let toolCallCase = grouping["toolCallCase"] as? String
            if toolCallCase == "askQuestionToolCall" {
                return grouping["toolCallId"] as? String
            }
            guard
                toolCallCase == "shellToolCall",
                grouping["toolFormerStatus"] as? String == "loading",
                grouping["shellStatus"] as? String == "running"
            else {
                return nil
            }
            return grouping["toolCallId"] as? String
        }
        return nil
    }
}

struct CursorComposerStateReader {
    private let databaseURL: URL
    private let parser = CursorComposerStateParser()

    init(databaseURL: URL) {
        self.databaseURL = databaseURL.standardizedFileURL
    }

    func pendingInteractionCallID(sessionID: String) -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT value FROM cursorDiskKV WHERE key = ? LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let key = "composerData:\(sessionID)"
        guard key.withCString({
            sqlite3_bind_text(statement, 1, $0, -1, SQLITE_TRANSIENT)
        }) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        guard
            let bytes = sqlite3_column_blob(statement, 0),
            sqlite3_column_bytes(statement, 0) > 0
        else {
            return nil
        }
        let data = Data(
            bytes: bytes,
            count: Int(sqlite3_column_bytes(statement, 0))
        )
        return parser.pendingInteractionCallID(from: data)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)
