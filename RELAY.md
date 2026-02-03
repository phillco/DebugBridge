# DebugBridge Relay - Quick Setup

DebugBridge uses a relay server for all device communication. iOS devices connect outbound via WebSocket (no permissions required), and `vibecontrol` talks to the relay to control them.

## Setup

### 1. Start Relay Server (Studio/Laptop)

```bash
# One-time: Set up launchd agent for auto-start
launchagent-gen com.phillco.debugbridge-relay --reload

# Or run manually:
debugbridge-relay --host 0.0.0.0 --port 8767
```

### 2. Configure iOS App

```swift
#if DEBUG
// Register actions
DebugBridge.shared.register(actions: [...])

// Connect to relay
let relayURL = URL(string: "ws://studio.tailced1f.ts.net:8767/bridge")!
Task { await DebugBridgeRelay.shared.start(url: relayURL) }
#endif
```

### 3. Control via vibecontrol

`vibecontrol` auto-discovers the relay (probes localhost, studio, mba over Tailscale):

```bash
vibecontrol                    # List devices
vibecontrol ipad screenshot    # Take screenshot
vibecontrol ipad state         # Get app state
vibecontrol ipad action refresh
```

Override relay location with `DEBUGBRIDGE_RELAY_URL` env var if needed.

## Verify It's Working

```bash
# Check relay is running
ps aux | grep debugbridge-relay

# Check devices connected to relay
curl http://localhost:8767/devices | jq '.devices[] | {device, app}'

# Test screenshot through relay
vibecontrol ipad screenshot
```

## Architecture

```
┌─────────────┐          WebSocket          ┌──────────────┐
│ iOS Device  │ ────────────────────────>   │ Relay Server │
│ (outbound)  │   ws://relay:8767/bridge    │  (Studio)    │
└─────────────┘                              └──────────────┘
                                                     ^
                                                     │ HTTP
                                                     │
                                              ┌──────┴───────┐
                                              │ vibecontrol  │
                                              │ (CLI)        │
                                              └──────────────┘
```

**Key points:**
- iOS → Relay is outbound WebSocket (no permission needed)
- Relay acts as message router between devices and CLI
- CLI talks to relay, not directly to devices

## Troubleshooting

**No devices showing:**
```bash
# Check relay is running
ps aux | grep debugbridge-relay

# Check relay logs
tail -f ~/.local/log/debugbridge-relay.log

# Verify app has correct relay URL
# Check ClaudeRemoteApp.swift for relay URL
```

**Can't connect to relay from iOS:**
```bash
# Test network connectivity from your Mac
ping studio.tailced1f.ts.net

# Verify relay is listening
netstat -an | grep 8767
```

## Files

- Relay Server: `~/bin/pc/debugbridge-relay`
- LaunchAgent Template: `~/bin/dotfiles/LaunchAgents/com.phillco.debugbridge-relay.plist.template`
- Client Code: `DebugBridge/Sources/DebugBridge/RelayClient.swift`
- CLI: `~/bin/pc/vibecontrol` (relay-only, auto-discovers server)
