import Foundation

public struct TreemapOptions: Equatable, Sendable {
    public var metric: SizeMetric
    public var gap: Double
    public var headerHeight: Double
    public var maxHeaderDepth: Int
    public var minRecurseWidth: Double
    public var minRecurseHeight: Double
    public var minChildExtent: Double
    public var pinHatchedAside: Bool

    public init(
        metric: SizeMetric = .allocated,
        gap: Double = 2,
        headerHeight: Double = 19,
        maxHeaderDepth: Int = 4,
        minRecurseWidth: Double = 34,
        minRecurseHeight: Double = 26,
        minChildExtent: Double = 4,
        pinHatchedAside: Bool = false
    ) {
        self.metric = metric
        self.gap = gap
        self.headerHeight = headerHeight
        self.maxHeaderDepth = maxHeaderDepth
        self.minRecurseWidth = minRecurseWidth
        self.minRecurseHeight = minRecurseHeight
        self.minChildExtent = minChildExtent
        self.pinHatchedAside = pinHatchedAside
    }

    public static func browsing(metric: SizeMetric, zoomed: Bool) -> TreemapOptions {
        TreemapOptions(metric: metric, maxHeaderDepth: zoomed ? 2 : 4)
    }
}

public struct TreemapNode: Equatable, Sendable {
    public var id: UInt32
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var header: Double
    public var childStart: Int
    public var childCount: Int
    public var showsLabel: Bool
    public var depth: Int
    /// Combined stand-in for siblings that would have been thinner than the minimum tile.
    public var isRemainder: Bool

    public func contains(_ px: Double, _ py: Double) -> Bool {
        px >= x && py >= y && px < x + width && py < y + height
    }
}

public struct TreemapLayout: Equatable, Sendable {
    public var nodes: [TreemapNode]
    public var childIndex: [Int]
    public var root: Int
    public var options: TreemapOptions

    public init(nodes: [TreemapNode] = [], childIndex: [Int] = [], root: Int = 0, options: TreemapOptions = TreemapOptions()) {
        self.nodes = nodes
        self.childIndex = childIndex
        self.root = root
        self.options = options
    }

    public static func build(store: NodeStore, rootID: UInt32, width: Double, height: Double, options: TreemapOptions) -> TreemapLayout {
        var layout = TreemapLayout(nodes: [], childIndex: [], root: 0, options: options)
        guard rootID != 0, width > 0, height > 0 else { return layout }
        layout.root = layout.place(store: store, id: rootID, x: 0, y: 0, width: width, height: height, depth: 0)
        return layout
    }

    public func children(of index: Int) -> ArraySlice<Int> {
        guard nodes.indices.contains(index) else { return [] }
        let node = nodes[index]
        let start = node.childStart
        let end = start + node.childCount
        guard start >= 0, end <= childIndex.count else { return [] }
        return childIndex[start..<end]
    }

    private mutating func place(store: NodeStore, id: UInt32, x: Double, y: Double, width: Double, height: Double, depth: Int) -> Int {
        let index = nodes.count
        nodes.append(TreemapNode(
            id: id, x: x, y: y, width: width, height: height,
            header: 0, childStart: 0, childCount: 0, showsLabel: false, depth: depth,
            isRemainder: TileFold.isRemainder(id)
        ))
        let kids = TileFold.isRemainder(id) ? [] : childItems(store: store, id: id)
        let canRecurse = !TileFold.isRemainder(id) && width >= options.minRecurseWidth && height >= options.minRecurseHeight && !kids.isEmpty
        let header: Double = (canRecurse && depth >= 1 && depth <= options.maxHeaderDepth && height >= options.headerHeight + 16 && width >= 48)
            ? options.headerHeight : 0
        if !canRecurse {
            nodes[index].showsLabel = LabelPlacement.frame(
                tileX: x, tileY: y, tileWidth: width, tileHeight: height, header: 0
            ).visible
            return index
        }

        let bodyY = y + header
        let bodyH = max(0, height - header)
        let boxes = boxesForChildren(store: store, kids: kids, x: x, y: bodyY, width: width, height: bodyH, parent: id)
        var childNodes: [Int] = []
        childNodes.reserveCapacity(boxes.count)
        for box in boxes {
            if box.width < options.minChildExtent || box.height < options.minChildExtent { continue }
            childNodes.append(place(
                store: store,
                id: box.id,
                x: box.x,
                y: box.y,
                width: box.width,
                height: box.height,
                depth: depth + 1
            ))
        }
        let start = childIndex.count
        childIndex.append(contentsOf: childNodes)
        nodes[index].header = header
        nodes[index].childStart = start
        nodes[index].childCount = childNodes.count
        nodes[index].showsLabel = LabelPlacement.frame(
            tileX: x, tileY: y, tileWidth: width, tileHeight: height, header: header
        ).visible
        return index
    }

    private func childItems(store: NodeStore, id: UInt32) -> [Squarify.Item] {
        var items: [Squarify.Item] = []
        store.forEachChild(id) { child in
            if store.flags(child).contains(.trashed) { return }
            let weight = Double(store.bytes(child, options.metric))
            if weight <= 0 { return }
            items.append(Squarify.Item(id: child, weight: weight))
        }
        return items
    }

    private func boxesForChildren(store: NodeStore, kids: [Squarify.Item], x: Double, y: Double, width: Double, height: Double, parent: UInt32) -> [LayoutBox] {
        let prepared = TileFold.prepare(kids, width: width, height: height, minimumExtent: options.minChildExtent, parent: parent)
        let hatched = prepared.filter { !TileFold.isRemainder($0.id) && store.flags($0.id).contains(.hatched) }
        let solid = prepared.filter { TileFold.isRemainder($0.id) || !store.flags($0.id).contains(.hatched) }
        guard options.pinHatchedAside, let hatch = hatched.max(by: { $0.weight < $1.weight }), !solid.isEmpty, width > 0 else {
            let laid = Squarify.layout(items: prepared, x: x, y: y, width: width, height: height, gap: options.gap)
            return TileFold.absorbSlivers(laid, minimumExtent: options.minChildExtent)
        }
        let total = solid.reduce(0.0) { $0 + $1.weight } + hatch.weight
        let fraction = total > 0 ? solid.reduce(0.0) { $0 + $1.weight } / total : 0.5
        let scannedW = max(0, min(width, width * fraction))
        var boxes = Squarify.layout(items: solid, x: x, y: y, width: max(scannedW, 1), height: height, gap: options.gap)
        boxes.append(LayoutBox(id: hatch.id, x: x + scannedW, y: y, width: max(0, width - scannedW), height: height))
        return TileFold.absorbSlivers(boxes, minimumExtent: options.minChildExtent)
    }
}

public enum HitTest {
    public static func hit(_ layout: TreemapLayout, x: Double, y: Double) -> UInt32? {
        guard layout.nodes.indices.contains(layout.root) else { return nil }
        let root = layout.nodes[layout.root]
        guard root.contains(x, y) else { return nil }
        var index = layout.root
        while true {
            let node = layout.nodes[index]
            if node.header > 0, y < node.y + node.header {
                return node.id
            }
            var next: Int?
            for child in layout.children(of: index) {
                if layout.nodes[child].contains(x, y) {
                    next = child
                    break
                }
            }
            if let next {
                index = next
            } else {
                let id = node.id
                return TileFold.isRemainder(id) ? TileFold.remainderParent(id) : id
            }
        }
    }
}

public enum TileFold {
    public static func remainderID(parent: UInt32) -> UInt32 { parent | 0x8000_0000 }
    public static func isRemainder(_ id: UInt32) -> Bool { id >= 0x8000_0000 }
    public static func remainderParent(_ id: UInt32) -> UInt32 { id & 0x7FFF_FFFF }

    /// Drop children that cannot cover `minimumExtent` on both sides. Their weight becomes one remainder tile when that pile is large enough to draw; otherwise squarify gives the space to the tiles that remain.
    public static func prepare(
        _ items: [Squarify.Item],
        width: Double,
        height: Double,
        minimumExtent: Double,
        parent: UInt32
    ) -> [Squarify.Item] {
        guard minimumExtent > 0, width > 0, height > 0 else { return items }
        let total = items.reduce(0.0) { $0 + max(0, $1.weight) }
        guard total > 0 else { return [] }
        let canvas = width * height
        let minArea = minimumExtent * minimumExtent
        var kept: [Squarify.Item] = []
        var rest = 0.0
        kept.reserveCapacity(items.count)
        for item in items where item.weight > 0 {
            let area = item.weight / total * canvas
            if area >= minArea {
                kept.append(item)
            } else {
                rest += item.weight
            }
        }
        if rest > 0, rest / total * canvas >= minArea {
            kept.append(Squarify.Item(id: remainderID(parent: parent), weight: rest))
        }
        return kept
    }

    /// Give a strip thinner than `minimumExtent` to the tile it shares an edge with, so it is not drawn as its own sliver.
    public static func absorbSlivers(_ boxes: [LayoutBox], minimumExtent: Double) -> [LayoutBox] {
        guard minimumExtent > 0 else { return boxes }
        var kept: [LayoutBox] = []
        var slivers: [LayoutBox] = []
        for box in boxes {
            if box.width >= minimumExtent && box.height >= minimumExtent {
                kept.append(box)
            } else if box.width > 0.5 && box.height > 0.5 {
                slivers.append(box)
            }
        }
        for sliver in slivers {
            guard let index = neighbor(of: sliver, in: kept) else { continue }
            kept[index] = extend(kept[index], over: sliver)
        }
        return kept
    }

    private static func neighbor(of sliver: LayoutBox, in boxes: [LayoutBox]) -> Int? {
        var best: Int?
        var bestScore = 0.0
        for index in boxes.indices {
            let score = sharedEdge(boxes[index], sliver)
            if score > bestScore {
                bestScore = score
                best = index
            }
        }
        return best
    }

    private static func sharedEdge(_ box: LayoutBox, _ sliver: LayoutBox) -> Double {
        let verticalTouch = abs(sliver.y - (box.y + box.height)) < 1.25 || abs((sliver.y + sliver.height) - box.y) < 1.25
        let horizontalTouch = abs(sliver.x - (box.x + box.width)) < 1.25 || abs((sliver.x + sliver.width) - box.x) < 1.25
        if verticalTouch {
            return overlap(box.x, box.width, sliver.x, sliver.width)
        }
        if horizontalTouch {
            return overlap(box.y, box.height, sliver.y, sliver.height)
        }
        return 0
    }

    private static func overlap(_ origin: Double, _ length: Double, _ otherOrigin: Double, _ otherLength: Double) -> Double {
        max(0, min(origin + length, otherOrigin + otherLength) - max(origin, otherOrigin))
    }

    private static func extend(_ box: LayoutBox, over sliver: LayoutBox) -> LayoutBox {
        var box = box
        if abs(sliver.y - (box.y + box.height)) < 1.25 {
            box.height = max(box.height, sliver.y + sliver.height - box.y)
        } else if abs((sliver.y + sliver.height) - box.y) < 1.25 {
            let top = min(box.y, sliver.y)
            box.height += box.y - top
            box.y = top
        } else if abs(sliver.x - (box.x + box.width)) < 1.25 {
            box.width = max(box.width, sliver.x + sliver.width - box.x)
        } else if abs((sliver.x + sliver.width) - box.x) < 1.25 {
            let left = min(box.x, sliver.x)
            box.width += box.x - left
            box.x = left
        }
        return box
    }
}

public enum LabelPlacement {
    public struct Frame: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var visible: Bool
    }

    /// Top-left label inside the tile. Hidden when the tile, or its header band, is too small to read.
    public static func frame(
        tileX: Double,
        tileY: Double,
        tileWidth: Double,
        tileHeight: Double,
        header: Double,
        inset: Double = 6,
        minWidth: Double = 36,
        minHeight: Double = 16
    ) -> Frame {
        let band = header > 0 ? header : tileHeight
        let visible = tileWidth >= minWidth && tileHeight >= minHeight && band >= minHeight
        let height = min(header > 0 ? max(0, header - 2) : min(28, tileHeight - inset), max(0, tileHeight - 2))
        return Frame(
            x: tileX + inset,
            y: tileY + (header > 0 ? 1 : min(inset, max(0, tileHeight - height))),
            width: max(0, tileWidth - inset * 2),
            height: max(0, height),
            visible: visible
        )
    }
}

public enum LayoutBench {
    public struct Result: Equatable, Sendable {
        public var hoverP99Ms: Double
        public var zoomP99Ms: Double
        public var hoverSamples: Int
        public var zoomSamples: Int
    }

    public static func measure(store: NodeStore, width: Double = 1200, height: Double = 740, hoverSamples: Int = 400, zoomSamples: Int = 40) -> Result {
        let root = store.rootID
        var hoverTimes: [Double] = []
        hoverTimes.reserveCapacity(hoverSamples)
        let layout = TreemapLayout.build(
            store: store,
            rootID: root,
            width: width,
            height: height,
            options: .browsing(metric: .allocated, zoomed: false)
        )
        var seed: UInt64 = 0xC0FFEE
        for _ in 0..<hoverSamples {
            seed = seed &* 6364136223846793005 &+ 1
            let px = Double(seed % 10_000) / 10_000 * width
            seed = seed &* 6364136223846793005 &+ 1
            let py = Double(seed % 10_000) / 10_000 * height
            let start = DispatchTime.now().uptimeNanoseconds
            _ = HitTest.hit(layout, x: px, y: py)
            let end = DispatchTime.now().uptimeNanoseconds
            hoverTimes.append(Double(end - start) / 1_000_000)
        }

        var zoomTimes: [Double] = []
        zoomTimes.reserveCapacity(zoomSamples)
        let focus = store.children(of: root)
        for sample in 0..<zoomSamples {
            let target = focus.isEmpty ? root : focus[sample % focus.count]
            let start = DispatchTime.now().uptimeNanoseconds
            _ = TreemapLayout.build(
                store: store,
                rootID: target,
                width: width,
                height: height,
                options: .browsing(metric: sample.isMultiple(of: 2) ? .allocated : .logical, zoomed: true)
            )
            let end = DispatchTime.now().uptimeNanoseconds
            zoomTimes.append(Double(end - start) / 1_000_000)
        }
        return Result(
            hoverP99Ms: percentile(hoverTimes, 0.99),
            zoomP99Ms: percentile(zoomTimes, 0.99),
            hoverSamples: hoverTimes.count,
            zoomSamples: zoomTimes.count
        )
    }

    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((Double(sorted.count - 1) * p).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank))]
    }
}
