import AppKit

/// Browser tab capture via Apple Events: find the tab by remembered title
/// (fallback: active tab), run JS in it, fall back to a plain HTTP fetch of
/// the URL.
enum BrowserCapture {
    enum Family { case chromium, safari }

    static func family(of entry: HistoryEntry) -> (Family, String)? {
        if let name = Config.chromiumBundles[entry.bundleID] { return (.chromium, name) }
        if let name = Config.safariBundles[entry.bundleID] { return (.safari, name) }
        return nil
    }

    private static func escAS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            csLog("AppleScript failed:", error)
            return nil
        }
        return result
    }

    private static func resolveTabScript(family: Family, appName: String,
                                         wantedTitle: String,
                                         joinedReturn: Bool) -> String {
        let titleProp = family == .chromium ? "title" : "name"
        let activeTab = family == .chromium ? "active tab" : "current tab"
        let ret = joinedReturn
            ? "return theURL & \"\\n\" & theTitle"
            : "return {theURL, theTitle}"
        return """
        tell application "\(appName)"
        	set wanted to "\(escAS(wantedTitle))"
        	set theURL to ""
        	set theTitle to ""
        	repeat with w in windows
        		repeat with t in tabs of w
        			if (\(titleProp) of t as text) is wanted then
        				set theURL to URL of t
        				set theTitle to \(titleProp) of t
        			end if
        		end repeat
        	end repeat
        	if theURL is "" then
        		set theURL to URL of \(activeTab) of front window
        		set theTitle to \(titleProp) of \(activeTab) of front window
        	end if
        	\(ret)
        end tell
        """
    }

    /// Find the tab matching the remembered window title (the tab may have
    /// moved or another tab may be active now); fall back to the active tab.
    static func resolveTab(family: Family, appName: String,
                           wantedTitle: String) -> (url: String, title: String)? {
        let script = resolveTabScript(family: family, appName: appName,
                                      wantedTitle: wantedTitle, joinedReturn: false)
        guard let result = runAppleScript(script), result.numberOfItems >= 1,
              let url = result.atIndex(1)?.stringValue, !url.isEmpty else { return nil }
        let title = result.atIndex(2)?.stringValue ?? ""
        return (url, title)
    }

    /// Fresh prefetched tab metadata for the entry, if any.
    static func cachedTab(_ entry: HistoryEntry) -> (url: String, title: String)? {
        guard let c = entry.cachedTab, Date().timeIntervalSince(c.at) < 10
        else { return nil }
        return (c.url, c.title)
    }

    /// Resolve the tab's URL + title in the background (osascript subprocess
    /// — safe off the main thread, unlike NSAppleScript) so link and page
    /// captures skip the AppleScript round trip at pick time. Metadata only,
    /// no page content is touched.
    static func prefetchTab(_ entry: HistoryEntry) {
        guard let (family, appName) = family(of: entry),
              cachedTab(entry) == nil else { return }
        let script = resolveTabScript(family: family, appName: appName,
                                      wantedTitle: entry.title, joinedReturn: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do { try proc.run() } catch { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  let out = String(data: data, encoding: .utf8) else { return }
            let parts = out.split(separator: "\n", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let url = parts.first, !url.isEmpty else { return }
            let title = parts.count > 1 ? parts[1] : ""
            DispatchQueue.main.async {
                entry.cachedTab = (url, title, Date())
                entry.knownTab = (url, title, Date())
            }
        }
    }

    /// Last known tab metadata, any age — the closed-tab fallback.
    static func knownTab(_ entry: HistoryEntry) -> (url: String, title: String)? {
        guard let k = entry.knownTab else { return nil }
        return (k.url, k.title)
    }

    /// Run JavaScript in the remembered tab (needs "Allow JavaScript from
    /// Apple Events" enabled in the browser). Returns the result string or nil.
    static func runTabJS(family: Family, appName: String,
                         wantedTitle: String, js: String) -> String? {
        let titleProp = family == .chromium ? "title" : "name"
        let activeTab = family == .chromium ? "active tab" : "current tab"
        let execute = family == .chromium
            ? "execute theTab javascript \"\(escAS(js))\""
            : "do JavaScript \"\(escAS(js))\" in theTab"
        let script = """
        tell application "\(appName)"
        	set wanted to "\(escAS(wantedTitle))"
        	set theTab to missing value
        	repeat with w in windows
        		repeat with t in tabs of w
        			if (\(titleProp) of t as text) is wanted then set theTab to t
        		end repeat
        	end repeat
        	if theTab is missing value then set theTab to \(activeTab) of front window
        	return \(execute)
        end tell
        """
        guard let result = runAppleScript(script),
              let s = result.stringValue, !s.isEmpty else { return nil }
        return s
    }

    /// Convert an HTML string to plain text using macOS textutil.
    static func htmlToText(_ html: String, cb: @escaping (String?) -> Void) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".html")
        do {
            try html.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            cb(nil)
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        proc.arguments = ["-convert", "txt", "-stdout", tmp.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        DispatchQueue.global().async {
            do {
                try proc.run()
            } catch {
                DispatchQueue.main.async { cb(nil) }
                return
            }
            // Read while running so a large output can't fill the pipe buffer.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            try? FileManager.default.removeItem(at: tmp)
            let out = String(data: data, encoding: .utf8)
            DispatchQueue.main.async {
                cb(proc.terminationStatus == 0 && out?.isEmpty == false ? out : nil)
            }
        }
    }

    /// Page content without delivery — shared by the single capture action
    /// and multi-select stacking. Completion on main:
    /// (content, sourceURL, kindLabel) or (nil, nil, failureReason).
    static func fetchPage(_ entry: HistoryEntry, wantHTML: Bool,
                          completion: @escaping (String?, String?, String) -> Void) {
        guard let (family, appName) = family(of: entry) else {
            completion(nil, nil, "not a browser window")
            return
        }
        let resolved = cachedTab(entry)
            ?? resolveTab(family: family, appName: appName, wantedTitle: entry.title)
            ?? knownTab(entry)
        let url = resolved?.url

        // Preferred: run JS in the live tab — sees the rendered page,
        // including logged-in content and SPAs.
        let js = wantHTML ? "document.documentElement.outerHTML" : "document.body.innerText"
        if let res = runTabJS(family: family, appName: appName,
                              wantedTitle: entry.title, js: js) {
            completion(res, url, wantHTML ? "full HTML" : "page text")
            return
        }

        // Fallback: plain fetch of the URL (no login/session, but always works).
        guard let url, let fetchURL = URL(string: url) else {
            completion(nil, nil, "Could not get a URL from \(appName) "
                       + "(check Automation permission for ContextStack)")
            return
        }
        URLSession.shared.dataTask(with: fetchURL) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data,
                  let body = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                DispatchQueue.main.async {
                    completion(nil, url, "Fetch failed (\(status)) for \(url)")
                }
                return
            }
            DispatchQueue.main.async {
                if wantHTML {
                    completion(body, url, "full HTML (fetched)")
                } else {
                    htmlToText(body) { txt in
                        if let txt {
                            completion(txt, url, "page text (fetched)")
                        } else {
                            completion(body, url, "raw HTML (fetched)")
                        }
                    }
                }
            }
        }.resume()
    }

    static func capturePage(_ entry: HistoryEntry, wantHTML: Bool) {
        fetchPage(entry, wantHTML: wantHTML) { content, url, kind in
            if let content {
                Delivery.text(entry: entry, kind: kind, source: url, content: content)
            } else {
                Delivery.failure("ContextStack", kind)
            }
        }
    }

    static func captureLink(_ entry: HistoryEntry) {
        guard let (family, appName) = family(of: entry) else { return }
        guard let (url, title) = cachedTab(entry)
                ?? resolveTab(family: family, appName: appName,
                              wantedTitle: entry.title)
                ?? knownTab(entry) else {
            Delivery.failure("ContextStack", "Could not get a URL from \(appName)")
            return
        }
        let label = title.isEmpty ? (entry.title.isEmpty ? url : entry.title) : title
        Delivery.setClipboard("[\(label)](\(url))")
        Delivery.notify("ContextStack: link copied", url)
        Delivery.maybeAutoPaste()
    }
}
