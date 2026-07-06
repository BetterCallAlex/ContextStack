import AppKit

/// The `~/ContextStack/` archive as a feature: re-paste past captures from
/// the menu, and expire old ones — the archive is a working buffer, not a
/// records system.
enum CaptureArchive {
    struct Item {
        let url: URL
        let date: Date
        let isImage: Bool

        /// "20260706-170345-Zed-thesis--01_edapy.md" → "Zed-thesis--01_edapy"
        var displayName: String {
            let base = url.deletingPathExtension().lastPathComponent
            let parts = base.split(separator: "-", maxSplits: 2)
            return parts.count == 3 ? String(parts[2]) : base
        }

        var menuTitle: String {
            let fmt = DateFormatter()
            fmt.dateFormat = "EEE HH:mm"
            return "\(fmt.string(from: date))  \(displayName)\(isImage ? "  🖼" : "")"
        }
    }

    static func recent(limit: Int = 10, dir: String = Config.captureDir) -> [Item] {
        let dirURL = URL(fileURLWithPath: dir)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles) else { return [] }
        return urls
            .filter { ["md", "png"].contains($0.pathExtension.lowercased()) }
            .compactMap { url -> Item? in
                guard let date = (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]))?.contentModificationDate
                else { return nil }
                return Item(url: url, date: date,
                            isImage: url.pathExtension.lowercased() == "png")
            }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }

    /// Copy a past capture back to the clipboard (and auto-paste): text
    /// captures verbatim (incl. their source header), images as images.
    static func repaste(_ item: Item) {
        if item.isImage {
            guard let image = NSImage(contentsOf: item.url) else {
                Delivery.failure("ContextStack", "Could not read \(item.url.lastPathComponent)")
                return
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
        } else {
            guard let text = try? String(contentsOf: item.url, encoding: .utf8) else {
                Delivery.failure("ContextStack", "Could not read \(item.url.lastPathComponent)")
                return
            }
            Delivery.setClipboard(text)
        }
        Delivery.maybeAutoPaste()
        Delivery.notify("ContextStack: capture re-copied", item.displayName)
    }

    /// Delete archived captures older than the retention window.
    /// retentionDays 0 = keep forever.
    @discardableResult
    static func cleanup(retentionDays: Int = Config.archiveRetentionDays,
                        dir: String = Config.captureDir) -> Int {
        guard retentionDays > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        let dirURL = URL(fileURLWithPath: dir)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles) else { return 0 }
        var removed = 0
        for url in urls where ["md", "png"].contains(url.pathExtension.lowercased()) {
            guard let date = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  date < cutoff else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        if removed > 0 {
            csLog("archive cleanup: removed \(removed) captures older than \(retentionDays)d")
        }
        return removed
    }
}
