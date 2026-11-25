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
    var hasChildren: Bool
    var isRemainder: Bool
    var isDepthCapped: Bool
    var bytes: UInt64
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
            if node.id == root || node.width < 1 || node.height < 1 { continue }
            let files = TileFold.isFiles(node.id)
            let remainder = node.isRemainder || TileFold.isRemainder(node.id)
            let source = files ? TileFold.filesParent(node.id) : (remainder ? TileFold.remainderParent(node.id) : node.id)
            let flags = (remainder || files) ? NodeFlags() : store.flags(node.id)
            let bytes = node.sizeBytes > 0 ? node.sizeBytes : store.bytes(source, metric)
            // A fold or a files tile takes its parent's kind, so Applications stays the apps colour.
            let kind = (remainder || files) ? store.kind(source) : store.kind(node.id)
            let name = node.label.isEmpty
                ? (remainder ? "\(max(node.foldedCount, 1)) smaller items" : store.name(of: node.id))
                : node.label
            tiles.append(TileDraw(
                id: node.id,
                x: node.x,
                y: node.y,
                width: node.width,
                height: node.height,
                header: node.header,
                kind: kind,
                name: name,
                sizeText: ByteFormat.bytes(bytes),
                showsLabel: node.showsLabel,
                hatched: flags.contains(.hatched),
                depth: node.depth,
                hasChildren: node.childCount > 0,
                isRemainder: remainder,
                isDepthCapped: node.isDepthCapped || flags.contains(.collapsed),
                bytes: bytes
            ))
        }
        return MapPicture(tiles: tiles, layout: layout, width: width, height: height, hatch: hatch, unscannedBytes: unread)
    }
}
