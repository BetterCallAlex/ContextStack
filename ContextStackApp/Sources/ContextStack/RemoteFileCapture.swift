import Foundation
import SQLite3

/// Zed publishes AXDocument for SSH projects with the *remote* path
/// (file:///home/user/project/file.py), so the local read fails. Zed's
/// session database records which SSH connection owns which remote worktree
/// root — match the path to the longest root prefix, then `ssh <host> cat`.
enum RemoteFileCapture {
    struct Connection {
        let host: String
        let port: Int?
        let user: String?
        let rootPath: String
    }

    /// Heuristic: a Zed window naming an absolute path that doesn't exist
    /// locally is a remote (SSH) buffer.
    static func isLikelyRemote(path: String, entry: HistoryEntry) -> Bool {
        entry.bundleID == "dev.zed.Zed"
            && path.hasPrefix("/")
            && !FileManager.default.fileExists(atPath: path)
    }

    /// Find the SSH connection whose workspace root is the longest prefix of
    /// the remote path, from Zed's session db (read-only, immutable open so
    /// a running Zed's locks don't matter).
    static func zedConnection(forRemotePath path: String) -> Connection? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dbDir = support.appendingPathComponent("Zed/db")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dbDir, includingPropertiesForKeys: nil),
              let stable = entries.first(where: { $0.lastPathComponent.hasSuffix("-stable") })
        else { return nil }
        let dbPath = stable.appendingPathComponent("db.sqlite").path

        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(dbPath)?immutable=1", &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT w.paths, c.host, c.port, c.user
        FROM workspaces w
        JOIN remote_connections c ON w.remote_connection_id = c.id
        WHERE c.kind = 'ssh' AND c.host IS NOT NULL AND w.paths IS NOT NULL
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt
        else { return nil }
        defer { sqlite3_finalize(stmt) }

        var best: Connection?
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let pathsC = sqlite3_column_text(stmt, 0),
                  let hostC = sqlite3_column_text(stmt, 1) else { continue }
            let host = String(cString: hostC)
            let port = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int(stmt, 2))
            let user = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            // Multi-root workspaces store newline-separated paths.
            for root in String(cString: pathsC).split(separator: "\n").map(String.init) {
                let normalized = root.hasSuffix("/") ? String(root.dropLast()) : root
                guard !normalized.isEmpty,
                      path == normalized || path.hasPrefix(normalized + "/"),
                      normalized.count > (best?.rootPath.count ?? -1)
                else { continue }
                best = Connection(host: host, port: port,
                                  user: (user?.isEmpty == false) ? user : nil,
                                  rootPath: normalized)
            }
        }
        return best
    }

    /// `ssh host cat -- 'path'` with batch mode (never prompts), connect and
    /// overall timeouts, size cap and binary sniff.
    static func fetch(path: String, via conn: Connection,
                      completion: @escaping (_ text: String?, _ error: String?) -> Void) {
        DispatchQueue.global().async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6"]
            if let port = conn.port { args += ["-p", String(port)] }
            let target = conn.user.map { "\($0)@\(conn.host)" } ?? conn.host
            let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            args += [target, "cat -- \(quoted)"]
            proc.arguments = args

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            do {
                try proc.run()
            } catch {
                DispatchQueue.main.async { completion(nil, error.localizedDescription) }
                return
            }
            let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: killer)
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            killer.cancel()

            guard proc.terminationStatus == 0 else {
                let stderr = String(data: errData, encoding: .utf8)?
                    .split(separator: "\n").last.map(String.init)
                DispatchQueue.main.async {
                    completion(nil, stderr ?? "ssh exited \(proc.terminationStatus)")
                }
                return
            }
            if data.prefix(Config.maxFileBytes).contains(0) {
                DispatchQueue.main.async { completion(nil, "binary file") }
                return
            }
            var text = String(decoding: data.prefix(Config.maxFileBytes), as: UTF8.self)
            if data.count > Config.maxFileBytes {
                text += "\n\n[... truncated by ContextStack ...]"
            }
            DispatchQueue.main.async { completion(text, nil) }
        }
    }
}
