import Foundation

/// `ContextStack --remote-selftest` — exercises the remote-editor parsers
/// against fixtures (window titles, vscode-remote URIs, recently-opened
/// JSON, JetBrains options XML). Pure parsing, no network, no editor state.
enum RemoteSelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ got: String?, _ want: String?) {
        let ok = got == want
        if !ok { failures += 1 }
        print("  \(ok ? "ok " : "MISS") \(name): got \(got ?? "nil"), want \(want ?? "nil")")
    }

    static func run() {
        print("remote selftest")

        // ---- VS Code / Cursor window titles
        let t1 = RemoteFileCapture.parseVSCodeTitle(
            "main.py — thesis [SSH: hera] — Visual Studio Code")
        check("vscode em-dash title host", t1?.hostSpec, "hera")
        check("vscode em-dash title file", t1?.filename, "main.py")
        check("vscode em-dash title folder", t1?.folder, "thesis")

        let t2 = RemoteFileCapture.parseVSCodeTitle(
            "● app.tsx - dashboard [SSH: alex@myvm:2222] - Cursor")
        check("cursor hyphen dirty title host", t2?.hostSpec, "alex@myvm:2222")
        check("cursor hyphen dirty title file", t2?.filename, "app.tsx")

        check("local title is not remote",
              RemoteFileCapture.parseVSCodeTitle(
                "main.py — thesis — Visual Studio Code")?.hostSpec, nil)

        // ---- remote authorities
        let a1 = RemoteFileCapture.decodeRemoteAuthority("ssh-remote+hera")
        check("authority plain", a1?.host, "hera")
        let a2 = RemoteFileCapture.decodeRemoteAuthority("ssh-remote+alex@myvm:2222")
        check("authority user", a2?.user, "alex")
        check("authority host", a2?.host, "myvm")
        check("authority port", a2.flatMap { $0.port.map(String.init) }, "2222")
        let a3 = RemoteFileCapture.decodeRemoteAuthority("ssh-remote%2Bhera")
        check("authority percent-encoded plus", a3?.host, "hera")
        let hexJSON = Data(#"{"hostName":"hera","user":"alex","port":2200}"#.utf8)
            .map { String(format: "%02x", $0) }.joined()
        let a4 = RemoteFileCapture.decodeRemoteAuthority("ssh-remote+" + hexJSON)
        check("authority hex-json host", a4?.host, "hera")
        check("authority hex-json user", a4?.user, "alex")

        // ---- full document URI
        let uri = RemoteFileCapture.fromVSCodeRemoteURI(
            "vscode-remote://ssh-remote%2Bhera/home/alex/thesis/main.py")
        check("document URI host", uri?.connection.host, "hera")
        check("document URI path", uri?.exactPath, "/home/alex/thesis/main.py")

        // ---- recently-opened JSON
        let json = """
        {"entries":[
          {"folderUri":"file:///Users/alex/local-project"},
          {"folderUri":"vscode-remote://ssh-remote%2Bhera/home/alex/thesis"},
          {"fileUri":"vscode-remote://ssh-remote%2Bhera/home/alex/notes.md"},
          {"workspace":{"id":"x","configPath":"vscode-remote://ssh-remote%2Bmyvm/home/a/ws.code-workspace"}}
        ]}
        """
        let folders = RemoteFileCapture.remoteFolders(fromRecentJSON: json)
        check("recent JSON remote count", String(folders.count), "3")
        check("recent JSON first path", folders.first?.path, "/home/alex/thesis")
        check("recent JSON local filtered",
              folders.contains { $0.path.contains("local-project") } ? "yes" : "no", "no")

        // ---- JetBrains
        let xml = """
        <application>
          <component name="RecentProjects">
            <entry key="ssh://alex@hera:22/home/alex/thesis" />
            <entry key="ssh://myvm/srv/app" />
          </component>
        </application>
        """
        let projects = RemoteFileCapture.jetbrainsSSHProjects(fromXML: xml)
        check("jetbrains ssh count", String(projects.count), "2")
        check("jetbrains user", projects.first?.connection.user, "alex")
        check("jetbrains host", projects.first?.connection.host, "hera")
        check("jetbrains path", projects.first?.path, "/home/alex/thesis")
        check("jetbrains hostless", projects.last?.connection.host, "myvm")

        let jt = RemoteFileCapture.parseJetBrainsTitle("thesis – src/main.py")
        check("jetbrains title project", jt?.project, "thesis")
        check("jetbrains title file", jt?.filename, "main.py")
        check("jetbrains title no file",
              RemoteFileCapture.parseJetBrainsTitle("thesis – Settings")?.filename, nil)

        print(failures == 0 ? "PASS" : "FAIL (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
