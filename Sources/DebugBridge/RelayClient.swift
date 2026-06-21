import Foundation
import OSLog

public actor DebugBridgeRelay {
    public static let shared = DebugBridgeRelay()

    private let logger = Logger(subsystem: "DebugBridge", category: "Relay")
    private var url: URL?
    private var socket: URLSessionWebSocketTask?
    private var listenTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var isRunning = false
    private var reconnectDelay: TimeInterval = 2
    private var isReconnecting = false
    private let maxReconnectDelay: TimeInterval = 30
    private let pingInterval: TimeInterval = 15

    private init() {}

    public func start(url: URL) {
        self.url = url
        guard !isRunning else { return }
        isRunning = true
        connect()
    }

    public func stop() {
        isRunning = false
        isReconnecting = false
        cleanupSocket()
    }

    private func connect() {
        guard let url, isRunning else { return }

        let session = URLSession(configuration: .default)
        let socket = session.webSocketTask(with: url)
        self.socket = socket
        socket.resume()

        Task {
            await sendHello()
            await listen()
        }

        startPingLoop()
    }

    private func listen() async {
        listenTask?.cancel()
        listenTask = Task {
            while isRunning {
                guard let socket else { return }
                do {
                    let message = try await socket.receive()
                    markActivity()
                    switch message {
                    case .string(let text):
                        await handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await handleMessage(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    logger.warning("Relay receive failed: \(error.localizedDescription)")
                    await scheduleReconnect(reason: "receive failed")
                    return
                }
            }
        }
    }

    private func handleMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "request":
            await handleRequest(json)
        case "ping":
            await sendJSON(["type": "pong"])
        case "pong":
            markActivity()
        default:
            break
        }
    }

    private func handleRequest(_ json: [String: Any]) async {
        guard let id = json["id"] as? String else { return }

        let method = (json["method"] as? String) ?? "GET"
        let path = (json["path"] as? String) ?? "/"
        let query = (json["query"] as? [String: String]) ?? [:]
        let body = (json["body"] as? [String: Any]) ?? [:]

        let payload = await DebugBridge.shared.handleRelayRequest(
            method: method,
            path: path,
            query: query,
            body: body
        )

        var response: [String: Any] = ["type": "response", "id": id]
        response.merge(payload) { _, new in new }
        await sendJSON(response)
    }

    private func sendHello() async {
        let info = await DebugBridge.shared.relayHelloPayload()
        var payload = info
        payload["type"] = "hello"
        await sendJSON(payload)
    }

    private func sendJSON(_ dict: [String: Any]) async {
        guard let socket else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        do {
            try await socket.send(.string(text))
        } catch {
            logger.warning("Relay send failed: \(error.localizedDescription)")
            await scheduleReconnect(reason: "send failed")
        }
    }

    private func startPingLoop() {
        pingTask?.cancel()
        pingTask = Task {
            while isRunning, !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(pingInterval * 1_000_000_000))
                } catch {
                    return
                }

                guard isRunning, !Task.isCancelled else { return }
                await sendJSON(["type": "ping", "ts": Int(Date().timeIntervalSince1970)])
            }
        }
    }

    private func markActivity() {
        reconnectDelay = 2
    }

    private func cleanupSocket() {
        listenTask?.cancel()
        listenTask = nil
        pingTask?.cancel()
        pingTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    private func scheduleReconnect(reason: String) async {
        guard isRunning, !isReconnecting else { return }
        isReconnecting = true
        cleanupSocket()

        let delay = reconnectDelay
        logger.info("Relay reconnecting in \(delay, privacy: .public)s (\(reason, privacy: .public))")
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
        isReconnecting = false
        connect()
    }
}
