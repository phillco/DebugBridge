import Foundation

public enum DebugLogLevel: String {
    case debug
    case info
    case warning
    case error
}

public struct DebugLogEntry {
    public let id: Int
    public let timestamp: TimeInterval
    public let level: String
    public let message: String
    public let category: String?
    public let metadata: [String: String]?

    public func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "ts": timestamp,
            "level": level,
            "message": message
        ]
        if let category {
            dict["category"] = category
        }
        if let metadata {
            dict["meta"] = metadata
        }
        return dict
    }
}

public actor DebugLogStore {
    public static let shared = DebugLogStore()

    private var entries: [DebugLogEntry] = []
    private var nextId = 0
    public var capacity: Int = 1000

    public func append(level: DebugLogLevel, message: String, category: String? = nil, metadata: [String: String]? = nil) -> DebugLogEntry {
        let entry = DebugLogEntry(
            id: nextId,
            timestamp: Date().timeIntervalSince1970,
            level: level.rawValue,
            message: message,
            category: category,
            metadata: metadata
        )
        nextId += 1
        entries.append(entry)

        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }

        return entry
    }

    public func snapshot(since: Int? = nil, limit: Int = 200) -> (entries: [DebugLogEntry], next: Int) {
        let clampedLimit = max(1, min(limit, 1000))
        if let since {
            let filtered = entries.filter { $0.id >= since }
            let limited = Array(filtered.prefix(clampedLimit))
            let next = (limited.last?.id ?? (since - 1)) + 1
            return (limited, next)
        }

        let limited = Array(entries.suffix(clampedLimit))
        let next = (limited.last?.id ?? (entries.last?.id ?? -1)) + 1
        return (limited, next)
    }

    public func clear() {
        entries.removeAll()
    }
}

public enum DebugLog {
    public static var isEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    public static func log(_ message: String,
                           level: DebugLogLevel = .info,
                           category: String? = nil,
                           metadata: [String: Any]? = nil) {
        guard isEnabled else { return }
        let normalized = normalize(metadata)
        Task {
            await DebugLogStore.shared.append(
                level: level,
                message: message,
                category: category,
                metadata: normalized
            )
        }
    }

    public static func debug(_ message: String, category: String? = nil, metadata: [String: Any]? = nil) {
        log(message, level: .debug, category: category, metadata: metadata)
    }

    public static func info(_ message: String, category: String? = nil, metadata: [String: Any]? = nil) {
        log(message, level: .info, category: category, metadata: metadata)
    }

    public static func warning(_ message: String, category: String? = nil, metadata: [String: Any]? = nil) {
        log(message, level: .warning, category: category, metadata: metadata)
    }

    public static func error(_ message: String, category: String? = nil, metadata: [String: Any]? = nil) {
        log(message, level: .error, category: category, metadata: metadata)
    }

    private static func normalize(_ metadata: [String: Any]?) -> [String: String]? {
        guard let metadata else { return nil }
        var normalized: [String: String] = [:]
        for (key, value) in metadata {
            normalized[key] = String(describing: value)
        }
        return normalized.isEmpty ? nil : normalized
    }
}
