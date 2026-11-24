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
    private var tileLayers: [CALayer] = []
    private var labelLayers: [CATextLayer] = []
    private var tileLayout = TreemapLayout()
    private var rects: [UInt32: CGRect] = [:]
    private var shownPicture: MapPicture?
    private var shownScheme: ColorScheme?
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
    }

    var resolvedScale: CGFloat {
        max(backingScale, window?.backingScaleFactor ?? 1)
    }

    func show(picture: MapPicture, scheme: ColorScheme) {
        if picture == shownPicture, scheme == shownScheme { return }
        shownPicture = picture
        shownScheme = scheme
        tileLayout = picture.layout
        rects.removeAll(keepingCapacity: true)
        for tile in picture.tiles {
            rects[tile.id] = CGRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height)
        }
        applyTiles(picture.tiles, scheme: scheme)
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
        let raw = tileLayout.index.hit(nodes: tileLayout.nodes, x: point.x, y: point.y)
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
    }

    private func applyTiles(_ tiles: [TileDraw], scheme: ColorScheme) {
        let scale = resolvedScale
        ensurePool(count: max(tiles.count, 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let canvas = scheme == .dark
            ? NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).cgColor
            : NSColor(calibratedWhite: 0.95, alpha: 1).cgColor
        tilesLayer.backgroundColor = canvas
        for index in tileLayers.indices {
            let box = tileLayers[index]
            let label = labelLayers[index]
            if index < tiles.count {
                let tile = tiles[index]
                let rect = CGRect(x: tile.x, y: tile.y, width: max(tile.width, 0), height: max(tile.height, 0))
                box.frame = rect
                box.isHidden = rect.width < 1 || rect.height < 1
                let rgb = QuadratTheme.components(tile.kind, scheme, variant: tile.id)
                box.backgroundColor = NSColor(calibratedRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1).cgColor
                box.cornerRadius = min(5, max(2, min(rect.width, rect.height) / 4))
                box.contents = nil
                box.sublayers?.filter { $0.name == "hatch" }.forEach { $0.removeFromSuperlayer() }
                if tile.hatched {
                    addHatch(to: box, size: rect.size)
                }
                label.isHidden = !tile.showsLabel || tile.name.isEmpty || rect.width < 36
                label.frame = CGRect(x: 8, y: 6, width: max(0, rect.width - 16), height: min(32, max(0, rect.height - 10)))
                label.string = tile.showsLabel && rect.height >= 36 ? "\(tile.name)\n\(tile.sizeText)" : tile.name
                label.contentsScale = scale
            } else {
                box.isHidden = true
                label.isHidden = true
            }
        }
        CATransaction.commit()
    }

    private func addHatch(to box: CALayer, size: CGSize) {
        let spacing: CGFloat = 8
        var x = -size.height
        while x < size.width {
            let line = CAShapeLayer()
            line.name = "hatch"
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: size.height))
            path.addLine(to: CGPoint(x: x + size.height, y: 0))
            line.path = path
            line.strokeColor = NSColor.white.withAlphaComponent(0.35).cgColor
            line.lineWidth = 1
            line.frame = CGRect(origin: .zero, size: size)
            line.zPosition = 0
            box.insertSublayer(line, at: 0)
            x += spacing
        }
    }

    private func ensurePool(count: Int) {
        guard tileLayers.count < count else { return }
        let scale = resolvedScale
        while tileLayers.count < count {
            let box = CALayer()
            box.contentsScale = scale
            let label = CATextLayer()
            label.contentsScale = scale
            label.fontSize = 11
            label.foregroundColor = NSColor.white.cgColor
            label.alignmentMode = .left
            label.isWrapped = false
            label.truncationMode = .none
            label.contentsScale = 1
            box.addSublayer(label)
            tilesLayer.addSublayer(box)
            tileLayers.append(box)
            labelLayers.append(label)
        }
    }
}
