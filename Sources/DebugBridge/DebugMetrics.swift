import Foundation

public struct DebugMetricEntry {
    public let id: Int
    public let name: String
    public let timestamp: TimeInterval
    public let durationMs: Double
    public let metadata: [String: String]?

    public func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "name": name,
            "ts": timestamp,
            "duration_ms": durationMs
        ]
        if let metadata {
            dict["meta"] = metadata
        }
        return dict
    }
}

public struct DebugMetricSummary {
    public let name: String
    public let count: Int
    public let totalMs: Double
    public let avgMs: Double
    public let maxMs: Double
    public let p50Ms: Double
    public let p95Ms: Double
    public let lastTimestamp: TimeInterval

    public func toDict() -> [String: Any] {
        [
            "name": name,
            "count": count,
            "total_ms": totalMs,
            "avg_ms": avgMs,
            "max_ms": maxMs,
            "p50_ms": p50Ms,
            "p95_ms": p95Ms,
            "last_ts": lastTimestamp
        ]
    }
}

public actor DebugMetricStore {
    public static let shared = DebugMetricStore()

    private var entries: [DebugMetricEntry] = []
    private var nextId = 0
    public var capacity: Int = 1000

    public func record(name: String, duration: TimeInterval, metadata: [String: String]? = nil) -> DebugMetricEntry {
        let entry = DebugMetricEntry(
            id: nextId,
            name: name,
            timestamp: Date().timeIntervalSince1970,
            durationMs: duration * 1000,
            metadata: metadata
        )
        nextId += 1
        entries.append(entry)

        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }

        return entry
    }

    public func snapshot(since: Int? = nil, limit: Int = 200) -> (entries: [DebugMetricEntry], next: Int) {
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

    public func summary(since: Int? = nil,
                        limit: Int = 50,
                        sort: String = "total") -> (summaries: [DebugMetricSummary], next: Int) {
        let filtered: [DebugMetricEntry]
        if let since {
            filtered = entries.filter { $0.id >= since }
        } else {
            filtered = entries
        }

        var grouped: [String: [DebugMetricEntry]] = [:]
        grouped.reserveCapacity(64)
        for entry in filtered {
            grouped[entry.name, default: []].append(entry)
        }

        var summaries: [DebugMetricSummary] = []
        summaries.reserveCapacity(grouped.count)

        for (name, items) in grouped {
            let durations = items.map { $0.durationMs }.sorted()
            guard let max = durations.last else { continue }
            let total = durations.reduce(0, +)
            let count = durations.count
            let avg = total / Double(count)
            let p50 = percentile(durations, 0.50)
            let p95 = percentile(durations, 0.95)
            let lastTs = items.max(by: { $0.timestamp < $1.timestamp })?.timestamp ?? 0

            summaries.append(DebugMetricSummary(
                name: name,
                count: count,
                totalMs: total,
                avgMs: avg,
                maxMs: max,
                p50Ms: p50,
                p95Ms: p95,
                lastTimestamp: lastTs
            ))
        }

        let sorted: [DebugMetricSummary]
        switch sort.lowercased() {
        case "avg":
            sorted = summaries.sorted { $0.avgMs > $1.avgMs }
        case "max":
            sorted = summaries.sorted { $0.maxMs > $1.maxMs }
        case "p95":
            sorted = summaries.sorted { $0.p95Ms > $1.p95Ms }
        case "count":
            sorted = summaries.sorted { $0.count > $1.count }
        default:
            sorted = summaries.sorted { $0.totalMs > $1.totalMs }
        }

        let clampedLimit = max(1, min(limit, 200))
        let limited = Array(sorted.prefix(clampedLimit))
        let next: Int
        if let since {
            next = (filtered.last?.id ?? (since - 1)) + 1
        } else {
            next = (entries.last?.id ?? -1) + 1
        }
        return (limited, next)
    }

    public func clear() {
        entries.removeAll()
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let clamped = max(0, min(1, p))
        let index = Int(Double(values.count - 1) * clamped)
        return values[index]
    }
}

public enum DebugMetrics {
    public static var isEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    public static func record(_ name: String, duration: TimeInterval, metadata: [String: Any]? = nil) {
        guard isEnabled else { return }
        let normalized = normalize(metadata)
        Task {
            await DebugMetricStore.shared.record(name: name, duration: duration, metadata: normalized)
        }
    }

    public static func measure<T>(_ name: String,
                                  metadata: [String: Any]? = nil,
                                  _ block: () async throws -> T) async rethrows -> T {
        let start = Date()
        let result = try await block()
        record(name, duration: Date().timeIntervalSince(start), metadata: metadata)
        return result
    }

    public static func measureSync<T>(_ name: String,
                                      metadata: [String: Any]? = nil,
                                      _ block: () throws -> T) rethrows -> T {
        let start = Date()
        let result = try block()
        record(name, duration: Date().timeIntervalSince(start), metadata: metadata)
        return result
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
