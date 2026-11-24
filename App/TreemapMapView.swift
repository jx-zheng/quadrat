import AppKit
import os
import QuadratCore
import QuartzCore
import SwiftUI

/// Tiles live in one layer contents image. Hover only moves a highlight layer,
/// so a mouse move does not redraw the window or upload the bitmap again.
final class TreemapMapView: NSView {
    static let signposter = OSSignposter(subsystem: "com.kevinzheng.quadrat", category: "treemap")

    var backingScale: CGFloat = 2
    var drawRects: [NSRect] = []
    var onHoverID: ((UInt32?) -> Void)?
    var onClick: ((CGPoint) -> Void)?

    private let tilesLayer = CALayer()
    private let highlightLayer = CALayer()
    private var tileImage: CGImage?
    private var layout = TreemapLayout()
    private var rects: [UInt32: CGRect] = [:]
    private var shownPicture: MapPicture?
    private var shownScheme: ColorScheme?
    private var renderedSize: CGSize = .zero
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        tilesLayer.contentsGravity = .resize
        highlightLayer.borderWidth = 2
        highlightLayer.borderColor = NSColor.black.withAlphaComponent(0.9).cgColor
        highlightLayer.cornerRadius = 3
        highlightLayer.isHidden = true
        highlightLayer.zPosition = 1
        layer?.addSublayer(tilesLayer)
        layer?.addSublayer(highlightLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let scale = resolvedScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tilesLayer.frame = bounds
        tilesLayer.contentsScale = scale
        highlightLayer.contentsScale = scale
        layer?.contentsScale = scale
        CATransaction.commit()
        if bounds.width > 1, bounds.size != renderedSize, let picture = shownPicture, let scheme = shownScheme {
            rebuildImage(tiles: picture.tiles, scheme: scheme)
        }
    }

    var resolvedScale: CGFloat {
        max(backingScale, window?.backingScaleFactor ?? 1)
    }

    func show(picture: MapPicture, scheme: ColorScheme) {
        if picture == shownPicture, scheme == shownScheme { return }
        shownPicture = picture
        shownScheme = scheme
        layout = picture.layout
        rects.removeAll(keepingCapacity: true)
        for tile in picture.tiles {
            rects[tile.id] = CGRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height)
        }
        rebuildImage(tiles: picture.tiles, scheme: scheme)
    }

    func highlight(id: UInt32?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let id, let rect = rects[id] {
            highlightLayer.frame = rect.insetBy(dx: 1, dy: 1)
            highlightLayer.isHidden = false
        } else {
            highlightLayer.isHidden = true
        }
        CATransaction.commit()
    }

    /// The mouse-moved path. Hit-test, move the highlight, flush. Does not redraw tiles.
    @discardableResult
    func moveHover(to point: CGPoint) -> UInt32? {
        let hit = Self.signposter.beginInterval("hit-test")
        let raw = layout.index.hit(nodes: layout.nodes, x: point.x, y: point.y)
        let id = raw.flatMap { rects[$0] == nil ? nil : $0 }
        Self.signposter.endInterval("hit-test", hit)

        let mark = Self.signposter.beginInterval("highlight")
        highlight(id: id)
        CATransaction.flush()
        Self.signposter.endInterval("highlight", mark)
        return id
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let id = moveHover(to: point)
        onHoverID?(id)
    }

    override func mouseExited(with event: NSEvent) {
        highlight(id: nil)
        CATransaction.flush()
        onHoverID?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onClick?(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawRects.append(dirtyRect)
        let width = Int(dirtyRect.width)
        let height = Int(dirtyRect.height)
        Self.signposter.emitEvent("draw", "\(width)x\(height)")
        guard let tileImage, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: dirtyRect)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(tileImage, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }

    private func rebuildImage(tiles: [TileDraw], scheme: ColorScheme) {
        let scale = resolvedScale
        let previous = tileImage
        tileImage = nil
        tilesLayer.contents = nil
        _ = previous
        let size = bounds.width > 1 ? bounds.size : CGSize(width: 1440, height: 900)
        renderedSize = size
        let image = Self.render(tiles: tiles, size: size, scale: scale, scheme: scheme)
        tileImage = image
        tilesLayer.contents = image
        tilesLayer.contentsScale = scale
    }

    private static func render(tiles: [TileDraw], size: CGSize, scale: CGFloat, scheme: ColorScheme) -> CGImage? {
        let pixelsWide = max(1, Int((size.width * scale).rounded(.up)))
        let pixelsHigh = max(1, Int((size.height * scale).rounded(.up)))
        guard let context = CGContext(
            data: nil,
            width: pixelsWide,
            height: pixelsHigh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let canvas = scheme == .dark
            ? NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            : NSColor(calibratedWhite: 0.95, alpha: 1)
        canvas.setFill()
        NSRect(origin: .zero, size: size).fill()
        for tile in tiles {
            let rect = NSRect(x: tile.x, y: tile.y, width: max(tile.width, 0), height: max(tile.height, 0))
            guard rect.width >= 1, rect.height >= 1 else { continue }
            let rgb = QuadratTheme.components(tile.kind, scheme, variant: tile.id)
            NSColor(calibratedRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1).setFill()
            let radius = min(5, max(2, min(rect.width, rect.height) / 4))
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            if tile.hatched {
                drawHatch(in: rect)
            } else if tile.isDepthCapped {
                drawStipple(in: rect, seed: tile.id)
            }
            guard tile.showsLabel, !tile.name.isEmpty else { continue }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byClipping
            let name = NSAttributedString(string: tile.name, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ])
            name.draw(in: rect.insetBy(dx: 8, dy: 6))
            if rect.height >= 36 {
                let sizeText = NSAttributedString(string: tile.sizeText, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.92),
                    .paragraphStyle: paragraph
                ])
                sizeText.draw(at: NSPoint(x: rect.minX + 8, y: rect.minY + 22))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func drawHatch(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        NSColor.white.withAlphaComponent(0.28).setStroke()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: rect.maxY))
            path.line(to: NSPoint(x: x + rect.height, y: rect.minY))
            path.lineWidth = 1
            path.stroke()
            x += 7
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawStipple(in rect: NSRect, seed: UInt32) {
        guard rect.width >= 48, rect.height >= 36 else { return }
        NSColor.white.withAlphaComponent(0.22).setFill()
        var rng = seed == 0 ? 1 : seed
        for _ in 0..<14 {
            rng = rng &* 1664525 &+ 1013904223
            let px = rect.minX + CGFloat(rng % 1000) / 1000 * rect.width
            rng = rng &* 1664525 &+ 1013904223
            let py = rect.minY + CGFloat(rng % 1000) / 1000 * rect.height
            NSBezierPath(ovalIn: NSRect(x: px, y: py, width: 2.5, height: 2.5)).fill()
        }
    }
}
