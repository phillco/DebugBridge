# DebugBridge

Lightweight HTTP control server for iOS apps. Enables remote control, inspection, and automated testing without touch simulation.

## Why?

- **AI Agent Control**: Claude can drive your app programmatically
- **Automated Testing**: No flaky coordinate-based touch simulation
- **Shortcuts Integration**: Expose actions to iOS Shortcuts
- **Voice Control**: Scriptable UI = accessible UI
- **Debugging**: Query app state remotely

## Architecture: Relay Mode (Recommended)

**IMPORTANT:** DebugBridge supports two modes. **Use relay mode** to avoid iOS Local Network permission issues.

### Relay Mode ✅ (Recommended)

iOS devices connect to a **central relay server** via outbound WebSocket:

```
[iOS Device] --WebSocket--> [Relay Server] <--HTTP-- [vibecontrol/CLI]
   (port --)                 (port 8767)
```

**Benefits:**
- ✅ **No iOS permissions required** (outbound connections are always allowed)
- ✅ **Central hub** - one server for all devices
- ✅ **Works over Tailscale/VPN** - devices can be anywhere
- ✅ **Reliable** - doesn't depend on iOS Local Network permission prompt

**Setup:**

1. **Start relay server** (on your laptop/Studio):
   ```bash
   ~/bin/pc/debugbridge-relay --host 0.0.0.0 --port 8767
   ```

2. **Configure iOS app** to use relay:
   ```swift
   #if DEBUG
   func setupDebugBridge() {
       // Use relay instead of direct server
       let relayURL = URL(string: "ws://studio.tailced1f.ts.net:8767/bridge")!
       Task {
           await DebugBridgeRelay.shared.start(url: relayURL)
       }

       // Register actions as usual
       DebugBridge.shared.register(actions: [...])
   }
   #endif
   ```

3. **Control via vibecontrol**:
   ```bash
   # vibecontrol automatically uses relay mode
   vibecontrol                    # List connected devices
   vibecontrol ipad screenshot    # Take screenshot
   ```

**Auto-start relay with launchd:**
```bash
# Template already exists in ~/bin/dotfiles/LaunchAgents/
launchagent-gen com.phillco.debugbridge-relay --reload
```

### Direct Mode ⚠️ (NOT Recommended)

Each device runs its own HTTP server:

```
[iOS Device:8765] <--HTTP-- [vibecontrol/CLI]
```

**Problems:**
- ❌ Requires iOS Local Network permission (often fails to prompt)
- ❌ Permission prompt is unreliable - depends on Bonjour service matching
- ❌ Each device needs its own port
- ❌ Only works on local network

**Only use direct mode for:**
- Debugging DebugBridge itself
- Environments where relay server can't run

## Installation

Add to your Xcode project as a local Swift Package:
```
File > Add Package Dependencies > Add Local > ~/Dropbox/Projects/swiftprojects/DebugBridge
```

## Usage

### 1. Register actions and start the server

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

        bridge.start()
    }
}
```

### 2. Control from CLI

```bash
# Get app info
curl http://ipad-mini:8765/

# Get current state
curl http://ipad-mini:8765/state

# List available actions
curl http://ipad-mini:8765/actions

# Execute an action
curl -X POST http://ipad-mini:8765/action/refresh

# Execute action with parameters
curl -X POST http://ipad-mini:8765/action/navigate \
  -H "Content-Type: application/json" \
  -d '{"screen": "settings"}'

# Batch execute actions
curl -X POST http://ipad-mini:8765/actions \
  -H "Content-Type: application/json" \
  -d '{"actions": [
    {"name": "refresh"},
    {"name": "selectSession", "params": {"pane": "0:6.1"}}
  ]}'

# Get screenshot (base64 PNG)
curl http://ipad-mini:8765/screenshot
```

### 3. Use from Claude Agent

```python
import httpx

def control_app(device: str, port: int = 8765):
    base = f"http://{device}:{port}"

    # Get state
    state = httpx.get(f"{base}/state").json()
    print(f"Current screen: {state['screen']}")

    # Execute action
    httpx.post(f"{base}/action/refresh")

    # Navigate
    httpx.post(f"{base}/action/navigate", json={"screen": "settings"})
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

The server binds to all interfaces, so it's accessible over the network. For production-adjacent testing, consider:
- Using a VPN/Tailscale
- Adding authentication headers
- Restricting to localhost

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
curl -X POST http://device:8765/tap -d '{"id": "refresh-button"}'
curl -X POST http://device:8765/tap -d '{"id": "session-0:2.1"}'

# Stream-ish log polling
curl "http://device:8765/logs?limit=200"
curl "http://device:8765/logs?since=1234&limit=200"

# Metrics polling
curl "http://device:8765/metrics?limit=200"
curl "http://device:8765/metrics?since=456&limit=200"
```

## Relay Server

The relay server (`~/bin/pc/debugbridge-relay`) is a lightweight WebSocket hub written in Python (aiohttp).

### How it works:

1. **iOS devices connect** via WebSocket to `/bridge` endpoint
2. **Devices send "hello"** with metadata (device name, app, version, actions)
3. **Relay maintains device registry** at `/devices` endpoint
4. **Client requests** are forwarded to the correct device via `/device/{device}/request`
5. **Devices respond** via WebSocket, relay returns HTTP response to client

### API Endpoints:

| Method | Path | Description |
|--------|------|-------------|
| GET | `/devices` | List connected devices with metadata |
| GET | `/bridge` | WebSocket endpoint (iOS devices connect here) |
| POST | `/device/{device}/request` | Forward request to specific device |

### Example: Direct relay usage

```bash
# List connected devices
curl http://localhost:8767/devices

# Send request to specific device
curl -X POST http://localhost:8767/device/ipad/request \
  -H "Content-Type: application/json" \
  -d '{
    "method": "GET",
    "path": "/state",
    "query": {},
    "body": {}
  }'

# Take screenshot through relay
curl -X POST http://localhost:8767/device/ipad/request \
  -H "Content-Type: application/json" \
  -d '{
    "method": "GET",
    "path": "/screenshot",
    "query": {},
    "body": {}
  }' | jq -r '.body' | base64 -d > screenshot.png
```

**Note:** `vibecontrol` wraps all this and uses relay mode by default.

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
curl -X POST http://device:8765/action/listIntents

# Run an intent
curl -X POST http://device:8765/action/intent.resumePlayback
curl -X POST http://device:8765/action/intent.loveCurrentSection \
  -H "Content-Type: application/json" -d '{"playSound": false}'
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

### Direct Mode Issues (if you must use it)

**iOS Local Network permission not prompting:**
- Check `NSBonjourServices` in Info.plist matches what your code advertises
- Try uninstalling and reinstalling the app
- Check Settings → [App Name] → Local Network is enabled
- Note: The permission prompt is unreliable by design - **use relay mode instead**

## Future Ideas

- [x] WebSocket relay mode for permission-free operation
- [ ] Server-sent events for logs/metrics streaming
- [x] Integration with App Intents (iOS Shortcuts)
- [ ] View hierarchy inspection
- [ ] Record/playback of action sequences
- [ ] Integration with XCTest
