import Darwin
import Foundation

public final class ClaudeSessionLogMonitor {
    public var onEvents: (([MonitoredSessionEvent]) -> Void)?
    public var onAvailabilityChanged: ((Bool) -> Void)?

    private struct FileCursor {
        var offset: UInt64 = 0
        var incompleteLine = Data()
        var sessionID: String?
        var currentTurnID: String?
        var lastActivityDate: Date?
        var outstandingCalls: Set<String> = []
    }

    private struct LocatedEvent {
        let path: String
        let order: Int
        let event: MonitoredSessionEvent
    }

    private struct RuntimeApproval {
        let path: String
        let timestamp: String
    }

    private let rootURL: URL
    private let runtimeSessionsURL: URL?
    private let pollInterval: TimeInterval
    private let inactivityTimeout: TimeInterval
    private let parser = ClaudeSessionLineParser()
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let queue = DispatchQueue(label: "local.codex.traffic-light.claude-session-monitor")
    private var timer: DispatchSourceTimer?
    private var cursors: [String: FileCursor] = [:]
    private var activeRuntimeApprovals: [String: RuntimeApproval] = [:]
    private var lastAvailability: Bool?

    public init(
        rootURL: URL,
        runtimeSessionsURL: URL? = nil,
        pollInterval: TimeInterval = 0.25,
        inactivityTimeout: TimeInterval = 10 * 60
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.runtimeSessionsURL = runtimeSessionsURL?.standardizedFileURL
        self.pollInterval = pollInterval
        self.inactivityTimeout = inactivityTimeout
    }

    public func poll(now: Date = Date()) throws -> [MonitoredSessionEvent] {
        let urls = try discoverSessionFiles(now: now)
        let currentPaths = Set(urls.map(\.path))
        cursors = cursors.filter { currentPaths.contains($0.key) }

        var locatedEvents: [LocatedEvent] = []
        for url in urls.sorted(by: { $0.path < $1.path }) {
            locatedEvents.append(contentsOf: try readNewEvents(from: url, now: now))
        }
        let runtimeSnapshot = readRuntimeApprovals(now: now)
        locatedEvents.append(contentsOf: runtimeSnapshot.events)
        locatedEvents.append(
            contentsOf: expireInactiveTurns(
                now: now,
                excludingSessionIDs: runtimeSnapshot.waitingSessionIDs
            )
        )

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

    private func discoverSessionFiles(now: Date = Date()) throws -> [URL] {
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

        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let cutoff = calendar.startOfDay(for: yesterday)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard !url.pathComponents.contains("subagents") else { continue }
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
            if line.last == 0x0D {
                line.removeLast()
            }
            if !line.isEmpty {
                parse(line, path: url.path, now: now, cursor: &cursor, events: &events)
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
        cursor.sessionID = parsed.sessionID
        cursor.lastActivityDate = parseTimestamp(parsed.timestamp) ?? now
        for signal in parsed.signals {
            let event: SessionEvent?
            switch signal {
            case let .taskStarted(turnID):
                cursor.currentTurnID = turnID
                cursor.outstandingCalls.removeAll()
                event = .taskStarted(turnID: turnID)
            case let .toolStarted(callID):
                cursor.outstandingCalls.insert(callID)
                event = .toolStarted(callID: callID)
            case let .toolFinished(callID):
                cursor.outstandingCalls.remove(callID)
                event = .toolFinished(callID: callID)
            case .completed:
                guard let turnID = cursor.currentTurnID else { continue }
                cursor.currentTurnID = nil
                cursor.outstandingCalls.removeAll()
                event = .taskCompleted(turnID: turnID)
            case .failed:
                event = .taskFailed(turnID: cursor.currentTurnID)
                cursor.currentTurnID = nil
                cursor.outstandingCalls.removeAll()
            }

            guard let event else { continue }
            events.append(
                LocatedEvent(
                    path: path,
                    order: events.count,
                    event: MonitoredSessionEvent(
                        timestamp: parsed.timestamp,
                        sessionID: parsed.sessionID,
                        event: event
                    )
                )
            )
        }
    }

    private func readRuntimeApprovals(
        now: Date
    ) -> (events: [LocatedEvent], waitingSessionIDs: Set<String>) {
        guard let runtimeSessionsURL else { return ([], []) }

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: runtimeSessionsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var waitingApprovals: [String: RuntimeApproval] = [:]
        var observedTimestamps: [String: String] = [:]

        for url in urls.sorted(by: { $0.path < $1.path }) where url.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: url),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let sessionID = object["sessionId"] as? String,
                let pidNumber = object["pid"] as? NSNumber
            else {
                continue
            }

            let timestamp = runtimeTimestamp(object["updatedAt"], fallback: now)
            observedTimestamps[sessionID] = timestamp
            guard
                isProcessAlive(pid: pidNumber.int32Value),
                object["status"] as? String == "waiting",
                let waitingFor = object["waitingFor"] as? String,
                waitingFor.hasPrefix("approve ")
            else {
                continue
            }

            waitingApprovals[sessionID] = RuntimeApproval(
                path: url.path,
                timestamp: timestamp
            )
        }

        var events: [LocatedEvent] = []
        for sessionID in waitingApprovals.keys.sorted()
        where activeRuntimeApprovals[sessionID] == nil {
            guard let approval = waitingApprovals[sessionID] else { continue }
            events.append(
                runtimeApprovalEvent(
                    path: approval.path,
                    timestamp: approval.timestamp,
                    sessionID: sessionID,
                    event: .toolStarted(callID: "runtime-approval"),
                    order: events.count
                )
            )
        }

        for sessionID in activeRuntimeApprovals.keys.sorted()
        where waitingApprovals[sessionID] == nil {
            guard let approval = activeRuntimeApprovals[sessionID] else { continue }
            events.append(
                runtimeApprovalEvent(
                    path: approval.path,
                    timestamp: observedTimestamps[sessionID]
                        ?? timestampFormatter.string(from: now),
                    sessionID: sessionID,
                    event: .toolFinished(callID: "runtime-approval"),
                    order: events.count
                )
            )
        }

        activeRuntimeApprovals = waitingApprovals
        return (events, Set(waitingApprovals.keys))
    }

    private func runtimeApprovalEvent(
        path: String,
        timestamp: String,
        sessionID: String,
        event: SessionEvent,
        order: Int
    ) -> LocatedEvent {
        LocatedEvent(
            path: path,
            order: order,
            event: MonitoredSessionEvent(
                timestamp: timestamp,
                sessionID: sessionID,
                event: event
            )
        )
    }

    private func runtimeTimestamp(_ value: Any?, fallback: Date) -> String {
        guard let milliseconds = value as? NSNumber else {
            return timestampFormatter.string(from: fallback)
        }
        return timestampFormatter.string(
            from: Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000)
        )
    }

    private func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    private func expireInactiveTurns(
        now: Date,
        excludingSessionIDs: Set<String>
    ) -> [LocatedEvent] {
        var events: [LocatedEvent] = []
        for path in cursors.keys.sorted() {
            guard var cursor = cursors[path] else { continue }
            guard
                let sessionID = cursor.sessionID,
                let turnID = cursor.currentTurnID,
                !excludingSessionIDs.contains(sessionID),
                cursor.outstandingCalls.isEmpty,
                let lastActivityDate = cursor.lastActivityDate,
                now.timeIntervalSince(lastActivityDate) >= inactivityTimeout
            else {
                continue
            }

            cursor.currentTurnID = nil
            cursor.lastActivityDate = nil
            cursors[path] = cursor
            events.append(
                LocatedEvent(
                    path: path,
                    order: events.count,
                    event: MonitoredSessionEvent(
                        timestamp: timestampFormatter.string(from: now),
                        sessionID: sessionID,
                        event: .taskAborted(turnID: turnID, reason: "inactive")
                    )
                )
            )
        }
        return events
    }

    private func parseTimestamp(_ timestamp: String) -> Date? {
        if let date = timestampFormatter.date(from: timestamp) {
            return date
        }
        return ISO8601DateFormatter().date(from: timestamp)
    }
}
