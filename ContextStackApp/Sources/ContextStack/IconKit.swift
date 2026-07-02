import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The ContextStack mark: three rounded "context cards" fanned like a hand
/// of cards, the top one tilted and carrying two text lines — a piece of
/// context being picked up. Everything is drawn in code: the app icon
/// (.icns) is rendered by `--render-icon` at build time and the menu-bar
/// icon is drawn at runtime as a template image, so the repo carries no
/// binary image assets.
enum IconKit {
    private struct Card {
        let rotation: CGFloat  // degrees, counterclockwise
        let offset: CGPoint    // fraction of the content rect
        let alpha: CGFloat
    }

    private static let cards: [Card] = [
        Card(rotation: -12, offset: CGPoint(x: -0.07, y: -0.11), alpha: 0.50),
        Card(rotation: -2, offset: CGPoint(x: 0.00, y: -0.01), alpha: 0.72),
        Card(rotation: 8, offset: CGPoint(x: 0.06, y: 0.10), alpha: 1.00),
    ]

    // Warm coral gradient — modern, a bit playful, and not another blue icon.
    private static let gradientTop = CGColor(red: 1.00, green: 0.62, blue: 0.36, alpha: 1)
    private static let gradientBottom = CGColor(red: 1.00, green: 0.36, blue: 0.48, alpha: 1)
    private static let accent = CGColor(red: 0.98, green: 0.42, blue: 0.47, alpha: 0.95)

    // ------------------------------------------------------------ card stack

    private static func drawCardStack(_ ctx: CGContext, content: CGRect, mono: Bool) {
        let cardW = content.width * 0.66
        let cardH = content.height * 0.48
        let corner = cardW * 0.14

        for (i, card) in cards.enumerated() {
            let cx = content.midX + card.offset.x * content.width
            let cy = content.midY + card.offset.y * content.height
            let rect = CGRect(x: -cardW / 2, y: -cardH / 2, width: cardW, height: cardH)
            let path = CGPath(roundedRect: rect, cornerWidth: corner,
                              cornerHeight: corner, transform: nil)

            ctx.saveGState()
            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: card.rotation * .pi / 180)
            if !mono {
                ctx.setShadow(offset: CGSize(width: 0, height: -content.height * 0.02),
                              blur: content.height * 0.05,
                              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.22))
            }
            ctx.setFillColor(CGColor(gray: mono ? 0 : 1, alpha: card.alpha))
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()

            // Two text lines on the top card — the "context" being grabbed.
            guard i == cards.count - 1, !mono else { continue }
            ctx.saveGState()
            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: card.rotation * .pi / 180)
            let lineH = cardH * 0.13
            let x0 = -cardW / 2 + cardW * 0.14
            var lineTop = cardH / 2 - cardH * 0.24
            ctx.setFillColor(accent)
            for widthFraction in [0.52, 0.34] {
                let line = CGRect(x: x0, y: lineTop - lineH,
                                  width: cardW * widthFraction, height: lineH)
                ctx.addPath(CGPath(roundedRect: line, cornerWidth: lineH / 2,
                                   cornerHeight: lineH / 2, transform: nil))
                lineTop -= lineH * 2.1
            }
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    // ------------------------------------------------------------- app icon

    /// Full app icon at the given pixel size: gradient rounded-rect tile
    /// (Big Sur margins) with the white card fan on top.
    static func renderAppIcon(pixels: Int) -> CGImage? {
        let s = CGFloat(pixels)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let inset = s * 0.098
        let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225,
                              cornerHeight: tile.width * 0.225, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.02,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
        ctx.addPath(tilePath)
        ctx.setFillColor(gradientBottom)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.clip()
        if let gradient = CGGradient(colorsSpace: space,
                                     colors: [gradientTop, gradientBottom] as CFArray,
                                     locations: [0, 1]) {
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: tile.minX, y: tile.maxY),
                                   end: CGPoint(x: tile.maxX, y: tile.minY),
                                   options: [])
        }
        drawCardStack(ctx, content: tile.insetBy(dx: tile.width * 0.15,
                                                 dy: tile.height * 0.15)
                                        .offsetBy(dx: 0, dy: -tile.height * 0.02),
                      mono: false)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// Write a complete .iconset directory (for `iconutil -c icns`) plus a
    /// 512px preview.png.
    static func renderIconset(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let variants: [(points: Int, scale: Int)] = [
            (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
            (256, 1), (256, 2), (512, 1), (512, 2),
        ]
        for v in variants {
            let suffix = v.scale == 2 ? "@2x" : ""
            let url = dir.appendingPathComponent("icon_\(v.points)x\(v.points)\(suffix).png")
            writePNG(renderAppIcon(pixels: v.points * v.scale), to: url)
        }
        writePNG(renderAppIcon(pixels: 512), to: dir.appendingPathComponent("preview.png"))
        writePNG(renderMenuBarPreview(pixels: 72),
                 to: dir.appendingPathComponent("preview-menubar.png"))
        print("iconset written to \(dir.path)")
    }

    /// The mono/template rendition at preview scale (menu bar is 18pt).
    private static func renderMenuBarPreview(pixels: Int) -> CGImage? {
        let s = CGFloat(pixels)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let content = CGRect(x: 0, y: 0, width: s, height: s)
            .insetBy(dx: s / 18, dy: s * 2.5 / 18)
        drawCardStack(ctx, content: content, mono: true)
        return ctx.makeImage()
    }

    static func writePNG(_ image: CGImage?, to url: URL) {
        guard let image,
              let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    // ------------------------------------------------------------- menu bar

    /// Monochrome template rendition of the card fan for the status item;
    /// adapts to light/dark menu bars automatically.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawCardStack(ctx, content: rect.insetBy(dx: 1.0, dy: 2.5), mono: true)
            return true
        }
        image.isTemplate = true
        return image
    }
}
