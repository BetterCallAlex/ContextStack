import AppKit
import ApplicationServices

/// Document-window capture via the AXDocument accessibility attribute
/// (Preview, TextEdit, Xcode, …): path, @-reference, file contents.
enum DocumentCapture {
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "rst", "py", "js",
        "ts", "tsx", "jsx", "json", "yaml", "yml",
        "toml", "ini", "cfg", "conf", "sh", "bash",
        "zsh", "lua", "c", "h", "cpp", "hpp",
        "rs", "go", "java", "swift", "kt", "rb",
        "php", "html", "htm", "css", "scss", "xml",
        "csv", "tsv", "log", "sql", "tex", "bib",
    ]

    /// Absolute file path of the window's document, or nil.
    static func documentPath(_ entry: HistoryEntry) -> String? {
        guard let doc = AX.string(entry.axWindow, "AXDocument"), !doc.isEmpty
        else { return nil }
        if doc.hasPrefix("file://") {
            return URL(string: doc)?.path
        }
        return doc.removingPercentEncoding ?? doc
    }

    static func readTextFile(_ path: String) -> (text: String?, error: String?) {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, textExtensions.contains(ext) else {
            return (nil, "not a text file (by extension)")
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return (nil, "cannot open file")
        }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: Config.maxFileBytes + 1)
        if data.contains(0) { return (nil, "binary file") }
        guard var text = String(data: data, encoding: .utf8) else {
            return (nil, "not valid UTF-8")
        }
        if data.count > Config.maxFileBytes {
            text = String(text.prefix(Config.maxFileBytes))
                + "\n\n[... truncated by ContextStack ...]"
        }
        return (text, nil)
    }
}
