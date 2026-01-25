# DebugBridge

Lightweight HTTP control server for iOS apps. Enables remote control, inspection, and automated testing without touch simulation.

## Why?

- **AI Agent Control**: Claude can drive your app programmatically
- **Automated Testing**: No flaky coordinate-based touch simulation
- **Shortcuts Integration**: Expose actions to iOS Shortcuts
- **Voice Control**: Scriptable UI = accessible UI
- **Debugging**: Query app state remotely

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

Then control from CLI:
```bash
curl -X POST http://device:8765/tap -d '{"id": "refresh-button"}'
curl -X POST http://device:8765/tap -d '{"id": "session-0:2.1"}'
```

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

## Future Ideas

- [ ] WebSocket support for real-time state streaming
- [ ] Integration with App Intents (iOS Shortcuts)
- [ ] View hierarchy inspection
- [ ] Record/playback of action sequences
- [ ] Integration with XCTest
