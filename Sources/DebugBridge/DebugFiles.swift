import CryptoKit
import Foundation
import SQLite3

/// Read-only access to files under registered roots, for pulling app data
/// (stores, ledgers, caches) that backups don't carry. Work runs off the main
/// actor; chunks keep each relay message well under its size limit.
enum DebugFiles {
    static let maxChunk = 1 << 20
    static let snapshotRoot = "snapshots"

    static var snapshotDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DebugBridgeSnapshots", isDirectory: true)
    }

    enum Failure: Error {
        case badRequest(String)
        case notFound(String)
    }

    /// Resolves `path` under `root`, refusing anything that escapes it.
    static func resolve(root: String?, path: String?, roots: [String: URL]) throws -> URL {
        guard let root, let base = roots[root] else {
            throw Failure.badRequest("Unknown root; one of: \(roots.keys.sorted().joined(separator: ", "))")
        }
        let rootURL = base.standardizedFileURL.resolvingSymlinksInPath()
        let url = rootURL.appendingPathComponent(path ?? "").standardizedFileURL.resolvingSymlinksInPath()
        guard url.path == rootURL.path || url.path.hasPrefix(rootURL.path + "/") else {
            throw Failure.badRequest("Path escapes root")
        }
        return url
    }

    static func list(_ url: URL, recursive: Bool) throws -> [[String: Any]] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw Failure.notFound("No such file: \(url.lastPathComponent)")
        }
        guard isDirectory.boolValue else { return [try entry(url, relativeTo: url.deletingLastPathComponent(), keys: keys)] }
        let children: [URL]
        if recursive {
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
            children = (enumerator?.allObjects as? [URL]) ?? []
        } else {
            children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
        }
        return try children.map { try entry($0, relativeTo: url, keys: keys) }
            .sorted { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
    }

    private static func entry(_ url: URL, relativeTo base: URL, keys: [URLResourceKey]) throws -> [String: Any] {
        let values = try url.resourceValues(forKeys: Set(keys))
        let basePath = base.standardizedFileURL.resolvingSymlinksInPath().path
        let fullPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        var dict: [String: Any] = [
            "path": fullPath.hasPrefix(basePath + "/") ? String(fullPath.dropFirst(basePath.count + 1)) : url.lastPathComponent,
            "isDirectory": values.isDirectory ?? false,
        ]
        if let size = values.fileSize { dict["size"] = size }
        if let modified = values.contentModificationDate { dict["modified"] = modified.timeIntervalSince1970 }
        return dict
    }

    /// One chunk as base64, with the file's size so callers know when to stop.
    static func read(_ url: URL, offset: Int, length: Int) throws -> [String: Any] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.notFound("Cannot open \(url.lastPathComponent)") }
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        try handle.seek(toOffset: UInt64(max(0, min(offset, size))))
        let data = try handle.read(upToCount: max(0, min(length, maxChunk))) ?? Data()
        return ["size": size, "offset": offset, "length": data.count, "data": data.base64EncodedString()]
    }

    static func sha256(_ url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.notFound("Cannot open \(url.lastPathComponent)") }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A consistent copy of a live SQLite database (WAL included) via
    /// VACUUM INTO, served from the snapshots root.
    static func snapshot(_ url: URL) throws -> [String: Any] {
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        let name = url.deletingPathExtension().lastPathComponent + "-" + String(Int(Date().timeIntervalSince1970)) + ".sqlite"
        let out = snapshotDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: out)
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw Failure.badRequest("Cannot open database: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_busy_timeout(db, 5_000)
        let quoted = out.path.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(db, "VACUUM INTO '\(quoted)'", nil, nil, nil) == SQLITE_OK else {
            throw Failure.badRequest("Snapshot failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        let size = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ["root": snapshotRoot, "path": name, "size": size]
    }

    /// Old snapshots are only scratch; drop them before writing another.
    static func pruneSnapshots() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: snapshotDirectory, includingPropertiesForKeys: nil)) ?? []
        urls.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}
