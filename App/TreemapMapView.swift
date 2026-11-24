import AppKit
import os
import QuadratCore
import QuartzCore
import SwiftUI

/// Each tile is its own layer: a rounded rect fill, optional vector hatch, and a text layer.
/// Hover only moves the highlight layer. Nothing here assigns a contents image.
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
    private var headerLayers: [CALayer] = []
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
            let band = headerLayers[index]
            if index < tiles.count {
                let tile = tiles[index]
                let rect = CGRect(x: tile.x, y: tile.y, width: max(tile.width, 0), height: max(tile.height, 0))
                box.frame = rect
                box.isHidden = rect.width < 1 || rect.height < 1
                let rgb = QuadratTheme.components(tile.kind, scheme, variant: tile.id)
                let group = tile.header > 1 ? 0.62 : 1.0
                box.backgroundColor = NSColor(
                    calibratedRed: rgb.0 * group,
                    green: rgb.1 * group,
                    blue: rgb.2 * group,
                    alpha: 1
                ).cgColor
                box.cornerRadius = min(5, max(2, min(rect.width, rect.height) / 4))
                box.contents = nil
                box.contentsScale = scale
                box.shouldRasterize = false
                box.masksToBounds = true
                box.sublayers?.filter { $0.name == "hatch" }.forEach { $0.removeFromSuperlayer() }
                if tile.hatched {
                    addHatch(to: box, size: rect.size, scale: scale)
                }
                if tile.header > 1, tile.showsLabel {
                    band.isHidden = false
                    band.frame = CGRect(x: 0, y: 0, width: rect.width, height: tile.header)
                    band.backgroundColor = NSColor.black.withAlphaComponent(scheme == .dark ? 0.28 : 0.16).cgColor
                    label.frame = CGRect(x: 8, y: 1, width: max(0, rect.width - 16), height: max(0, tile.header - 2))
                    label.string = "\(tile.name)  \(tile.sizeText)"
                } else {
                    band.isHidden = true
                    label.frame = CGRect(x: 8, y: 6, width: max(0, rect.width - 16), height: min(34, max(0, rect.height - 8)))
                    label.string = tile.height >= 36 ? "\(tile.name)\n\(tile.sizeText)" : tile.name
                }
                label.isHidden = !tile.showsLabel || tile.name.isEmpty
                label.contentsScale = scale
            } else {
                box.isHidden = true
                label.isHidden = true
                band.isHidden = true
            }
        }
        CATransaction.commit()
    }

    private func addHatch(to box: CALayer, size: CGSize, scale: CGFloat) {
        let spacing: CGFloat = 8
        var x = -size.height
        while x < size.width {
            let line = CAShapeLayer()
            line.name = "hatch"
            line.contentsScale = scale
            line.shouldRasterize = false
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
            box.shouldRasterize = false
            let label = CATextLayer()
            label.contentsScale = scale
            label.fontSize = 12
            label.foregroundColor = NSColor.white.cgColor
            label.alignmentMode = .left
            label.isWrapped = true
            label.truncationMode = .none
            let band = CALayer()
            band.zPosition = 0.5
            label.zPosition = 1
            box.addSublayer(band)
            box.addSublayer(label)
            tilesLayer.addSublayer(box)
            tileLayers.append(box)
            labelLayers.append(label)
            headerLayers.append(band)
        }
    }
}
