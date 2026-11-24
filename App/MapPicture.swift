import CoreGraphics
import QuadratCore

struct TileDraw: Equatable, Identifiable {
    var id: UInt32
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var header: Double
    var kind: ContentKind
    var name: String
    var sizeText: String
    var showsLabel: Bool
    var hatched: Bool
    var depth: Int
}

struct MapPicture: Equatable {
    var tiles: [TileDraw] = []
    var layout = TreemapLayout(nodes: [], childIndex: [], root: 0, options: TreemapOptions())
    var width: Double = 0
    var height: Double = 0
    var hatch: CGRect = .zero
    var unscannedBytes: UInt64 = 0

    static func make(
        store: NodeStore,
        root: UInt32,
        width: Double,
        height: Double,
        metric: SizeMetric,
        scanned: UInt64?,
        volumeUsed: UInt64?,
        zoomed: Bool
    ) -> MapPicture {
        guard width > 8, height > 8, root != 0 else { return MapPicture() }
        var contentWidth = width
        var hatch = CGRect.zero
        var unread: UInt64 = 0
        if let scanned, let volumeUsed, volumeUsed > scanned {
            let fraction = min(0.92, max(0.08, Double(scanned) / Double(volumeUsed)))
            contentWidth = width * fraction
            hatch = CGRect(x: contentWidth, y: 0, width: width - contentWidth, height: height)
            unread = volumeUsed - scanned
        }
        let options = TreemapOptions.browsing(metric: metric, zoomed: zoomed)
        let layout = TreemapLayout.build(store: store, rootID: root, width: contentWidth, height: height, options: options)
        var tiles: [TileDraw] = []
        tiles.reserveCapacity(layout.nodes.count)
        for node in layout.nodes where node.id != root || node.header > 0 {
            if node.id == root { continue }
            let flags = store.flags(node.id)
            let bytes = store.bytes(node.id, metric)
            tiles.append(TileDraw(
                id: node.id,
                x: node.x,
                y: node.y,
                width: node.width,
                height: node.height,
                header: node.header,
                kind: store.kind(node.id),
                name: store.name(of: node.id),
                sizeText: ByteFormat.bytes(bytes),
                showsLabel: node.showsLabel || node.header > 0,
                hatched: flags.contains(.hatched),
                depth: node.depth
            ))
        }
        return MapPicture(tiles: tiles, layout: layout, width: width, height: height, hatch: hatch, unscannedBytes: unread)
    }
}
