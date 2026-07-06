import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Window screenshots via ScreenCaptureKit (needs the Screen Recording
/// permission). The SCWindow is matched to the AX window by pid + title,
/// falling back to pid + frame.
enum ScreenshotCapture {
    /// Window-list enumeration is the slow half of a capture (~100–300 ms).
    /// It's pure metadata, so it can be prefetched when the action chooser
    /// opens and reused for a few seconds.
    private static var contentCache: (content: SCShareableContent, at: Date)?

    static func prefetchShareableContent() {
        Task { @MainActor in
            if let c = contentCache, Date().timeIntervalSince(c.at) < 5 { return }
            if let content = try? await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: false) {
                contentCache = (content, Date())
            }
        }
    }

    @MainActor
    private static func shareableContent() async throws -> SCShareableContent {
        if let c = contentCache, Date().timeIntervalSince(c.at) < 5 {
            return c.content
        }
        let content = try await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: false)
        contentCache = (content, Date())
        return content
    }

    enum Mode {
        case image   // clipboard image + archived PNG
        case path    // archived PNG, path on clipboard
        case ocr     // pixels → text (Vision) — works where AX can't
    }

    static func capture(_ entry: HistoryEntry, pathOnly: Bool) {
        capture(entry, mode: pathOnly ? .path : .image)
    }

    static func capture(_ entry: HistoryEntry, mode: Mode) {
        Task { @MainActor in
            do {
                let content = try await shareableContent()
                let appWindows = content.windows.filter {
                    $0.owningApplication?.processID == entry.pid
                }
                guard let scWindow = match(entry, in: appWindows) else {
                    Delivery.failure("ContextStack",
                                    "Snapshot failed — window not found (closed?)")
                    return
                }
                // SCContentFilter(desktopIndependentWindow:) hard-aborts the
                // whole process (SkyLight assert) for windows that aren't on
                // the active Space — only use ScreenCaptureKit for on-screen
                // windows, and the legacy CGWindowList path for the rest.
                if scWindow.isOnScreen {
                    do {
                        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                        let cfg = SCStreamConfiguration()
                        let scale = CGFloat(filter.pointPixelScale)
                        cfg.width = max(1, Int(filter.contentRect.width * scale))
                        cfg.height = max(1, Int(filter.contentRect.height * scale))
                        cfg.showsCursor = false
                        let image = try await SCScreenshotManager.captureImage(
                            contentFilter: filter, configuration: cfg)
                        deliver(image, entry: entry, mode: mode)
                        return
                    } catch {
                        csLog("SCK capture failed, trying legacy:", error.localizedDescription)
                    }
                }
                if let image = legacyCapture(windowID: scWindow.windowID) {
                    deliver(image, entry: entry, mode: mode)
                } else {
                    Delivery.failure("ContextStack",
                                    "Snapshot failed — window may be minimized; "
                                    + "bring it on screen and try again")
                }
            } catch {
                Delivery.failure("ContextStack",
                                "Snapshot failed — check the Screen Recording permission "
                                + "(\(error.localizedDescription))")
            }
        }
    }

    private static func match(_ entry: HistoryEntry, in candidates: [SCWindow]) -> SCWindow? {
        if candidates.isEmpty { return nil }
        // Prefer on-screen candidates — only they can be captured.
        let candidates = candidates.filter(\.isOnScreen).isEmpty
            ? candidates : candidates.filter(\.isOnScreen)
        // Current AX title first (tab switches rename browser windows),
        // then the remembered one.
        let currentTitle = AX.string(entry.axWindow, kAXTitleAttribute as String)
        for wanted in [currentTitle, entry.title] {
            if let wanted, !wanted.isEmpty,
               let hit = candidates.first(where: { $0.title == wanted }) {
                return hit
            }
        }
        if let frame = AX.frame(entry.axWindow),
           let hit = candidates.first(where: {
               abs($0.frame.origin.x - frame.origin.x) < 2 &&
               abs($0.frame.origin.y - frame.origin.y) < 2 &&
               abs($0.frame.width - frame.width) < 2 &&
               abs($0.frame.height - frame.height) < 2
           }) {
            return hit
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Legacy CGWindowList capture — deprecated, but the only way to shoot a
    /// window that lives on another Space (ScreenCaptureKit aborts on those).
    static func legacyCapture(windowID: CGWindowID) -> CGImage? {
        CGWindowListCreateImage(.null, .optionIncludingWindow, windowID,
                                [.boundsIgnoreFraming, .bestResolution])
    }

    private static func deliver(_ image: CGImage, entry: HistoryEntry, mode: Mode) {
        if case .ocr = mode {
            recognizeText(in: image) { text in
                if let text {
                    Delivery.text(entry: entry, kind: "screenshot text (OCR)",
                                  source: entry.appName, content: text)
                } else {
                    Delivery.failure("ContextStack",
                                     "No text recognized in the window image")
                }
            }
            return
        }
        let path = Config.captureDir + "/" + Delivery.captureName(entry, ext: "png")

        if case .path = mode {
            // The path is what gets pasted — the file must exist first.
            guard writePNG(image, to: path) else {
                Delivery.failure("ContextStack", "Could not write PNG to \(path)")
                return
            }
            Delivery.setClipboard(path)
            Delivery.maybeAutoPaste()
            Delivery.notify("ContextStack: screenshot path copied", path)
        } else {
            // Clipboard + paste immediately; PNG encode/write can lag behind.
            let nsImage = NSImage(cgImage: image,
                                  size: NSSize(width: image.width, height: image.height))
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([nsImage])
            Delivery.maybeAutoPaste()
            DispatchQueue.global(qos: .utility).async {
                let ok = writePNG(image, to: path)
                Delivery.notify("ContextStack: screenshot copied as image",
                                ok ? "Also saved: \(path)" : "PNG save failed")
            }
        }
    }

    /// On-device Vision OCR; reading order top-to-bottom via bounding boxes.
    private static func recognizeText(in image: CGImage,
                                      completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image)
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let lines = (request.results ?? [])
                .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                .compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async { completion(text.isEmpty ? nil : text) }
        }
    }

    private static func writePNG(_ image: CGImage, to path: String) -> Bool {
        Delivery.ensureDir()
        guard let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL,
            UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
