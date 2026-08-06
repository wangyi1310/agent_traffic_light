# Codex Traffic Light Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS menu bar and floating traffic-light app that reflects Codex Desktop thinking, tool execution, completion, and terminal error states.

**Architecture:** A Swift core library parses and incrementally tails recent Codex Desktop JSONL sessions, reduces events into active-turn state plus one terminal latch, and publishes one aggregate traffic-light state. A small AppKit executable renders that state in an `NSStatusItem` and borderless floating `NSPanel`; a shell script assembles the release executable into a standard app bundle.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode, Foundation, AppKit, Swift Package Manager, zero-dependency executable test harness, POSIX shell.

**Execution environment adjustment:** The installed Apple Command Line Tools contains neither `XCTest` nor Swift `Testing`. Core tests are therefore implemented as the zero-dependency `CodexTrafficLightCoreTests` executable in `Tests/CodexTrafficLightCoreTests/main.swift` and run with `swift run CodexTrafficLightCoreTests`; any failed assertion exits nonzero. This supersedes the XCTest filenames and `swift test` commands below without changing their required behaviors.

## Global Constraints

- Support macOS 13 or newer and build without a full Xcode installation.
- Monitor only JSONL sessions whose `session_meta.payload.originator` is exactly `Codex Desktop`.
- Never decode into domain models, render, or persist prompt, response, reasoning, tool-input, or tool-output content.
- Treat user interruption as idle; only a terminal task failure produces the red state.
- Aggregate states in this exact priority: error, executing, thinking, completed, idle.
- Clear a terminal error when a new task starts or the user acknowledges it.
- Keep the first version free of login items, notifications, analytics, themes, configurable animation settings, signing, and notarization.

## File Structure

- `Package.swift`: declares the core library, AppKit executable, and test target.
- `Sources/CodexTrafficLightCore/TrafficLightState.swift`: presentation state and parsed event value types.
- `Sources/CodexTrafficLightCore/SessionStateReducer.swift`: active-turn state machine, terminal latch, and priority aggregation.
- `Sources/CodexTrafficLightCore/SessionLineParser.swift`: narrow JSON-line parser and Codex Desktop originator metadata.
- `Sources/CodexTrafficLightCore/SessionLogMonitor.swift`: per-file cursors, partial-line buffering, recent session discovery, polling, and event delivery.
- `Sources/CodexTrafficLightApp/main.swift`: executable entry point.
- `Sources/CodexTrafficLightApp/AppDelegate.swift`: application lifecycle and component wiring.
- `Sources/CodexTrafficLightApp/AppState.swift`: monitor-to-main-thread state bridge and error acknowledgement.
- `Sources/CodexTrafficLightApp/TrafficLightView.swift`: three-lamp drawing, animation, and error click handling.
- `Sources/CodexTrafficLightApp/StatusItemController.swift`: menu bar indicator and minimal menu.
- `Sources/CodexTrafficLightApp/TrafficLightPanelController.swift`: draggable floating panel and position persistence.
- `Tests/CodexTrafficLightCoreTests/SessionStateReducerTests.swift`: state transitions and concurrency priority.
- `Tests/CodexTrafficLightCoreTests/SessionLineParserTests.swift`: safe field parsing and originator filtering inputs.
- `Tests/CodexTrafficLightCoreTests/SessionLogMonitorTests.swift`: split writes, discovery, filtering, malformed input, and truncation.
- `scripts/package_app.sh`: creates `build/Codex Traffic Light.app`.
- `README.md`: concise build, run, and verification commands.

---

### Task 1: Package And State Reducer

**Files:**
- Create: `Package.swift`
- Create: `Sources/CodexTrafficLightCore/TrafficLightState.swift`
- Create: `Sources/CodexTrafficLightCore/SessionStateReducer.swift`
- Create: `Tests/CodexTrafficLightCoreTests/SessionStateReducerTests.swift`

**Interfaces:**
- Produces: `TrafficLightState`, `SessionEvent`, and `SessionStateReducer`.
- Produces: `mutating func apply(_ event: SessionEvent, sessionID: String)`, `mutating func acknowledgeError()`, and `var state: TrafficLightState { get }`.

- [ ] **Step 1: Create the package manifest and failing reducer tests**

Declare macOS 13, a `CodexTrafficLightCore` library, and `CodexTrafficLightCoreTests`, with `swiftLanguageModes: [.v5]` so the installed Swift 6 toolchain keeps the deployment code in Swift 5 concurrency mode. The executable target is added in Task 3 when its entry point exists. Write tests with these concrete transitions:

```swift
func testToolCallTransitionsThinkingToExecutingAndBack() {
    var reducer = SessionStateReducer()
    reducer.apply(.taskStarted(turnID: "turn-1"), sessionID: "session-1")
    XCTAssertEqual(reducer.state, .thinking)
    reducer.apply(.toolStarted(callID: "call-1"), sessionID: "session-1")
    XCTAssertEqual(reducer.state, .executing)
    reducer.apply(.toolFinished(callID: "call-1"), sessionID: "session-1")
    XCTAssertEqual(reducer.state, .thinking)
}

func testPriorityAndTerminalLatchLifecycle() {
    var reducer = SessionStateReducer()
    reducer.apply(.taskStarted(turnID: "turn-a"), sessionID: "session-a")
    reducer.apply(.taskFailed(turnID: "turn-a"), sessionID: "session-a")
    XCTAssertEqual(reducer.state, .error)
    reducer.apply(.taskStarted(turnID: "turn-b"), sessionID: "session-b")
    XCTAssertEqual(reducer.state, .thinking)
    reducer.apply(.toolStarted(callID: "call-b"), sessionID: "session-b")
    XCTAssertEqual(reducer.state, .executing)
    reducer.apply(.taskCompleted(turnID: "turn-b"), sessionID: "session-b")
    XCTAssertEqual(reducer.state, .completed)
}

func testInterruptionAndAcknowledgementDoNotRemainRed() {
    var reducer = SessionStateReducer()
    reducer.apply(.taskStarted(turnID: "turn-1"), sessionID: "session-1")
    reducer.apply(.taskAborted(turnID: "turn-1", reason: "interrupted"), sessionID: "session-1")
    XCTAssertEqual(reducer.state, .idle)
    reducer.apply(.taskStarted(turnID: "turn-2"), sessionID: "session-1")
    reducer.apply(.taskAborted(turnID: "turn-2", reason: "model_error"), sessionID: "session-1")
    XCTAssertEqual(reducer.state, .error)
    reducer.acknowledgeError()
    XCTAssertEqual(reducer.state, .idle)
}
```

- [ ] **Step 2: Run the reducer tests and verify the expected compile failure**

Run: `swift test --filter SessionStateReducerTests`

Expected: FAIL because `SessionStateReducer`, `SessionEvent`, and `TrafficLightState` do not exist.

- [ ] **Step 3: Implement the minimal state model and reducer**

Use these exact public cases:

```swift
public enum TrafficLightState: Equatable, Sendable {
    case idle, thinking, executing, completed, error
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
```

Implement `SessionStateReducer` with:

```swift
private struct TurnKey: Hashable { let sessionID: String; let turnID: String }
private struct ActiveTurn { var outstandingCalls: Set<String> = [] }
private var activeTurns: [TurnKey: ActiveTurn] = [:]
private var currentTurnBySession: [String: TurnKey] = [:]
private var terminalLatch: TrafficLightState?
```

On `taskStarted`, clear `terminalLatch`, create the active turn, and make it current for the session. On tool start/finish, mutate the current turn's call set. On completion or abort, remove that turn and its current-session entry. Preserve `.error` when a different active turn completes. Compute `state` in the required error/executing/thinking/completed/idle priority.

- [ ] **Step 4: Run reducer tests**

Run: `swift test --filter SessionStateReducerTests`

Expected: PASS.

- [ ] **Step 5: Commit the state machine**

```bash
git add Package.swift Sources/CodexTrafficLightCore Tests/CodexTrafficLightCoreTests/SessionStateReducerTests.swift
git commit -m "feat: add traffic light state reducer"
```

### Task 2: Safe JSONL Parsing And Incremental Monitoring

**Files:**
- Create: `Sources/CodexTrafficLightCore/SessionLineParser.swift`
- Create: `Sources/CodexTrafficLightCore/SessionLogMonitor.swift`
- Create: `Tests/CodexTrafficLightCoreTests/SessionLineParserTests.swift`
- Create: `Tests/CodexTrafficLightCoreTests/SessionLogMonitorTests.swift`

**Interfaces:**
- Consumes: `SessionEvent` from Task 1.
- Produces: `ParsedSessionLine`, `MonitoredSessionEvent`, `SessionLineParser.parse(_:)`, `SessionLogMonitor.poll()`, `SessionLogMonitor.start()`, and `SessionLogMonitor.stop()`.

- [ ] **Step 1: Write failing parser tests with anonymous JSON fixtures**

```swift
func testParsesMetadataWithoutContentFields() throws {
    let data = Data(#"{"timestamp":"2026-08-06T08:00:00Z","type":"session_meta","payload":{"id":"session-1","originator":"Codex Desktop","base_instructions":"must not escape"}}"#.utf8)
    XCTAssertEqual(try parser.parse(data), .metadata(timestamp: "2026-08-06T08:00:00Z", sessionID: "session-1", originator: "Codex Desktop"))
}

func testParsesTaskAndToolEvents() throws {
    let started = Data(#"{"timestamp":"2026-08-06T08:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#.utf8)
    let tool = Data(#"{"timestamp":"2026-08-06T08:00:02Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call-1","input":"ignored"}}"#.utf8)
    XCTAssertEqual(try parser.parse(started), .event(timestamp: "2026-08-06T08:00:01Z", .taskStarted(turnID: "turn-1")))
    XCTAssertEqual(try parser.parse(tool), .event(timestamp: "2026-08-06T08:00:02Z", .toolStarted(callID: "call-1")))
}
```

Also cover `agent_reasoning`, `custom_tool_call_output`, `function_call`, `function_call_output`, `task_complete`, interrupted and non-interrupted `turn_aborted`, and explicit `task_failed`, `turn_failed`, or `error` event types. Assert unknown records return `.ignored` and malformed JSON throws.

- [ ] **Step 2: Run parser tests and verify failure**

Run: `swift test --filter SessionLineParserTests`

Expected: FAIL because the parser types do not exist.

- [ ] **Step 3: Implement a narrow parser**

Use `JSONSerialization.jsonObject(with:)` and read only these keys: outer `timestamp`, outer `type`, `payload.type`, `payload.id`, `payload.originator`, `payload.turn_id`, `payload.call_id`, and `payload.reason`. Return:

```swift
public enum ParsedSessionLine: Equatable, Sendable {
    case metadata(timestamp: String, sessionID: String, originator: String)
    case event(timestamp: String, SessionEvent)
    case ignored
}
```

Do not model or copy `text`, `input`, `output`, `last_agent_message`, `base_instructions`, or other content keys.

- [ ] **Step 4: Run parser tests**

Run: `swift test --filter SessionLineParserTests`

Expected: PASS.

- [ ] **Step 5: Write failing monitor integration tests**

Create a temporary root with `2026/08/06/session.jsonl`. Append metadata and task events in separate writes and assert:

```swift
let first = try monitor.poll()
XCTAssertEqual(first.map(\.event), [.taskStarted(turnID: "turn-1")])

try append(#"{"timestamp":"2026-08-06T08:00:02Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call-1"}}"#)
let second = try monitor.poll()
XCTAssertEqual(second.map(\.event), [.toolStarted(callID: "call-1")])
```

Add tests proving that a split final line emits only after completion, `originator: "codex_cli_rs"` is ignored, malformed lines do not block later valid lines, a truncated file restarts from offset zero, and events from multiple files are returned in timestamp order.

- [ ] **Step 6: Run monitor tests and verify failure**

Run: `swift test --filter SessionLogMonitorTests`

Expected: FAIL because `SessionLogMonitor` does not exist.

- [ ] **Step 7: Implement incremental monitoring**

Expose:

```swift
public struct MonitoredSessionEvent: Equatable, Sendable {
    public let timestamp: String
    public let sessionID: String
    public let event: SessionEvent
}

public final class SessionLogMonitor {
    public init(rootURL: URL, pollInterval: TimeInterval = 0.25)
    public var onEvents: (([MonitoredSessionEvent]) -> Void)?
    public func poll() throws -> [MonitoredSessionEvent]
    public func start()
    public func stop()
}
```

Maintain one cursor containing byte offset, incomplete bytes, optional session ID, and an accepted-originator flag per file. Production discovery scans the current and previous local-date directories beneath the session root; if neither dated directory exists, recursively scan the supplied root so temporary test roots work. Sort emitted events by ISO-8601 timestamp and then file path for deterministic replay. Use a serial `DispatchQueue` and repeating `DispatchSourceTimer` in `start()`. On unreadable root, call a separate `onAvailabilityChanged?(Bool)` callback with `false` and retry on later ticks.

- [ ] **Step 8: Run all core tests and inspect concurrency warnings**

Run: `swift test`

Expected: PASS with no Swift compiler errors.

- [ ] **Step 9: Commit parsing and monitoring**

```bash
git add Sources/CodexTrafficLightCore/SessionLineParser.swift Sources/CodexTrafficLightCore/SessionLogMonitor.swift Tests/CodexTrafficLightCoreTests/SessionLineParserTests.swift Tests/CodexTrafficLightCoreTests/SessionLogMonitorTests.swift
git commit -m "feat: monitor Codex Desktop session events"
```

### Task 3: Menu Bar And Floating Traffic-Light UI

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CodexTrafficLightApp/main.swift`
- Create: `Sources/CodexTrafficLightApp/AppDelegate.swift`
- Create: `Sources/CodexTrafficLightApp/AppState.swift`
- Create: `Sources/CodexTrafficLightApp/TrafficLightView.swift`
- Create: `Sources/CodexTrafficLightApp/StatusItemController.swift`
- Create: `Sources/CodexTrafficLightApp/TrafficLightPanelController.swift`

**Interfaces:**
- Consumes: `SessionLogMonitor`, `SessionStateReducer`, and `TrafficLightState`.
- Produces: a menu bar status item, floating panel, shared state updates, and red-error acknowledgement.

- [ ] **Step 1: Add the executable target and app lifecycle skeleton**

Add the `CodexTrafficLightApp` executable product and target, depending on `CodexTrafficLightCore`, to `Package.swift`. Use an explicit AppKit lifecycle:

```swift
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
```

`AppDelegate.applicationDidFinishLaunching` creates `AppState`, `StatusItemController`, and `TrafficLightPanelController`, then starts monitoring. `applicationWillTerminate` stops the monitor.

- [ ] **Step 2: Build and verify missing UI types fail**

Run: `swift build --product CodexTrafficLightApp`

Expected: FAIL until the controllers and view are implemented.

- [ ] **Step 3: Implement `AppState`**

`AppState` owns one reducer and monitor. Its event callback dispatches to the main queue, applies each event, and publishes changes through:

```swift
final class AppState {
    private(set) var state: TrafficLightState = .idle
    var onStateChanged: ((TrafficLightState) -> Void)?
    var onMonitoringAvailabilityChanged: ((Bool) -> Void)?
    func start()
    func stop()
    func acknowledgeError()
}
```

Default the monitor root to `FileManager.default.homeDirectoryForCurrentUser/.codex/sessions`. Allow the process-only `CODEX_TRAFFIC_LIGHT_SESSION_ROOT` environment variable to override this path for isolated manual acceptance; do not expose it as an in-app setting.

- [ ] **Step 4: Implement traffic-light rendering and animation**

`TrafficLightView` draws three circles with stable geometry. Provide:

```swift
final class TrafficLightView: NSView {
    var state: TrafficLightState = .idle { didSet { restartAnimationIfNeeded() } }
    var onAcknowledgeError: (() -> Void)?
    var orientation: Orientation
}
```

Use a 0.36-second timer. Thinking cycles the active lamp index `0, 1, 2`; executing toggles yellow; error toggles red; completed keeps green bright; idle keeps all lamps dim. Invalidate the previous timer on every state change and in `deinit`. Only a click inside the red lamp while `.error` invokes acknowledgement.

- [ ] **Step 5: Implement menu bar and panel controllers**

Create an `NSStatusItem` with a fixed-width custom `TrafficLightView` in its button and an `NSMenu` containing exactly:

- `Show Traffic Light` or `Hide Traffic Light`
- disabled `Monitoring unavailable` only while monitoring cannot read the root
- separator
- `Quit`

Create a borderless `NSPanel` with `.floating` level, `.canJoinAllSpaces`, transparent background, and a vertical `TrafficLightView`. Set `isMovableByWindowBackground = true`. Persist the top-left panel point in `UserDefaults` after movement and constrain restored frames to the union of visible screens.

- [ ] **Step 6: Build and launch the debug executable**

Run: `swift build --product CodexTrafficLightApp`

Expected: PASS and produce `.build/debug/CodexTrafficLightApp`.

Run:

```bash
.build/debug/CodexTrafficLightApp >/tmp/codex-traffic-light-debug.log 2>&1 &
app_pid=$!
sleep 2
ps -p "$app_pid"
kill "$app_pid"
wait "$app_pid" || true
```

Expected: the app remains running as an accessory app, shows both UI surfaces, and reflects the current Codex Desktop session without a Dock icon. Stop the process after inspection.

- [ ] **Step 7: Commit the UI**

```bash
git add Sources/CodexTrafficLightApp
git commit -m "feat: add macOS traffic light interface"
```

### Task 4: Packaging, Documentation, And Acceptance

**Files:**
- Create: `scripts/package_app.sh`
- Create: `README.md`
- Create: `.gitignore`

**Interfaces:**
- Consumes: the `CodexTrafficLightApp` release executable.
- Produces: `build/Codex Traffic Light.app` and reproducible build/run instructions.

- [ ] **Step 1: Write the packaging script**

The script must use `set -euo pipefail`, resolve the repository root, run `swift build -c release --product CodexTrafficLightApp`, recreate only the exact `build/Codex Traffic Light.app` path, copy the executable as `Contents/MacOS/CodexTrafficLight`, and write an `Info.plist` containing:

```xml
<key>CFBundleExecutable</key><string>CodexTrafficLight</string>
<key>CFBundleIdentifier</key><string>local.codex.traffic-light</string>
<key>CFBundleName</key><string>Codex Traffic Light</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
```

Use an explicit app path variable and remove only that validated path before recreation.

- [ ] **Step 2: Document exact commands and exclusions**

`README.md` contains:

```bash
swift test
./scripts/package_app.sh
open "build/Codex Traffic Light.app"
```

Explain the four states, desktop-only originator filter, local read-only JSONL source, error acknowledgement, unsigned local-build limitation, and that future Codex event-format changes can require an update. Add `.build/`, `build/`, and `.DS_Store` to `.gitignore`.

- [ ] **Step 3: Run automated verification**

Run: `swift test && swift build -c release --product CodexTrafficLightApp && ./scripts/package_app.sh`

Expected: all tests pass and `build/Codex Traffic Light.app/Contents/MacOS/CodexTrafficLight` exists and is executable.

- [ ] **Step 4: Verify the bundle metadata and launch**

Run:

```bash
plutil -lint "build/Codex Traffic Light.app/Contents/Info.plist"
plutil -p "build/Codex Traffic Light.app/Contents/Info.plist"
open "build/Codex Traffic Light.app"
pgrep -fl CodexTrafficLight
```

Expected: valid plist, `LSUIElement = true`, and one running packaged process.

- [ ] **Step 5: Perform visual and live-state acceptance**

Verify menu bar and panel are both visible and synchronized. During this Codex Desktop task, observe the chase animation while reasoning, yellow flashing around tool calls, and green steady after completion. Use an anonymous temporary session root in a debug launch to verify red flashing, click acknowledgement, interruption-to-idle, and split-line behavior without manufacturing errors in the real Codex session.

- [ ] **Step 6: Commit packaging and documentation**

```bash
git add .gitignore README.md scripts/package_app.sh
git commit -m "build: package Codex traffic light app"
```

- [ ] **Step 7: Final repository verification**

Run: `git status --short --branch && git log --oneline --decorate -5`

Expected: clean `main` branch with the design, reducer, monitor, UI, and packaging commits.
