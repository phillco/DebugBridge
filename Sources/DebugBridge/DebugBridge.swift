import Foundation
import Network
import OSLog
#if canImport(UIKit)
import UIKit
#endif

/// DebugBridge enables remote control and inspection of iOS apps.
///
/// Benefits:
/// - Automated testing without touch simulation
/// - AI agent control (Claude can drive the app)
/// - Shortcuts/Voice Control integration
/// - Forces scriptable, accessible UI architecture
///
/// Usage:
/// ```swift
/// DebugBridge.shared.register(
///     actions: [
///         "refresh": { _ in await serverManager.refreshAll() },
///         "navigate": { params in navigate(to: params["screen"]) }
///     ],
///     state: { ["screen": currentScreen, "sessions": sessions.count] }
/// )
/// DebugBridge.shared.start()
/// ```
@MainActor
public final class DebugBridge: ObservableObject {
    public static let shared = DebugBridge()

    private let logger = Logger(subsystem: "DebugBridge", category: "Server")
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    /// Port for the debug server (default: 8765)
    public var port: UInt16 = 8765

    /// Whether the server is running
    @Published public private(set) var isRunning = false

    /// Registered actions that can be triggered remotely
    private var actions: [String: (Parameters) async throws -> ActionResult] = [:]
    private var nonThrowingActions: [String: (Parameters) async -> ActionResult] = [:]

    /// State provider for querying app state
    private var stateProvider: (() -> [String: Any])?

    /// Crash provider for querying crash history
    private var crashProvider: (() -> [String: Any])?

    /// Stall provider for querying stall history
    private var stallProvider: ((Int?) -> [String: Any])?

    /// Screenshot provider
    private var screenshotProvider: (() async -> Data?)?

    /// Directories whose files /files can list and read
    private var fileRoots: [String: URL] = [:]

    /// When set, relayed requests must carry this token (vibecontrol sends it).
    public var relayToken: String?

    /// App metadata
    public var appName: String = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Unknown"
    public var appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"

    private init() {}

    // MARK: - Registration

    /// Action handler type
    public typealias ActionHandler = @Sendable (Parameters) async throws -> ActionResult
    public typealias NonThrowingActionHandler = @Sendable (Parameters) async -> ActionResult

    /// Register actions that can be triggered remotely
    public func register(actions newActions: [String: ActionHandler]) {
        for (key, value) in newActions {
            self.actions[key] = value
        }
        logger.info("Registered \(newActions.count) actions: \(newActions.keys.joined(separator: ", "))")
    }

    /// Register handlers that represent failures in ActionResult instead of throwing.
    public func register(nonThrowingActions newActions: [String: NonThrowingActionHandler]) {
        for (key, value) in newActions {
            self.nonThrowingActions[key] = value
        }
        logger.info("Registered \(newActions.count) nonthrowing actions: \(newActions.keys.joined(separator: ", "))")
    }

    /// Convenience: register simple void actions
    public func register(simpleActions: [String: @Sendable () async throws -> Void]) {
        for (key, action) in simpleActions {
            self.actions[key] = { _ in
                try await action()
                return .success
            }
        }
    }

    /// Register a state provider for querying app state
    public func register(state provider: @escaping () -> [String: Any]) {
        self.stateProvider = provider
    }

    /// Register a crash provider for querying crash history
    public func register(crashes provider: @escaping () -> [String: Any]) {
        self.crashProvider = provider
    }

    /// Register a stall provider for querying stall history
    public func register(stalls provider: @escaping (_ limit: Int?) -> [String: Any]) {
        self.stallProvider = provider
    }

    /// Register a screenshot provider
    public func register(screenshot provider: @escaping () async -> Data?) {
        self.screenshotProvider = provider
    }

    /// Register named directories (e.g. the app container and app group) that
    /// /files can list, read in chunks, and snapshot (SQLite) from.
    public func register(fileRoots roots: [String: URL]) {
        fileRoots.merge(roots) { _, new in new }
    }

    // MARK: - Server Lifecycle

    /// Start the debug server
    public func start() {
        #if DEBUG
        guard !isRunning else { return }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true

            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.logger.info("DebugBridge listening on port \(self?.port ?? 0)")
                    case .failed(let error):
                        self?.logger.error("DebugBridge failed: \(error)")
                        self?.isRunning = false
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleConnection(connection)
                }
            }

            listener?.start(queue: .main)
        } catch {
            logger.error("Failed to start DebugBridge: \(error)")
        }
        #else
        logger.warning("DebugBridge is disabled in release builds")
        #endif
    }

    /// Stop the debug server
    public func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        isRunning = false
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .cancelled = state, let conn = connection {
                Task { @MainActor in
                    self?.connections.removeAll { $0 === conn }
                }
            }
        }

        connection.start(queue: .main)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else {
                if isComplete || error != nil {
                    connection.cancel()
                }
                return
            }

            Task { @MainActor in
                await self.handleRequest(data: data, connection: connection)
                if !isComplete {
                    self.receiveRequest(on: connection)
                }
            }
        }
    }

    private func handleRequest(data: Data, connection: NWConnection) async {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendResponse(.badRequest("Invalid request encoding"), to: connection)
            return
        }

        // Parse simple HTTP request
        let lines = requestString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            sendResponse(.badRequest("Empty request"), to: connection)
            return
        }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(.badRequest("Malformed request line"), to: connection)
            return
        }

        let method = parts[0]
        let rawPath = parts[1]
        let components = URLComponents(string: "http://localhost\(rawPath)")
        let path = components?.path ?? rawPath
        var query: [String: String] = [:]
        if let items = components?.queryItems {
            for item in items {
                if let value = item.value {
                    query[item.name] = value
                }
            }
        }

        // Extract body for POST requests
        var body: [String: Any] = [:]
        if method == "POST", let emptyLineIndex = lines.firstIndex(of: "") {
            let bodyString = lines.dropFirst(emptyLineIndex + 1).joined(separator: "\r\n")
            if let bodyData = bodyString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                body = json
            }
        }

        // Route request
        let response = await routeRequest(method: method, path: path, query: query, body: body)
        sendResponse(response, to: connection)
    }

    func handleRelayRequest(method: String, path: String, query: [String: String], body: [String: Any], token: String?) async -> [String: Any] {
        if let relayToken, !relayToken.isEmpty, token != relayToken {
            return responsePayload(.unauthorized)
        }
        let response = await routeRequest(method: method, path: path, query: query, body: body)
        return responsePayload(response)
    }

    func relayHelloPayload() async -> [String: Any] {
        var payload = info()
        #if canImport(UIKit)
        payload["deviceName"] = UIDevice.current.name
        if let vendorId = UIDevice.current.identifierForVendor?.uuidString {
            payload["deviceId"] = vendorId
        }
        if let alias = UserDefaults.standard.string(forKey: "debugBridgeDeviceAlias"), !alias.isEmpty {
            payload["deviceAlias"] = alias
        }
        payload["deviceModel"] = UIDevice.current.model
        payload["deviceLocalizedModel"] = UIDevice.current.localizedModel
        payload["systemName"] = UIDevice.current.systemName
        payload["systemVersion"] = UIDevice.current.systemVersion
        #if targetEnvironment(simulator)
        payload["isSimulator"] = true
        #else
        payload["isSimulator"] = false
        #endif
        #endif
        return payload
    }

    private func routeRequest(method: String, path: String, query: [String: String], body: [String: Any]) async -> Response {
        let pathComponents = path.split(separator: "/").map(String.init)

        // Route based on method and path
        if method == "GET" && pathComponents.isEmpty {
            return .json(info())
        }

        if method == "GET" && pathComponents == ["describe"] {
            return .json(describe())
        }

        if method == "GET" && pathComponents == ["state"] {
            return .json(state())
        }

        if method == "GET" && pathComponents == ["crashes"] {
            if let crashProvider {
                return .json(crashProvider())
            }
            return .notFound("Crash provider not registered")
        }

        if method == "GET" && pathComponents == ["actions"] {
            return .json(["actions": Array(actions.keys)])
        }

        if method == "GET" && pathComponents == ["logs"] {
            let since = query["since"].flatMap { Int($0) }
            let limit = query["limit"].flatMap { Int($0) } ?? 200
            let snapshot = await DebugLogStore.shared.snapshot(since: since, limit: limit)
            let payload: [String: Any] = [
                "logs": snapshot.entries.map { $0.toDict() },
                "next": snapshot.next
            ]
            return .json(payload)
        }

        if method == "GET" && pathComponents == ["metrics"] {
            let since = query["since"].flatMap { Int($0) }
            let limit = query["limit"].flatMap { Int($0) } ?? 200
            let snapshot = await DebugMetricStore.shared.snapshot(since: since, limit: limit)
            let payload: [String: Any] = [
                "metrics": snapshot.entries.map { $0.toDict() },
                "next": snapshot.next
            ]
            return .json(payload)
        }

        if method == "GET" && pathComponents == ["perf"] {
            let since = query["since"].flatMap { Int($0) }
            let limit = query["limit"].flatMap { Int($0) } ?? 50
            let sort = query["sort"] ?? "total"
            let summary = await DebugMetricStore.shared.summary(since: since, limit: limit, sort: sort)
            let payload: [String: Any] = [
                "summary": summary.summaries.map { $0.toDict() },
                "next": summary.next
            ]
            return .json(payload)
        }

        if method == "GET" && pathComponents == ["stalls"] {
            guard let stallProvider else {
                return .notFound("Stall provider not registered")
            }
            let limit = query["limit"].flatMap { Int($0) }
            return .json(stallProvider(limit))
        }

        if method == "GET" && pathComponents == ["screenshot"] {
            if let data = await screenshotProvider?() {
                return .png(data)
            }
            return .notFound("Screenshot provider not registered")
        }

        if pathComponents.first == "files" {
            return await routeFiles(method: method, path: Array(pathComponents.dropFirst()), query: query, body: body)
        }

        #if canImport(UIKit)
        // UI Element inspection
        if method == "GET" && pathComponents == ["elements"] {
            let elements = UIElementInspector.shared.getElements()
            let dicts = elements.map { element -> [String: Any] in
                var dict: [String: Any] = [
                    "id": element.id,
                    "type": element.type,
                    "enabled": element.enabled,
                    "frame": [
                        "x": element.frame.x,
                        "y": element.frame.y,
                        "width": element.frame.width,
                        "height": element.frame.height
                    ],
                    "traits": element.traits
                ]
                if let label = element.label { dict["label"] = label }
                if let value = element.value { dict["value"] = value }
                return dict
            }
            return .json(["elements": dicts, "count": elements.count])
        }

        // Tap element
        if method == "POST" && pathComponents == ["tap"] {
            guard let identifier = body["id"] as? String ?? body["label"] as? String else {
                return .badRequest("Missing 'id' or 'label' parameter")
            }
            let success = UIElementInspector.shared.tap(identifier: identifier)
            if success {
                return .json(["status": "ok", "tapped": identifier])
            } else {
                return .notFound("Element not found: \(identifier)")
            }
        }

        // Type text
        if method == "POST" && pathComponents == ["type"] {
            guard let identifier = body["id"] as? String ?? body["label"] as? String else {
                return .badRequest("Missing 'id' or 'label' parameter")
            }
            guard let text = body["text"] as? String else {
                return .badRequest("Missing 'text' parameter")
            }
            let success = UIElementInspector.shared.typeText(identifier: identifier, text: text)
            if success {
                return .json(["status": "ok", "typed": text, "into": identifier])
            } else {
                return .notFound("Text field not found: \(identifier)")
            }
        }

        // Toggle switch
        if method == "POST" && pathComponents == ["toggle"] {
            guard let identifier = body["id"] as? String ?? body["label"] as? String else {
                return .badRequest("Missing 'id' or 'label' parameter")
            }
            let success = UIElementInspector.shared.toggle(identifier: identifier)
            if success {
                return .json(["status": "ok", "toggled": identifier])
            } else {
                return .notFound("Toggle not found: \(identifier)")
            }
        }

        // Scroll
        if method == "POST" && pathComponents == ["scroll"] {
            guard let direction = body["direction"] as? String else {
                return .badRequest("Missing 'direction' parameter (up/down/left/right)")
            }
            let amount = body["amount"] as? Double ?? 300
            let success = UIElementInspector.shared.scroll(direction: direction, amount: amount)
            if success {
                return .json(["status": "ok", "scrolled": direction, "amount": amount])
            } else {
                return .notFound("No scrollable view found")
            }
        }

        // Tap at coordinates
        if method == "POST" && pathComponents == ["tapxy"] {
            guard let x = body["x"] as? Double ?? (body["x"] as? Int).map(Double.init),
                  let y = body["y"] as? Double ?? (body["y"] as? Int).map(Double.init) else {
                return .badRequest("Missing 'x' and 'y' parameters")
            }
            let success = UIElementInspector.shared.tapAtPoint(x: x, y: y)
            if success {
                return .json(["status": "ok", "tapped": ["x": x, "y": y]])
            } else {
                return .json(["status": "ok", "tapped": ["x": x, "y": y], "warning": "No interactive element at coordinates"])
            }
        }
        #endif

        if method == "POST" && pathComponents.count == 2 && pathComponents[0] == "action" {
            let actionName = pathComponents[1]
            return await executeAction(name: actionName, params: Parameters(body))
        }

        if method == "POST" && pathComponents == ["actions"] {
            // Batch execute multiple actions
            guard let actionList = body["actions"] as? [[String: Any]] else {
                return .badRequest("Expected 'actions' array")
            }
            var results: [[String: Any]] = []
            for actionDef in actionList {
                guard let name = actionDef["name"] as? String else { continue }
                let params = actionDef["params"] as? [String: Any] ?? [:]
                let result = await executeAction(name: name, params: Parameters(params))
                results.append(["action": name, "status": result.statusCode])
            }
            return .json(["results": results])
        }

        return .notFound("Unknown endpoint: \(method) \(path)")
    }

    private func routeFiles(method: String, path: [String], query: [String: String], body: [String: Any]) async -> Response {
        var roots = fileRoots
        roots[DebugFiles.snapshotRoot] = DebugFiles.snapshotDirectory
        if method == "GET" && path.isEmpty && query["root"] == nil {
            return .json(["roots": roots.mapValues(\.path)])
        }
        let root = query["root"] ?? body["root"] as? String
        let filePath = query["path"] ?? body["path"] as? String
        let work: @Sendable () throws -> [String: Any]
        do {
            let url = try DebugFiles.resolve(root: root, path: filePath, roots: roots)
            switch (method, path) {
            case ("GET", []):
                let recursive = query["recursive"] == "1"
                work = { ["files": try DebugFiles.list(url, recursive: recursive)] }
            case ("GET", ["read"]):
                let offset = query["offset"].flatMap(Int.init) ?? 0
                let length = query["length"].flatMap(Int.init) ?? DebugFiles.maxChunk
                work = { try DebugFiles.read(url, offset: offset, length: length) }
            case ("GET", ["sha256"]):
                work = { ["sha256": try DebugFiles.sha256(url)] }
            case ("POST", ["snapshot"]):
                work = {
                    DebugFiles.pruneSnapshots()
                    return try DebugFiles.snapshot(url)
                }
            default:
                return .notFound("Unknown endpoint: \(method) /files/\(path.joined(separator: "/"))")
            }
            return .json(try await Task.detached(priority: .utility, operation: work).value)
        } catch DebugFiles.Failure.badRequest(let message) {
            return .badRequest(message)
        } catch DebugFiles.Failure.notFound(let message) {
            return .notFound(message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func executeAction(name: String, params: Parameters) async -> Response {
        if let action = nonThrowingActions[name] {
            let result = await action(params)
            return .json(result.toDict())
        }

        guard let action = actions[name] else {
            return .notFound("Unknown action: \(name)")
        }

        do {
            let result = try await action(params)
            return .json(result.toDict())
        } catch {
            return .error("Action failed: \(error.localizedDescription)")
        }
    }

    private func sendResponse(_ response: Response, to connection: NWConnection) {
        let httpResponse = response.toHTTP()
        connection.send(content: httpResponse.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func responsePayload(_ response: Response) -> [String: Any] {
        switch response {
        case .json(let dict):
            return ["status": response.statusCode, "contentType": "application/json", "body": dict]
        case .png(let data):
            return ["status": response.statusCode, "contentType": "image/png", "body": data.base64EncodedString()]
        case .badRequest(let msg):
            return ["status": response.statusCode, "contentType": "application/json", "body": ["error": msg]]
        case .notFound(let msg):
            return ["status": response.statusCode, "contentType": "application/json", "body": ["error": msg]]
        case .error(let msg):
            return ["status": response.statusCode, "contentType": "application/json", "body": ["error": msg]]
        case .unauthorized:
            return ["status": response.statusCode, "contentType": "application/json", "body": ["error": "Missing or wrong DebugBridge token"]]
        }
    }

    // MARK: - Info & State

    private func info() -> [String: Any] {
        var info: [String: Any] = [
            "app": appName,
            "version": appVersion,
            "actions": Array(actions.keys),
            "hasState": stateProvider != nil,
            "hasCrashes": crashProvider != nil,
            "hasStalls": stallProvider != nil,
            "hasScreenshot": screenshotProvider != nil,
            "hasLogs": true,
            "hasMetrics": true,
            "hasPerf": true,
            "hasFiles": !fileRoots.isEmpty
        ]
        #if canImport(UIKit)
        info["hasElements"] = true
        #endif
        return info
    }

    private func state() -> [String: Any] {
        stateProvider?() ?? ["error": "No state provider registered"]
    }

    private func describe() -> [String: Any] {
        var result: [String: Any] = [
            "app": appName,
            "version": appVersion,
            "actions": Array(actions.keys).sorted(),
        ]
        if let stateProvider {
            result["state"] = stateProvider()
        }
        #if canImport(UIKit)
        let elements = UIElementInspector.shared.getElements()
        result["elements"] = elements.map { element -> [String: Any] in
            var dict: [String: Any] = [
                "id": element.id,
                "type": element.type,
                "enabled": element.enabled,
                "frame": [
                    "x": element.frame.x,
                    "y": element.frame.y,
                    "width": element.frame.width,
                    "height": element.frame.height
                ],
                "traits": element.traits
            ]
            if let label = element.label { dict["label"] = label }
            if let value = element.value { dict["value"] = value }
            return dict
        }
        result["elementCount"] = elements.count
        #endif
        return result
    }
}

// MARK: - Supporting Types

/// Parameters passed to actions
public struct Parameters {
    private let dict: [String: Any]

    public init(_ dict: [String: Any] = [:]) {
        self.dict = dict
    }

    /// A detached JSON snapshot for transferring requests between executors.
    public func encodedJSON() throws -> Data {
        guard JSONSerialization.isValidJSONObject(dict) else {
            throw EncodingError.invalidValue(
                "DebugBridge.Parameters",
                .init(codingPath: [], debugDescription: "Parameters must contain only JSON values")
            )
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    public subscript(key: String) -> Any? { dict[key] }

    public func string(_ key: String) -> String? { dict[key] as? String }
    public func int(_ key: String) -> Int? { dict[key] as? Int }
    public func double(_ key: String) -> Double? {
        if let value = dict[key] as? Double { return value }
        if let value = dict[key] as? Int { return Double(value) }
        if let value = dict[key] as? String { return Double(value) }
        return nil
    }
    public func bool(_ key: String) -> Bool? { dict[key] as? Bool }
    public func array<T>(_ key: String) -> [T]? { dict[key] as? [T] }
}

/// Result of an action execution
public enum ActionResult {
    case success
    case value(Any)
    case error(String)

    func toDict() -> [String: Any] {
        switch self {
        case .success:
            return ["status": "ok"]
        case .value(let v):
            return ["status": "ok", "value": v]
        case .error(let msg):
            return ["status": "error", "error": msg]
        }
    }
}

/// HTTP Response wrapper
private enum Response {
    case json([String: Any])
    case png(Data)
    case badRequest(String)
    case notFound(String)
    case error(String)
    case unauthorized

    var statusCode: Int {
        switch self {
        case .json, .png: return 200
        case .badRequest: return 400
        case .unauthorized: return 401
        case .notFound: return 404
        case .error: return 500
        }
    }

    func toHTTP() -> String {
        let (status, contentType, body) = httpComponents()
        let bodyData = body.data(using: .utf8) ?? Data()

        return """
        HTTP/1.1 \(status)
        Content-Type: \(contentType)
        Content-Length: \(bodyData.count)
        Access-Control-Allow-Origin: *
        Connection: close

        \(body)
        """
    }

    private func httpComponents() -> (status: String, contentType: String, body: String) {
        switch self {
        case .json(let dict):
            let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
            let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return ("200 OK", "application/json", json)
        case .png(let data):
            return ("200 OK", "image/png", data.base64EncodedString())
        case .badRequest(let msg):
            return ("400 Bad Request", "application/json", "{\"error\":\"\(msg)\"}")
        case .notFound(let msg):
            return ("404 Not Found", "application/json", "{\"error\":\"\(msg)\"}")
        case .error(let msg):
            return ("500 Internal Server Error", "application/json", "{\"error\":\"\(msg)\"}")
        case .unauthorized:
            return ("401 Unauthorized", "application/json", "{\"error\":\"Missing or wrong DebugBridge token\"}")
        }
    }
}
