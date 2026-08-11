import Foundation

public struct MonitoredSessionEvent: Equatable, Sendable {
    public let timestamp: String
    public let sessionID: String
    public let event: SessionEvent

    public init(timestamp: String, sessionID: String, event: SessionEvent) {
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.event = event
    }
}

public final class SessionLogMonitor {
    public var onEvents: (([MonitoredSessionEvent]) -> Void)?
    public var onAvailabilityChanged: ((Bool) -> Void)?

    private struct FileCursor {
        var offset: UInt64 = 0
        var incompleteLine = Data()
        var sessionID: String?
        var acceptsEvents = false
    }

    private struct LocatedEvent {
        let path: String
        let event: MonitoredSessionEvent
    }

    private let rootURL: URL
    private let pollInterval: TimeInterval
    private let parser = SessionLineParser()
    private let queue = DispatchQueue(label: "local.codex.traffic-light.session-monitor")
    private var timer: DispatchSourceTimer?
    private var cursors: [String: FileCursor] = [:]
    private var lastAvailability: Bool?

    public init(rootURL: URL, pollInterval: TimeInterval = 0.25) {
        self.rootURL = rootURL.standardizedFileURL
        self.pollInterval = pollInterval
    }

    public func poll(now: Date = Date()) throws -> [MonitoredSessionEvent] {
        let urls = try discoverSessionFiles(now: now)
        let currentPaths = Set(urls.map(\.path))
        cursors = cursors.filter { currentPaths.contains($0.key) }

        var locatedEvents: [LocatedEvent] = []
        for url in urls.sorted(by: { $0.path < $1.path }) {
            locatedEvents.append(contentsOf: try readNewEvents(from: url))
        }

        return locatedEvents.sorted {
            if $0.event.timestamp == $1.event.timestamp {
                return $0.path < $1.path
            }
            return $0.event.timestamp < $1.event.timestamp
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

    private func discoverSessionFiles(now: Date) throws -> [URL] {
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
        var files: [URL] = []
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
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

    private func readNewEvents(from url: URL) throws -> [LocatedEvent] {
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
                parse(line, path: url.path, cursor: &cursor, events: &events)
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
        cursor: inout FileCursor,
        events: inout [LocatedEvent]
    ) {
        guard let parsed = try? parser.parse(line) else { return }
        switch parsed {
        case let .metadata(_, sessionID, originator):
            cursor.sessionID = sessionID
            cursor.acceptsEvents = originator == "Codex Desktop"
        case let .event(timestamp, event):
            guard cursor.acceptsEvents, let sessionID = cursor.sessionID else { return }
            events.append(
                LocatedEvent(
                    path: path,
                    event: MonitoredSessionEvent(
                        timestamp: timestamp,
                        sessionID: sessionID,
                        event: event
                    )
                )
            )
        case .ignored:
            break
        }
    }
}
