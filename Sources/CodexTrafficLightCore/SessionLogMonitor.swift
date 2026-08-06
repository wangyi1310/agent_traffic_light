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

    public func poll() throws -> [MonitoredSessionEvent] {
        let urls = try discoverSessionFiles()
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

    private func discoverSessionFiles() throws -> [URL] {
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

        let datedDirectories = recentDatedDirectories().filter {
            var directoryFlag: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &directoryFlag)
                && directoryFlag.boolValue
        }
        let searchRoots = datedDirectories.isEmpty ? [rootURL] : datedDirectories

        var files: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey]
        for searchRoot in searchRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: searchRoot,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isRegularFile == true {
                    files.append(url.standardizedFileURL)
                }
            }
        }
        return files
    }

    private func recentDatedDirectories(now: Date = Date()) -> [URL] {
        let calendar = Calendar.current
        return [now, calendar.date(byAdding: .day, value: -1, to: now)].compactMap { date in
            guard let date else { return nil }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard
                let year = components.year,
                let month = components.month,
                let day = components.day
            else {
                return nil
            }
            return rootURL
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        }
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
