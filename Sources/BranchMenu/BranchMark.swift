import AppKit

/// The app's mark: a trunk with two commits and a branch whose tip is a session, orange when it
/// waits for you. Drawn in code so the app icon and the menu bar icon share one shape.
enum BranchMark {
    // The shape in a unit square, y up.
    private static let trunkX = 0.28
    private static let bottomY = 0.14
    private static let topY = 0.86
    private static let forkY = 0.30
    private static let tip = CGPoint(x: 0.76, y: 0.62)

    static let orange = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1)

    private static func point(_ x: Double, _ y: Double, in box: CGRect) -> CGPoint {
        CGPoint(x: box.minX + x * box.width, y: box.minY + y * box.height)
    }

    /// Trunk and branch, to be stroked with round caps.
    private static func lines(in box: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: point(trunkX, bottomY, in: box))
        path.addLine(to: point(trunkX, topY, in: box))
        path.move(to: point(trunkX, forkY, in: box))
        path.addCurve(
            to: point(tip.x, tip.y, in: box),
            control1: point(trunkX, forkY + 0.20, in: box),
            control2: point(tip.x, tip.y - 0.30, in: box)
        )
        return path
    }

    private static func dot(at center: CGPoint, radius: Double) -> CGPath {
        CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
    }

    /// Draws the mark into `box`: lines and commits in `ink`, the tip in `tipColor`.
    private static func draw(in box: CGRect, context: CGContext, line: Double, radius: Double,
                             tipRadius: Double, ink: CGColor, tipColor: CGColor) {
        context.saveGState()
        context.setStrokeColor(ink)
        context.setLineWidth(line * box.width)
        context.setLineCap(.round)
        context.addPath(lines(in: box))
        context.strokePath()
        context.setFillColor(ink)
        for y in [bottomY, topY] {
            context.addPath(dot(at: point(trunkX, y, in: box), radius: radius * box.width))
        }
        context.fillPath()
        context.setFillColor(tipColor)
        context.addPath(dot(at: point(tip.x, tip.y, in: box), radius: tipRadius * box.width))
        context.fillPath()
        context.restoreGState()
    }

    // MARK: App icon

    /// The app icon on Apple's 1024 grid: a rounded square with a 100 pt margin, deep indigo,
    /// with the mark in white and its tip glowing orange.
    static func appIcon(pixels: Int) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = Double(pixels) / 1024
        context.scaleBy(x: scale, y: scale)
        context.interpolationQuality = .high

        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

        // Drop shadow under the body.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
        context.addPath(shape)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(shape)
        context.clip()
        let background = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.33, green: 0.38, blue: 0.96, alpha: 1),
            CGColor(srgbRed: 0.16, green: 0.15, blue: 0.48, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(background, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        // A soft sheen on the upper half.
        let sheen = CGGradient(colorsSpace: space, colors: [
            CGColor(gray: 1, alpha: 0.16), CGColor(gray: 1, alpha: 0),
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 520), options: [])

        let box = body.insetBy(dx: 140, dy: 140)
        let tipCenter = point(tip.x, tip.y, in: box)
        // The orange glow behind the tip.
        let glow = CGGradient(colorsSpace: space, colors: [
            orange.withAlphaComponent(0.55).cgColor, orange.withAlphaComponent(0).cgColor,
        ] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(glow, startCenter: tipCenter, startRadius: 0, endCenter: tipCenter, endRadius: 190, options: [])

        context.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: CGColor(gray: 0, alpha: 0.28))
        draw(in: box, context: context, line: 0.08, radius: 0.095, tipRadius: 0.125,
             ink: CGColor(gray: 1, alpha: 1), tipColor: orange.cgColor)
        context.restoreGState()
        return context.makeImage()
    }

    /// Writes an `.iconset` folder for `iconutil -c icns`.
    static func writeIconset(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                guard let image = appIcon(pixels: points * scale),
                      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                else { continue }
                try data.write(to: folder.appendingPathComponent(name))
            }
        }
    }

    // MARK: Menu bar

    private static let glyphSize = 18.0
    private static let height = 20.0
    // Deeper than `orange`, so the white count stays readable.
    private static let barOrange = NSColor(srgbRed: 0.93, green: 0.45, blue: 0.0, alpha: 1)

    /// The menu bar icon. With nobody waiting it is a plain template image; otherwise the tip turns
    /// orange and an orange pill next to it holds the count.
    static func statusImage(waiting: Int) -> NSImage {
        let glyph = CGRect(x: 1, y: 1, width: glyphSize, height: glyphSize)
        guard waiting > 0 else {
            let image = NSImage(size: NSSize(width: glyphSize + 2, height: height), flipped: false) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                let black = CGColor(gray: 0, alpha: 1)
                draw(in: glyph, context: context, line: 0.115, radius: 0.14, tipRadius: 0.17, ink: black, tipColor: black)
                return true
            }
            image.isTemplate = true
            image.accessibilityDescription = "Branch Menu"
            return image
        }

        let count = NSAttributedString(string: "\(waiting)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let textSize = count.size()
        let pillHeight = 14.0
        let pillWidth = max(pillHeight, ceil(textSize.width) + 8)
        let gap = 3.0
        let size = NSSize(width: glyph.maxX + gap + pillWidth + 1, height: height)
        // Drawn on demand so the lines follow the menu bar's light or dark appearance.
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: glyph, context: context, line: 0.115, radius: 0.14, tipRadius: 0.17,
                 ink: NSColor.labelColor.cgColor, tipColor: barOrange.cgColor)
            let pill = CGRect(x: glyph.maxX + gap, y: (height - pillHeight) / 2, width: pillWidth, height: pillHeight)
            barOrange.setFill()
            NSBezierPath(roundedRect: pill, xRadius: pillHeight / 2, yRadius: pillHeight / 2).fill()
            count.draw(at: CGPoint(x: pill.midX - textSize.width / 2, y: pill.midY - textSize.height / 2))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Branch Menu, \(waiting) waiting"
        return image
    }
}
