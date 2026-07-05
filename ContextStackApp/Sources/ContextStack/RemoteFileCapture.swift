import AppKit
import SQLite3

/// Fetching file contents from editors working over SSH. The window only
/// points at a *remote* path, so the local read fails; each supported editor
/// leaves enough breadcrumbs locally to resolve (host, remote path):
///
/// - **Zed** publishes the remote path in AXDocument; its session db maps
///   remote worktree roots → SSH connections (host aliases).
/// - **VS Code / Cursor** (and forks) put `[SSH: host]` in the window title;
///   their `state.vscdb` history lists `vscode-remote://ssh-remote+…` folder
///   URIs, giving the remote roots to search for the title's filename. If
///   AXDocument ever carries the `vscode-remote://` URI directly, that wins.
/// - **JetBrains** remote development stores `ssh://user@host:port/path`
///   project URIs in its options XML; the window title carries project name
///   and filename.
///
/// Everything ends in `ssh <host> cat -- <path>` (BatchMode, timeouts, size
/// cap, binary sniff) — key-based auth required, nothing ever prompts.
enum RemoteFileCapture {
    struct Connection {
        let host: String
        let port: Int?
        let user: String?
        var rootPath: String = ""
    }

    /// A resolvable remote file: either an exact path, or a filename to
    /// locate under known remote roots.
    struct Candidate {
        let connection: Connection
        let exactPath: String?
        let filename: String?
        let searchRoots: [String]

        var displayHost: String { connection.host }
    }

    // ------------------------------------------------------------ dispatch

    /// Cheap, synchronous: does this entry look like a remote file we can
    /// resolve? (Title parsing + local db/xml reads only — no network.)
    static func candidate(for entry: HistoryEntry, docPath: String?) -> Candidate? {
        // An explicit vscode-remote:// document URI beats everything.
        if let raw = AX.string(entry.axWindow, "AXDocument"),
           let c = fromVSCodeRemoteURI(raw) {
            return c
        }
        if entry.bundleID == "dev.zed.Zed" {
            return zedCandidate(docPath: docPath)
        }
        if let storeName = Self.vscodeFamilyStores[entry.bundleID] {
            return vscodeCandidate(title: entry.title, storeName: storeName)
        }
        if entry.bundleID.hasPrefix("com.jetbrains") {
            return jetbrainsCandidate(title: entry.title)
        }
        return nil
    }

    /// VS Code and its forks, bundle ID → Application Support dir name.
    static let vscodeFamilyStores: [String: String] = [
        "com.microsoft.VSCode": "Code",
        "com.microsoft.VSCodeInsiders": "Code - Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.vscodium": "VSCodium",
    ]

    /// Resolve (remote find if needed) and fetch the file text.
    static func retrieve(_ candidate: Candidate,
                         completion: @escaping (_ text: String?, _ path: String?,
                                                _ error: String?) -> Void) {
        if let path = candidate.exactPath {
            fetch(path: path, via: candidate.connection) { text, err in
                completion(text, path, err)
            }
            return
        }
        guard let filename = candidate.filename, !candidate.searchRoots.isEmpty else {
            completion(nil, nil, "nothing to search for")
            return
        }
        findRemote(filename: filename, roots: candidate.searchRoots,
                   via: candidate.connection) { path, err in
            guard let path else {
                completion(nil, nil, err ?? "'\(filename)' not found on \(candidate.displayHost)")
                return
            }
            fetch(path: path, via: candidate.connection) { text, ferr in
                completion(text, path, ferr)
            }
        }
    }

    // ----------------------------------------------------------------- Zed

    static func zedCandidate(docPath: String?) -> Candidate? {
        guard let docPath, docPath.hasPrefix("/"),
              !FileManager.default.fileExists(atPath: docPath),
              let conn = zedConnection(forRemotePath: docPath)
        else { return nil }
        return Candidate(connection: conn, exactPath: docPath,
                         filename: nil, searchRoots: [])
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

        var best: Connection?
        query(dbPath: stable.appendingPathComponent("db.sqlite").path,
              sql: """
              SELECT w.paths, c.host, c.port, c.user
              FROM workspaces w
              JOIN remote_connections c ON w.remote_connection_id = c.id
              WHERE c.kind = 'ssh' AND c.host IS NOT NULL AND w.paths IS NOT NULL
              """) { stmt in
            guard let pathsC = sqlite3_column_text(stmt, 0),
                  let hostC = sqlite3_column_text(stmt, 1) else { return }
            let host = String(cString: hostC)
            let port = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int(stmt, 2))
            let user = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
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

    // -------------------------------------------------- VS Code family

    /// "main.py — myproject [SSH: hera] — Visual Studio Code"
    /// (separator can be " — " or " - "; dirty marker "● " may prefix).
    static func parseVSCodeTitle(_ title: String)
        -> (filename: String?, folder: String, hostSpec: String)? {
        let segments = title
            .replacingOccurrences(of: " — ", with: "\u{1}")
            .replacingOccurrences(of: " - ", with: "\u{1}")
            .split(separator: "\u{1}")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "● ")) }
        guard let sshIdx = segments.firstIndex(where: { $0.contains("[SSH:") }),
              let open = segments[sshIdx].range(of: "[SSH:"),
              let close = segments[sshIdx].range(of: "]", range: open.upperBound..<segments[sshIdx].endIndex)
        else { return nil }
        let hostSpec = segments[sshIdx][open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        guard !hostSpec.isEmpty else { return nil }
        let folder = segments[sshIdx][..<open.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let filename = segments[..<sshIdx].first {
            $0.contains(".") && !$0.contains("/") && $0.count <= 64
        }
        return (filename, folder, hostSpec)
    }

    /// "ssh-remote+hera", "ssh-remote+alex@hera:2222", or hex-encoded JSON
    /// ("ssh-remote+7b22686f73744e616d65…" → {"hostName": …}).
    static func decodeRemoteAuthority(_ authority: String) -> Connection? {
        // The "+" is often percent-encoded inside folder URIs.
        let decoded = authority.removingPercentEncoding ?? authority
        guard decoded.hasPrefix("ssh-remote+") else { return nil }
        var spec = String(decoded.dropFirst("ssh-remote+".count))
        if spec.count >= 16, spec.count % 2 == 0,
           spec.allSatisfy(\.isHexDigit),
           let data = Data(hexString: spec),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hostName = obj["hostName"] as? String {
            return Connection(host: hostName,
                              port: obj["port"] as? Int,
                              user: obj["user"] as? String)
        }
        var user: String?
        if let at = spec.lastIndex(of: "@") {
            user = String(spec[..<at])
            spec = String(spec[spec.index(after: at)...])
        }
        var port: Int?
        if let colon = spec.lastIndex(of: ":"), let p = Int(spec[spec.index(after: colon)...]) {
            port = p
            spec = String(spec[..<colon])
        }
        guard !spec.isEmpty else { return nil }
        return Connection(host: spec, port: port, user: user)
    }

    /// A full "vscode-remote://ssh-remote+host/path" document URI.
    static func fromVSCodeRemoteURI(_ uri: String) -> Candidate? {
        guard uri.hasPrefix("vscode-remote://") else { return nil }
        let rest = uri.dropFirst("vscode-remote://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        guard let conn = decodeRemoteAuthority(String(rest[..<slash])) else { return nil }
        let path = String(rest[slash...]).removingPercentEncoding ?? String(rest[slash...])
        return Candidate(connection: conn, exactPath: path, filename: nil, searchRoots: [])
    }

    /// Remote (authority, path) pairs from the recently-opened JSON.
    static func remoteFolders(fromRecentJSON json: String) -> [(authority: String, path: String)] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = obj["entries"] as? [[String: Any]] else { return [] }
        var out: [(String, String)] = []
        for e in entries {
            let uris = [e["folderUri"] as? String,
                        e["fileUri"] as? String,
                        (e["workspace"] as? [String: Any])?["configPath"] as? String]
            for uri in uris.compactMap({ $0 }) where uri.hasPrefix("vscode-remote://") {
                let rest = uri.dropFirst("vscode-remote://".count)
                guard let slash = rest.firstIndex(of: "/") else { continue }
                let path = String(rest[slash...]).removingPercentEncoding
                    ?? String(rest[slash...])
                out.append((String(rest[..<slash]), path))
            }
        }
        return out
    }

    static func vscodeCandidate(title: String, storeName: String) -> Candidate? {
        guard let parsed = parseVSCodeTitle(title), let filename = parsed.filename
        else { return nil }
        var conn = decodeRemoteAuthority("ssh-remote+" + parsed.hostSpec)
            ?? Connection(host: parsed.hostSpec, port: nil, user: nil)

        // Roots for this host from the editor's own history.
        var roots: [String] = []
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first {
            let db = support.appendingPathComponent(
                "\(storeName)/User/globalStorage/state.vscdb").path
            var json: String?
            query(dbPath: db,
                  sql: "SELECT value FROM ItemTable WHERE key='history.recentlyOpenedPathsList'") {
                if let v = sqlite3_column_text($0, 0) { json = String(cString: v) }
            }
            if let json {
                let folders = remoteFolders(fromRecentJSON: json)
                let matching = folders.filter {
                    guard let c = decodeRemoteAuthority($0.authority) else { return false }
                    return c.host == conn.host
                }
                // Prefer roots whose basename matches the title's folder.
                let named = matching.filter {
                    ($0.path as NSString).lastPathComponent == parsed.folder
                }
                roots = (named.isEmpty ? matching : named).map(\.path)
                // The URI authority may know user/port the title doesn't.
                if conn.user == nil, conn.port == nil,
                   let richer = matching.compactMap({ decodeRemoteAuthority($0.authority) })
                       .first(where: { $0.user != nil || $0.port != nil }) {
                    conn = Connection(host: conn.host, port: richer.port, user: richer.user)
                }
            }
        }
        guard !roots.isEmpty else {
            // Host is known from the title even without history — search $HOME.
            return Candidate(connection: conn, exactPath: nil,
                             filename: filename, searchRoots: ["."])
        }
        return Candidate(connection: conn, exactPath: nil,
                         filename: filename, searchRoots: dedupe(roots))
    }

    // ------------------------------------------------------- JetBrains

    /// "ssh://alex@hera:22/home/alex/project" URIs from options XMLs.
    static func jetbrainsSSHProjects(fromXML xml: String)
        -> [(connection: Connection, path: String)] {
        var out: [(Connection, String)] = []
        var search = xml[...]
        while let r = search.range(of: "ssh://") {
            let tail = search[r.upperBound...]
            let end = tail.firstIndex { "\"'<& \n".contains($0) } ?? tail.endIndex
            let body = String(tail[..<end])
            search = tail[end...]
            guard let slash = body.firstIndex(of: "/") else { continue }
            var authority = String(body[..<slash])
            let path = String(body[slash...])
            var user: String?
            if let at = authority.lastIndex(of: "@") {
                user = String(authority[..<at])
                authority = String(authority[authority.index(after: at)...])
            }
            var port: Int?
            if let colon = authority.lastIndex(of: ":"),
               let p = Int(authority[authority.index(after: colon)...]) {
                port = p
                authority = String(authority[..<colon])
            }
            guard !authority.isEmpty, path.count > 1 else { continue }
            out.append((Connection(host: authority, port: port, user: user), path))
        }
        return out
    }

    /// "project – file.py" (JetBrains uses an en dash; hyphen also seen).
    static func parseJetBrainsTitle(_ title: String)
        -> (project: String, filename: String?)? {
        let segments = title
            .replacingOccurrences(of: " – ", with: "\u{1}")
            .replacingOccurrences(of: " — ", with: "\u{1}")
            .replacingOccurrences(of: " - ", with: "\u{1}")
            .split(separator: "\u{1}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let project = segments.first, !project.isEmpty else { return nil }
        let filename = segments.dropFirst().compactMap { seg -> String? in
            let base = (seg as NSString).lastPathComponent
            return base.contains(".") && base.count <= 64 ? base : nil
        }.first
        return (project, filename)
    }

    /// The options-XML scan walks every JetBrains product dir — cache it,
    /// the title parse alone shouldn't trigger disk walks on every pick.
    private static var jetbrainsScanCache:
        (projects: [(connection: Connection, path: String)], at: Date)?

    private static func jetbrainsProjects() -> [(connection: Connection, path: String)] {
        if let cached = jetbrainsScanCache,
           Date().timeIntervalSince(cached.at) < 60 {
            return cached.projects
        }
        var projects: [(connection: Connection, path: String)] = []
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first,
           let products = try? FileManager.default.contentsOfDirectory(
            at: support.appendingPathComponent("JetBrains"),
            includingPropertiesForKeys: nil) {
            for product in products {
                let options = product.appendingPathComponent("options")
                guard let xmls = try? FileManager.default.contentsOfDirectory(
                    at: options, includingPropertiesForKeys: nil) else { continue }
                for xml in xmls where xml.pathExtension == "xml" {
                    if let content = try? String(contentsOf: xml, encoding: .utf8),
                       content.contains("ssh://") {
                        projects.append(contentsOf: jetbrainsSSHProjects(fromXML: content))
                    }
                }
            }
        }
        jetbrainsScanCache = (projects, Date())
        return projects
    }

    static func jetbrainsCandidate(title: String) -> Candidate? {
        guard let parsed = parseJetBrainsTitle(title), let filename = parsed.filename
        else { return nil }
        let projects = jetbrainsProjects()
        guard !projects.isEmpty else { return nil }
        let named = projects.filter {
            ($0.path as NSString).lastPathComponent == parsed.project
        }
        let pool = named.isEmpty ? projects : named
        guard let first = pool.first else { return nil }
        return Candidate(connection: first.connection, exactPath: nil,
                         filename: filename,
                         searchRoots: dedupe(pool.filter {
                             $0.connection.host == first.connection.host
                         }.map(\.path)))
    }

    // ------------------------------------------------------------ plumbing

    private static func dedupe(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func query(dbPath: String, sql: String,
                              row: (OpaquePointer) -> Void) {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(dbPath)?immutable=1", &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt
        else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Run one remote command; completion off the main thread.
    private static func runSSH(_ conn: Connection, command: String, timeout: TimeInterval,
                               done: @escaping (Int32, Data, Data) -> Void) {
        DispatchQueue.global().async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            // Connection multiplexing: the first command pays the handshake,
            // repeats within 60 s ride the same connection (~instant).
            var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6",
                        "-o", "ControlMaster=auto",
                        "-o", "ControlPath=/tmp/contextstack-ssh-%C",
                        "-o", "ControlPersist=60"]
            if let port = conn.port { args += ["-p", String(port)] }
            let target = conn.user.map { "\($0)@\(conn.host)" } ?? conn.host
            args += [target, command]
            proc.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            do {
                try proc.run()
            } catch {
                done(-1, Data(), Data(error.localizedDescription.utf8))
                return
            }
            let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            killer.cancel()
            done(proc.terminationStatus, out, err)
        }
    }

    /// Locate `filename` under the remote roots; shortest hit wins.
    static func findRemote(filename: String, roots: [String], via conn: Connection,
                           completion: @escaping (String?, String?) -> Void) {
        let quotedRoots = roots.prefix(8).map(shellQuote).joined(separator: " ")
        let command = "find \(quotedRoots) -maxdepth 8 -type f -name \(shellQuote(filename)) 2>/dev/null | head -20"
        runSSH(conn, command: command, timeout: 20) { status, out, err in
            let hits = String(decoding: out, as: UTF8.self)
                .split(separator: "\n").map(String.init)
                .sorted { $0.count < $1.count }
            DispatchQueue.main.async {
                if let best = hits.first {
                    completion(best, nil)
                } else {
                    let msg = status == 0 ? nil
                        : String(data: err, encoding: .utf8)?
                            .split(separator: "\n").last.map(String.init)
                    completion(nil, msg)
                }
            }
        }
    }

    /// `ssh host cat -- 'path'` with size cap and binary sniff.
    static func fetch(path: String, via conn: Connection,
                      completion: @escaping (_ text: String?, _ error: String?) -> Void) {
        runSSH(conn, command: "cat -- \(shellQuote(path))", timeout: 15) { status, data, errData in
            DispatchQueue.main.async {
                guard status == 0 else {
                    let stderr = String(data: errData, encoding: .utf8)?
                        .split(separator: "\n").last.map(String.init)
                    completion(nil, stderr ?? "ssh exited \(status)")
                    return
                }
                if data.prefix(Config.maxFileBytes).contains(0) {
                    completion(nil, "binary file")
                    return
                }
                var text = String(decoding: data.prefix(Config.maxFileBytes), as: UTF8.self)
                if data.count > Config.maxFileBytes {
                    text += "\n\n[... truncated by ContextStack ...]"
                }
                completion(text, nil)
            }
        }
    }
}

private extension Data {
    init?(hexString: String) {
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            guard let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex),
                  let byte = UInt8(hexString[index..<next], radix: 16)
            else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
