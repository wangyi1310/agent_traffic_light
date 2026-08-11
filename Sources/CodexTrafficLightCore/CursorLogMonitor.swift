import Foundation

public final class CursorLogMonitor {
    public var onEvents: (([MonitoredSessionEvent]) -> Void)?
    public var onAvailabilityChanged: ((Bool) -> Void)?

    private struct FileCursor {
        var offset: UInt64 = 0
        var incompleteLine = Data()
        var currentSessionID: String?
        var currentTurnID: String?
        var lastActivityDate: Date?
        var outstandingCalls: Set<String> = []
        var isInactive = false
    }

    private struct LocatedEvent {
        let path: String
        let order: Int
        let event: MonitoredSessionEvent
    }

    private let rootURL: URL
    private let stateReader: CursorComposerStateReader?
    private let pollInterval: TimeInterval
    private let inactivityTimeout: TimeInterval
    private let parser = CursorLogLineParser()
    private let queue = DispatchQueue(label: "local.codex.traffic-light.cursor-log-monitor")
    private var timer: DispatchSourceTimer?
    private var cursors: [String: FileCursor] = [:]
    private var activeQuestionCalls: [String: String] = [:]
    private var lastAvailability: Bool?

    public init(
        rootURL: URL,
        stateDatabaseURL: URL? = nil,
        pollInterval: TimeInterval = 1.0,
        inactivityTimeout: TimeInterval = 10 * 60
    ) {
        self.rootURL = rootURL.standardizedFileURL
        stateReader = stateDatabaseURL.map(CursorComposerStateReader.init)
        self.pollInterval = pollInterval
        self.inactivityTimeout = inactivityTimeout
    }

    public func poll(now: Date = Date()) throws -> [MonitoredSessionEvent] {
        let urls = try discoverLogFiles(now: now)
        let currentPaths = Set(urls.map(\.path))
        cursors = cursors.filter { path, cursor in
            currentPaths.contains(path)
                || (cursor.currentTurnID != nil && !cursor.isInactive)
        }

        var locatedEvents: [LocatedEvent] = []
        for url in urls.sorted(by: { $0.path < $1.path }) {
            locatedEvents.append(contentsOf: try readNewEvents(from: url, now: now))
        }
        locatedEvents.append(contentsOf: readQuestionStateEvents(now: now))
        locatedEvents.append(contentsOf: expireInactiveTurns(now: now))
        return locatedEvents.sorted {
            if $0.event.timestamp != $1.event.timestamp {
                return $0.event.timestamp < $1.event.timestamp
            }
            if $0.path != $1.path {
                return $0.path < $1.path
            }
            return $0.order < $1.order
        }.map(\.event)
    }

    private func readQuestionStateEvents(now: Date) -> [LocatedEvent] {
        guard let stateReader else { return [] }
        let sessions = Set(cursors.values.compactMap(\.currentSessionID))
            .union(activeQuestionCalls.keys)
        let timestamp = Self.timestampFormatter.string(from: now)
        var events: [LocatedEvent] = []

        for sessionID in sessions.sorted() {
            let pendingCallID = stateReader.pendingQuestionCallID(sessionID: sessionID)
            let activeCallID = activeQuestionCalls[sessionID]
            if let pendingCallID, pendingCallID != activeCallID {
                if let activeCallID {
                    append(
                        .toolFinished(callID: activeCallID),
                        timestamp: timestamp,
                        sessionID: sessionID,
                        path: "cursor-state",
                        to: &events
                    )
                }
                activeQuestionCalls[sessionID] = pendingCallID
                refreshActivity(
                    sessionID: sessionID,
                    now: now,
                    events: &events
                )
                append(
                    .toolStarted(callID: pendingCallID),
                    timestamp: timestamp,
                    sessionID: sessionID,
                    path: "cursor-state",
                    to: &events
                )
            } else if pendingCallID == nil, let activeCallID {
                activeQuestionCalls.removeValue(forKey: sessionID)
                refreshActivity(
                    sessionID: sessionID,
                    now: now,
                    events: &events
                )
                append(
                    .toolFinished(callID: activeCallID),
                    timestamp: timestamp,
                    sessionID: sessionID,
                    path: "cursor-state",
                    to: &events
                )
            }
        }
        return events
    }

    private func refreshActivity(
        sessionID: String,
        now: Date,
        events: inout [LocatedEvent]
    ) {
        for path in cursors.keys.sorted() {
            guard
                var cursor = cursors[path],
                cursor.currentSessionID == sessionID
            else {
                continue
            }
            cursor.lastActivityDate = now
            if cursor.isInactive, let turnID = cursor.currentTurnID {
                cursor.isInactive = false
                append(
                    .taskStarted(turnID: turnID),
                    timestamp: Self.timestampFormatter.string(from: now),
                    sessionID: sessionID,
                    path: "cursor-state",
                    to: &events
                )
            }
            cursors[path] = cursor
        }
    }

    private func expireInactiveTurns(now: Date) -> [LocatedEvent] {
        var events: [LocatedEvent] = []
        for path in cursors.keys.sorted() {
            guard var cursor = cursors[path] else { continue }
            guard
                let sessionID = cursor.currentSessionID,
                let turnID = cursor.currentTurnID,
                !cursor.isInactive,
                cursor.outstandingCalls.isEmpty,
                activeQuestionCalls[sessionID] == nil,
                let lastActivityDate = cursor.lastActivityDate,
                now.timeIntervalSince(lastActivityDate) >= inactivityTimeout
            else {
                continue
            }

            cursor.isInactive = true
            cursors[path] = cursor
            append(
                .taskAborted(turnID: turnID, reason: "inactive"),
                timestamp: Self.timestampFormatter.string(from: now),
                sessionID: sessionID,
                path: path,
                to: &events
            )
        }
        return events
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    public func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: self.pollInterval)
            timer.setEventHandler { [weak self] in
                self?.pollAndPublish()
            }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func pollAndPublish() {
        do {
            let events = try poll()
            publishAvailability(true)
            if !events.isEmpty {
                onEvents?(events)
            }
        } catch {
            publishAvailability(false)
        }
    }

    private func publishAvailability(_ available: Bool) {
        guard lastAvailability != available else { return }
        lastAvailability = available
        onAvailabilityChanged?(available)
    }

    private func discoverLogFiles(now: Date) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard FileManager.default.isReadableFile(atPath: rootURL.path) else {
            throw CocoaError(.fileReadNoPermission)
        }

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        let cutoff = Calendar.current.startOfDay(for: yesterday)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "Cursor Structured Logs.log" {
            let values = try url.resourceValues(forKeys: keys)
            guard
                values.isRegularFile == true,
                let modificationDate = values.contentModificationDate,
                modificationDate >= cutoff
            else {
                continue
            }
            files.append(url.standardizedFileURL)
        }
        return files
    }

    private func readNewEvents(from url: URL, now: Date) throws -> [LocatedEvent] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        var cursor = cursors[url.path] ?? FileCursor()
        if fileSize < cursor.offset {
            cursor = FileCursor()
        }
        guard fileSize > cursor.offset else {
            cursors[url.path] = cursor
            return []
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: cursor.offset)
        let appendedData = try handle.readToEnd() ?? Data()
        cursor.offset += UInt64(appendedData.count)

        var combined = cursor.incompleteLine
        combined.append(appendedData)
        var lineStart = combined.startIndex
        var events: [LocatedEvent] = []
        for index in combined.indices where combined[index] == 0x0A {
            var line = combined.subdata(in: lineStart..<index)
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty {
                parse(
                    line,
                    path: url.path,
                    now: now,
                    cursor: &cursor,
                    events: &events
                )
            }
            lineStart = combined.index(after: index)
        }
        cursor.incompleteLine = combined.subdata(in: lineStart..<combined.endIndex)
        cursors[url.path] = cursor
        return events
    }

    private func parse(
        _ line: Data,
        path: String,
        now: Date,
        cursor: inout FileCursor,
        events: inout [LocatedEvent]
    ) {
        guard let parsed = try? parser.parse(line) else { return }
        cursor.lastActivityDate = Self.timestampFormatter.date(from: parsed.timestamp) ?? now
        if let sessionID = parsed.sessionID {
            cursor.currentSessionID = sessionID
        }
        guard let sessionID = parsed.sessionID ?? cursor.currentSessionID else { return }

        let startsNewTurn: Bool
        if case .taskStarted = parsed.signal {
            startsNewTurn = true
        } else {
            startsNewTurn = false
        }
        if cursor.isInactive, !startsNewTurn, let turnID = cursor.currentTurnID {
            cursor.isInactive = false
            append(
                .taskStarted(turnID: turnID),
                timestamp: parsed.timestamp,
                sessionID: sessionID,
                path: path,
                to: &events
            )
        }

        switch parsed.signal {
        case let .taskStarted(turnID):
            finishOutstandingCalls(
                timestamp: parsed.timestamp,
                sessionID: sessionID,
                path: path,
                cursor: &cursor,
                events: &events
            )
            cursor.currentTurnID = turnID
            cursor.isInactive = false
            append(
                .taskStarted(turnID: turnID),
                timestamp: parsed.timestamp,
                sessionID: sessionID,
                path: path,
                to: &events
            )
        case .reasoning:
            finishOutstandingCalls(
                timestamp: parsed.timestamp,
                sessionID: sessionID,
                path: path,
                cursor: &cursor,
                events: &events
            )
            append(.reasoning, timestamp: parsed.timestamp, sessionID: sessionID, path: path, to: &events)
        case let .toolStarted(callID):
            guard cursor.currentTurnID != nil else { return }
            if cursor.outstandingCalls.insert(callID).inserted {
                append(
                    .toolStarted(callID: callID),
                    timestamp: parsed.timestamp,
                    sessionID: sessionID,
                    path: path,
                    to: &events
                )
            }
        case let .completed(turnID):
            finishOutstandingCalls(
                timestamp: parsed.timestamp,
                sessionID: sessionID,
                path: path,
                cursor: &cursor,
                events: &events
            )
            cursor.currentTurnID = nil
            cursor.isInactive = false
            append(.taskCompleted(turnID: turnID), timestamp: parsed.timestamp, sessionID: sessionID, path: path, to: &events)
        case let .aborted(turnID, reason):
            finishOutstandingCalls(
                timestamp: parsed.timestamp,
                sessionID: sessionID,
                path: path,
                cursor: &cursor,
                events: &events
            )
            cursor.currentTurnID = nil
            cursor.isInactive = false
            append(.taskAborted(turnID: turnID, reason: reason), timestamp: parsed.timestamp, sessionID: sessionID, path: path, to: &events)
        case let .failed(turnID):
            finishOutstandingCalls(
                timestamp: parsed.timestamp,
                sessionID: sessionID,
                path: path,
                cursor: &cursor,
                events: &events
            )
            cursor.currentTurnID = nil
            cursor.isInactive = false
            append(.taskFailed(turnID: turnID), timestamp: parsed.timestamp, sessionID: sessionID, path: path, to: &events)
        }
    }

    private func finishOutstandingCalls(
        timestamp: String,
        sessionID: String,
        path: String,
        cursor: inout FileCursor,
        events: inout [LocatedEvent]
    ) {
        for callID in cursor.outstandingCalls.sorted() {
            append(
                .toolFinished(callID: callID),
                timestamp: timestamp,
                sessionID: sessionID,
                path: path,
                to: &events
            )
        }
        cursor.outstandingCalls.removeAll()
    }

    private func append(
        _ event: SessionEvent,
        timestamp: String,
        sessionID: String,
        path: String,
        to events: inout [LocatedEvent]
    ) {
        events.append(
            LocatedEvent(
                path: path,
                order: events.count,
                event: MonitoredSessionEvent(
                    timestamp: timestamp,
                    sessionID: sessionID,
                    event: event
                )
            )
        )
    }
}
