# DebugBridge

Lightweight HTTP control server for iOS apps. Enables remote control, inspection, and automated testing without touch simulation.

## Why?

- **AI Agent Control**: Claude can drive your app programmatically
- **Automated Testing**: No flaky coordinate-based touch simulation
- **Shortcuts Integration**: Expose actions to iOS Shortcuts
- **Voice Control**: Scriptable UI = accessible UI
- **Debugging**: Query app state remotely

## Architecture

iOS devices connect to a **central relay server** via outbound WebSocket. `vibecontrol` (CLI) talks to the relay, not directly to devices.

```
[iOS Device] --WebSocket--> [Relay Server] <--HTTP-- [vibecontrol/CLI]
   (outbound)                (port 8767)
```

- **No iOS permissions required** - outbound connections are always allowed
- **Works everywhere** - real devices, simulators, over Tailscale/VPN
- **Central hub** - one server, all devices
- **Auto-discovery** - `vibecontrol` finds the relay automatically (localhost, studio, mba)

### Setup

1. **Start relay server** (on your laptop/Studio):
   ```bash
   # Auto-start via launchd (recommended):
   launchagent-gen com.phillco.debugbridge-relay --reload

   # Or run manually:
   debugbridge-relay --host 0.0.0.0 --port 8767
   ```

2. **Configure iOS app** to connect to relay:
   ```swift
   #if DEBUG
   func setupDebugBridge() {
       DebugBridge.shared.register(actions: [...])

       let relayURL = URL(string: "ws://studio.tailced1f.ts.net:8767/bridge")!
       Task {
           await DebugBridgeRelay.shared.start(url: relayURL)
       }
   }
   #endif
   ```

3. **Control via vibecontrol**:
   ```bash
   vibecontrol                    # List connected devices
   vibecontrol ipad screenshot    # Take screenshot
   vibecontrol iphone action intent.resumePlayback
   ```

## Installation

Add to your Xcode project as a local Swift Package:
```
File > Add Package Dependencies > Add Local > ~/Dropbox/Projects/swiftprojects/DebugBridge
```

## Usage

### 1. Register actions and connect to relay

```swift
import DebugBridge

@main
struct MyApp: App {
    init() {
        #if DEBUG
        setupDebugBridge()
        #endif
    }

    func setupDebugBridge() {
        let bridge = DebugBridge.shared

        // Register actions
        bridge.register(actions: [
            "refresh": { _ in
                await ServerManager.shared.refreshAll()
                return .success
            },
            "navigate": { params in
                guard let screen = params.string("screen") else {
                    return .error("Missing 'screen' parameter")
                }
                Navigator.shared.navigate(to: screen)
                return .success
            },
            "selectSession": { params in
                guard let pane = params.string("pane") else {
                    return .error("Missing 'pane' parameter")
                }
                SessionManager.shared.select(pane: pane)
                return .value(["selected": pane])
            }
        ])

        // Register state provider
        bridge.register(state: {
            [
                "screen": Navigator.currentScreen,
                "sessionCount": SessionManager.sessions.count,
                "selectedSession": SessionManager.selected?.pane
            ]
        })

        // Register screenshot provider (optional)
        bridge.register(screenshot: {
            await MainActor.run {
                UIApplication.shared.windows.first?.asImage()?.pngData()
            }
        })

        // Connect to relay server
        let relayURL = URL(string: "ws://studio.tailced1f.ts.net:8767/bridge")!
        Task { await DebugBridgeRelay.shared.start(url: relayURL) }
    }
}
```

### 2. Control via vibecontrol

```bash
# List connected devices (auto-discovers relay)
vibecontrol

# Get app info
vibecontrol ipad info

# Execute an action
vibecontrol ipad action refresh

# Execute action with parameters
vibecontrol ipad action navigate '{"screen": "settings"}'

# Take screenshot
vibecontrol ipad screenshot
```

### 3. Control via relay HTTP API (low-level)

```bash
# List connected devices
curl http://localhost:8767/devices

# Send request to a device through relay
curl -X POST http://localhost:8767/device/ipad/request \
  -H "Content-Type: application/json" \
  -d '{"method": "POST", "path": "/action/refresh", "query": {}, "body": {}}'
```

## API Reference

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | App info (name, version, available actions) |
| GET | `/state` | Current app state from state provider |
| GET | `/actions` | List registered action names |
| GET | `/screenshot` | Base64 PNG screenshot |
| GET | `/logs` | Recent in-app logs (optional `?since=` and `?limit=`) |
| GET | `/metrics` | Recent performance metrics (optional `?since=` and `?limit=`) |
| GET | `/perf` | Aggregated performance summary (optional `?since=`, `?limit=`, `?sort=`) |
| GET | `/crashes` | Crash history (requires crash provider) |
| GET | `/stalls` | Main-thread stall history (requires stall provider; optional `?limit=`) |
| POST | `/action/{name}` | Execute single action |
| POST | `/actions` | Batch execute multiple actions |

### Action Parameters

Actions receive a `Parameters` object with typed accessors:

```swift
bridge.register(actions: [
    "example": { params in
        let name = params.string("name")     // String?
        let count = params.int("count")      // Int?
        let enabled = params.bool("enabled") // Bool?
        let items = params.array("items")    // [T]?
        return .success
    }
])
```

### Action Results

```swift
return .success                    // {"status": "ok"}
return .value(["count": 42])       // {"status": "ok", "value": {"count": 42}}
return .error("Something failed")  // {"status": "error", "error": "..."}
```

## Security

⚠️ **DebugBridge only runs in DEBUG builds** - it's automatically disabled in release.

The relay server should run on a trusted network (e.g., behind Tailscale). All device communication flows through the relay - devices don't expose any ports themselves.

## Architecture Benefits

Designing your app around DebugBridge encourages:

1. **Semantic actions**: Instead of "tap button at (x,y)", you have "refresh", "navigate"
2. **Observable state**: App state is queryable, not hidden
3. **Testability**: Actions are pure functions that can be unit tested
4. **Accessibility**: Same actions work for VoiceOver, Shortcuts, automation

## SwiftUI Helpers

Make SwiftUI views controllable via DebugBridge:

```swift
import DebugBridge

// Make a button tappable by ID
Button("Refresh") { refresh() }
    .debugTappable("refresh-button")

// Add a custom action to any view
SessionRow(session: session)
    .debugAction("session-\(session.id)") {
        selectedSession = session
    }

// Scriptable navigation link
ScriptableNavigationLink("session-\(session.pane)", destination: ChatView(session: session)) {
    SessionRow(session: session)
}
```

### Accessibility Identifiers (Important)

DebugBridge's UI inspection and `tap` endpoints rely on accessibility identifiers/labels. SwiftUI views often **aren't** accessibility elements by default, especially inside `LazyVStack`/`LazyVGrid`.

**Recommendation:**
- Add `.accessibilityIdentifier("your.id")` to any view you want to control.
- For custom rows/cards, also add `.accessibilityElement(children: .combine)` so the container becomes tappable.

Example:
```swift
SavedLoopCard(loop: loop)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("loop.\(index)")
    .accessibilityLabel(loop.displayName)
```

Then control from CLI:
```bash
vibecontrol ipad tap "refresh-button"
vibecontrol ipad tap "session-0:2.1"
```

## Relay Server

The relay server (`~/bin/pc/debugbridge-relay`) is a lightweight WebSocket hub (Python/aiohttp).

**How it works:** iOS devices connect via WebSocket → relay maintains device registry → `vibecontrol` sends HTTP requests to relay → relay forwards to device via WebSocket → response flows back.

| Method | Path | Description |
|--------|------|-------------|
| GET | `/devices` | List connected devices with metadata |
| GET | `/bridge` | WebSocket endpoint (iOS devices connect here) |
| POST | `/device/{device}/request` | Forward request to specific device |

## Design Philosophy

DebugBridge encourages **scriptable by design** architecture:

1. **Discovery**: Screenshots and element inspection always work
2. **App Actions**: Register semantic actions (`refresh`, `navigate`, `selectSession`)
3. **UI Automation**: Use accessibility identifiers for fine-grained control

This approach:
- Works with SwiftUI and UIKit
- Encourages accessibility best practices
- Makes apps testable and automatable
- Enables AI agent control (Claude, Shortcuts, Voice Control)

## App Intents Integration

Automatically expose every `AppIntent` as a DebugBridge HTTP action. Build a new Shortcuts action → get DebugBridge automation for free.

### Setup

1. **Define the protocol and registry** in your app (e.g. `IntentBridge.swift`):

```swift
#if DEBUG
import AppIntents
import DebugBridge

/// Conform an AppIntent to auto-expose it via DebugBridge.
protocol BridgeableIntent: AppIntent {
    static var bridgeParameters: [IntentBridge.ParamDescriptor] { get }
    static func bridgeExecute(params: Parameters) async throws -> ActionResult
}

// Default: parameterless intents just call perform()
extension BridgeableIntent {
    static var bridgeParameters: [IntentBridge.ParamDescriptor] { [] }
    static func bridgeExecute(params: Parameters) async throws -> ActionResult {
        let intent = Self()
        _ = try await intent.perform()
        return .success
    }
}

enum IntentBridge {
    struct ParamDescriptor {
        let name: String
        let type: String
        let required: Bool
        let defaultValue: String?

        init(name: String, type: String, required: Bool = false, defaultValue: String? = nil) {
            self.name = name; self.type = type; self.required = required; self.defaultValue = defaultValue
        }
    }

    /// All intent types to expose. Add new intents here.
    static let allIntents: [any BridgeableIntent.Type] = [
        ResumePlaybackIntent.self,
        PausePlaybackIntent.self,
        // ...
    ]

    /// "ResumePlaybackIntent" → "intent.resumePlayback"
    static func actionName(for type: any BridgeableIntent.Type) -> String {
        var name = String(describing: type)
        if name.hasSuffix("Intent") { name = String(name.dropLast(6)) }
        return "intent.\(name.prefix(1).lowercased())\(name.dropFirst())"
    }

    @MainActor
    static func register(on bridge: DebugBridge) {
        var actions: [String: @Sendable (Parameters) async -> ActionResult] = [:]
        for intentType in allIntents {
            let name = actionName(for: intentType)
            let captured = intentType
            actions[name] = { params in
                do { return try await captured.bridgeExecute(params: params) }
                catch { return .error("\(error)") }
            }
        }

        // IMPORTANT: Pre-compute catalog here, not inside the closure.
        // Iterating [any BridgeableIntent.Type] inside @Sendable async
        // closures crashes at runtime.
        let catalog: [[String: Any]] = allIntents.map { intentType in
            var entry: [String: Any] = [
                "action": actionName(for: intentType),
                "title": String(localized: intentType.title),
            ]
            let params = intentType.bridgeParameters
            if !params.isEmpty {
                entry["parameters"] = params.map { ["name": $0.name, "type": $0.type] }
            }
            return entry
        }
        actions["listIntents"] = { _ in .value(["intents": catalog, "count": catalog.count]) }

        bridge.register(actions: actions)
    }
}
#endif
```

2. **Add conformance** to your intents:

```swift
#if DEBUG
// Parameterless: one line
extension ResumePlaybackIntent: BridgeableIntent {}
extension PausePlaybackIntent: BridgeableIntent {}

// Parameterized: override bridgeExecute
extension LoveCurrentSectionIntent: BridgeableIntent {
    static var bridgeParameters: [IntentBridge.ParamDescriptor] {
        [.init(name: "playSound", type: "Bool", defaultValue: "true")]
    }
    static func bridgeExecute(params: Parameters) async throws -> ActionResult {
        var intent = Self()
        intent.playSound = params.bool("playSound") ?? true
        _ = try await intent.perform()
        return .success
    }
}
#endif
```

3. **Register in your SceneDelegate/App init**:

```swift
#if DEBUG
IntentBridge.register(on: DebugBridge.shared)
#endif
```

### Usage

```bash
# List all exposed intents
vibecontrol ipad action listIntents

# Run an intent
vibecontrol ipad action intent.resumePlayback
vibecontrol ipad action intent.loveCurrentSection '{"playSound": false}'
```

### Naming Convention

Intent actions use the `intent.` prefix to coexist with manual DebugBridge actions:
- `ResumePlaybackIntent` → `intent.resumePlayback`
- `CheckForUpdatesIntent` → `intent.checkForUpdates`

### Known Limitations

- **Opaque result types**: `some IntentResult & ProvidesDialog` resists Mirror reflection. Dialog text from intents like "Already paused" can't be extracted. Intents returning `ReturnsValue<String>` work fine.
- **Existential crash**: The `[any BridgeableIntent.Type]` array must be iterated at registration time, not inside `@Sendable` async closures. Pre-compute any data you need from the array.
- **Entity parameters**: Intents taking `AppEntity` parameters (like `PlayEpisodeIntent` with `EpisodeEntity`) are better handled as manual DebugBridge actions with query-based lookup.

## Troubleshooting

### Relay Mode Issues

**Devices not appearing in `vibecontrol`:**
1. Check relay server is running: `ps aux | grep debugbridge-relay`
2. Check relay server logs: `tail -f ~/.local/log/debugbridge-relay.log`
3. Query relay directly: `curl http://localhost:8767/devices`
4. Verify iOS app is using correct relay URL (check hostname/port)
5. Check network connectivity (ping the relay server from another device)

**iOS app can't connect to relay:**
- Verify relay URL is reachable from iOS device: `ping mbp-nano.tailced1f.ts.net`
- Check relay is listening on all interfaces (0.0.0.0, not 127.0.0.1)
- Verify port 8767 is not blocked by firewall
- Check relay logs for connection attempts

**Devices keep disconnecting:**
- WebSocket connections can drop on network changes
- Relay auto-reconnects with exponential backoff
- Check for network stability issues

## Future Ideas

- [x] WebSocket relay mode for permission-free operation
- [ ] Server-sent events for logs/metrics streaming
- [x] Integration with App Intents (iOS Shortcuts)
- [ ] View hierarchy inspection
- [ ] Record/playback of action sequences
- [ ] Integration with XCTest
