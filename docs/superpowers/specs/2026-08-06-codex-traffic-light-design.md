# Codex Traffic Light Design

## Goal

Build a native macOS companion app that shows the live state of Codex Desktop as a traffic light. The app must not modify Codex, read conversation text, or monitor Codex CLI and IDE sessions.

## Success Criteria

- A Codex Desktop task entering reasoning starts a repeating chase animation.
- A Codex Desktop tool call makes the yellow light flash until its result arrives.
- Successful completion leaves the green light on until another task starts.
- A failed task makes the red light flash until another task starts or the user acknowledges it.
- Concurrent tasks are aggregated in this order: error, executing, thinking, completed.
- User cancellation is treated as idle, not as an error.
- Both a menu bar indicator and a draggable always-on-top floating traffic light reflect the same state.
- The app builds with the installed Swift command-line toolchain and can be packaged as a standard `.app` without Xcode.

## Scope

### Included

- Read-only monitoring of local Codex session JSONL files under `~/.codex/sessions`.
- Filtering sessions whose `session_meta.payload.originator` is exactly `Codex Desktop`.
- Per-task state reduction and concurrent task aggregation.
- A menu bar indicator and a floating traffic-light panel.
- Remembering the floating panel position.
- A minimal menu for showing or hiding the panel and quitting the app.
- Automated reducer, aggregation, and file-monitoring tests.
- A packaging script that produces a launchable macOS app bundle.

### Excluded

- Codex CLI and IDE session monitoring.
- Reading or displaying user prompts, assistant messages, reasoning text, or tool output.
- Editing, injecting into, or automating the Codex application.
- Login-item installation, notifications, history, analytics, themes, or user-configurable animation settings.
- Distribution signing, notarization, or Mac App Store packaging.

## Architecture

The implementation is a Swift Package executable using AppKit. AppKit is preferred over a SwiftUI lifecycle because it gives direct control over a menu bar item, a borderless floating panel, click handling, and app-bundle startup while remaining compatible with the command-line Swift toolchain.

### `CodexSessionMonitor`

`CodexSessionMonitor` watches `~/.codex/sessions` for changed JSONL files and tails them incrementally. It keeps a byte offset and an incomplete-line buffer per file. On startup it scans existing session files to reconstruct the latest state, then processes appended bytes only.

Each file remains ignored until a valid `session_meta` identifies `originator` as `Codex Desktop`. The parser extracts only the timestamp, outer record type, event type, turn identifier, call identifier, call status, and abort reason required for state transitions. Content fields are neither decoded into domain models nor shown in the UI.

File creation, append, rotation, and truncation are handled independently. A malformed or unknown line is skipped without stopping the monitor. An incomplete final line remains buffered until the next append.

### `SessionStateReducer`

The reducer maintains one state per active turn plus a single terminal presentation latch. Historical finished turns are not retained in aggregation.

| Event | Resulting state |
| --- | --- |
| `task_started` | Clear the terminal latch and add the turn as Thinking |
| `agent_reasoning` | Thinking, unless a tool call is still outstanding |
| Tool or function call item | Executing |
| Matching tool or function result | Thinking |
| `task_complete` | Remove the active turn and latch Completed |
| Terminal error or non-interruption abort | Remove the active turn and latch Error |
| `turn_aborted` with `reason == interrupted` | Remove the active turn without latching an error |

Tool calls are tracked by call identifier so overlapping calls remain in the executing state until every outstanding result arrives. Unknown events do not change state.

Red errors can be acknowledged locally. Acknowledgement clears the error latch without writing to the Codex session. A new `task_started` event also clears the terminal latch before marking the new task as thinking. This implements the agreed rule that a red error remains visible only until acknowledgement or the next task, and that a prior green completion cannot override a later active or cancelled task.

### `StatusAggregator`

The aggregator combines all active Codex Desktop turns and the terminal presentation latch using the agreed priority:

1. Error
2. Executing
3. Thinking
4. Completed
5. Idle

This means one failed task keeps the red indicator active even if another already-running task completes. A later `task_started` event clears the prior terminal latch before normal priority aggregation resumes. Replaying events chronologically at startup reconstructs the same active-turn table and terminal latch without allowing old completed tasks to remain permanently green.

### `AppState`

`AppState` owns the monitor, reducer, and aggregator on the main actor. It publishes one presentation state to both UI surfaces. Monitor callbacks cross onto the main actor before changing UI-visible state.

### UI Components

- `StatusItemController` owns the menu bar item and its menu.
- `TrafficLightPanelController` owns a borderless, draggable, always-on-top `NSPanel`.
- `TrafficLightView` renders the same three-light state for both surfaces at different sizes.

## Visual And Interaction Design

The menu bar uses a compact horizontal three-light indicator that fits the standard menu bar height. The floating panel uses a compact vertical dark signal housing with three circular lamps and no title bar or explanatory copy.

| State | Animation |
| --- | --- |
| Thinking | Red, yellow, and green illuminate in sequence as a repeating chase |
| Executing | Yellow flashes; red and green remain dim |
| Completed | Green remains steadily lit |
| Error | Red flashes; yellow and green remain dim |
| Idle | All three lamps remain dim |

Clicking the flashing red lamp acknowledges all currently aggregated errors. Clicking and dragging elsewhere on the panel moves it. The panel position is stored in `UserDefaults` and restored on launch, constrained to a visible screen if the previous display is unavailable.

The menu contains only `Show/Hide Traffic Light` and `Quit`. Closing the floating panel hides it without terminating the menu bar app.

## Data Flow

1. Codex Desktop appends an event to a session JSONL file.
2. `CodexSessionMonitor` receives the file change and reads new complete lines.
3. The originator filter accepts only Codex Desktop sessions.
4. Parsed event metadata enters `SessionStateReducer`.
5. `StatusAggregator` computes the global presentation state.
6. `AppState` updates the menu bar icon and floating panel together.
7. Animation timers run only for thinking, executing, or error states.

## Error Handling

- Missing session directory: remain idle and retry when the directory appears.
- Unreadable monitoring directory: remain idle and show `Monitoring unavailable` as a disabled menu item; do not display a task-error red light.
- Partial JSON line: buffer it until complete.
- Malformed or unknown event: skip it and continue.
- File truncation or replacement: reset that file's offset and parse it again.
- UI restoration outside available screens: move the panel to a safe position on the main screen.

Only task-terminal failure signals produce the red state. Individual tool failures that Codex can inspect and recover from return control to thinking when their result arrives; they do not become a terminal red state by themselves.

## Build And Packaging

The repository contains a Swift Package with one executable target and one test target. `swift build` and `swift test` are the source-level build and verification commands.

A small packaging script builds the release executable and assembles `Codex Traffic Light.app` with `Contents/MacOS`, `Contents/Resources`, and an `Info.plist`. The app is an accessory application so it does not add a Dock icon. Signing and notarization are intentionally outside the first version.

## Testing

### Unit Tests

- All event-to-state transitions.
- Outstanding overlapping tool calls.
- User interruption versus terminal error.
- Error acknowledgement.
- Concurrent aggregation priority.
- Desktop originator filtering.

### Integration Tests

- Startup reconstruction from fixture files.
- Incremental and split-line appends in a temporary session directory.
- New session discovery.
- Multiple concurrent session files.
- Malformed line recovery.
- File truncation and replacement.

### Manual Acceptance

- Build and launch the generated `.app`.
- Feed simulated events and visually verify each steady and animated state.
- Confirm the menu bar and floating panel remain synchronized.
- Confirm panel drag, position restoration, hide/show, and error acknowledgement.
- Run one real Codex Desktop task containing a tool call and observe thinking, executing, and completed states in order.

## Known Constraint

This integration relies on Codex Desktop's local JSONL event format, which is not controlled by this app. Parsing is deliberately narrow and tolerant of unknown fields, but a future Codex release that renames the required event types or stops writing local sessions will require a compatibility update.
