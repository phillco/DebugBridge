import Foundation
import Network
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
    // Off the tailnet the relay never resolves; back off far enough that
    // retrying costs nothing noticeable.
    private let maxReconnectDelay: TimeInterval = 300
    private let pingInterval: TimeInterval = 30
    /// Bumped by start/stop so a sleeping reconnect from an earlier run can't
    /// open a second socket.
    private var generation = 0
    private let session = URLSession(configuration: .default)
    private let pathMonitor = NWPathMonitor()
    private var hasNetwork = true
    private var networkWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        pathMonitor.pathUpdateHandler = { path in
            Task { await DebugBridgeRelay.shared.networkChanged(path.status == .satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "DebugBridgeRelay.path"))
    }

    public func start(url: URL) {
        self.url = url
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        reconnectDelay = 2
        connect()
    }

    public func stop() {
        isRunning = false
        isReconnecting = false
        generation += 1
        cleanupSocket()
        resumeNetworkWaiters()
    }

    private func networkChanged(_ satisfied: Bool) {
        let regained = satisfied && !hasNetwork
        hasNetwork = satisfied
        guard satisfied else { return }
        resumeNetworkWaiters()
        // A new path (e.g. joining Wi-Fi) is worth an immediate retry.
        if regained { reconnectDelay = 2 }
    }

    private func resumeNetworkWaiters() {
        let waiters = networkWaiters
        networkWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func connect() {
        guard let url, isRunning else { return }

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
            body: body,
            token: json["token"] as? String
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

        let run = generation
        if !hasNetwork {
            logger.info("Relay waiting for a network path (\(reason, privacy: .public))")
            await withCheckedContinuation { networkWaiters.append($0) }
        } else {
            let delay = reconnectDelay * Double.random(in: 0.8...1.2)
            logger.info("Relay reconnecting in \(delay, privacy: .public)s (\(reason, privacy: .public))")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
        }
        guard run == generation else { return }
        isReconnecting = false
        connect()
    }
}
