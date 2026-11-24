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
    /// How many levels below the current root this view may draw. 2 is the default; 3 is the ceiling.
    public var maxVisibleDepth: Int
    public var minTileWidth: Double
    public var minTileHeight: Double

    public init(
        metric: SizeMetric = .allocated,
        gap: Double = 2,
        headerHeight: Double = 19,
        maxHeaderDepth: Int = 1,
        minRecurseWidth: Double = 40,
        minRecurseHeight: Double = 24,
        minChildExtent: Double = 4,
        pinHatchedAside: Bool = false,
        maxVisibleDepth: Int = 2,
        minTileWidth: Double = 40,
        minTileHeight: Double = 24
    ) {
        self.metric = metric
        self.gap = gap
        self.headerHeight = headerHeight
        self.maxHeaderDepth = maxHeaderDepth
        self.minRecurseWidth = minRecurseWidth
        self.minRecurseHeight = minRecurseHeight
        self.minChildExtent = minChildExtent
        self.pinHatchedAside = pinHatchedAside
        self.maxVisibleDepth = min(3, max(1, maxVisibleDepth))
        self.minTileWidth = minTileWidth
        self.minTileHeight = minTileHeight
    }

    public static func browsing(metric: SizeMetric, zoomed: Bool) -> TreemapOptions {
        // Drilling in starts a new view, so the cap stays two levels either way.
        _ = zoomed
        return TreemapOptions(metric: metric, maxHeaderDepth: 1, maxVisibleDepth: 2, minTileWidth: 40, minTileHeight: 24)
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
    /// A directory whose descendants are not drawn in this view. Drill in to see them.
    public var isDepthCapped: Bool = false
    /// How many siblings were folded into a remainder tile.
    public var foldedCount: Int = 0
    /// Breadcrumb for a collapsed single-child chain. Empty when the tile is a single name.
    public var headerTitle: String = ""
    public var sizeBytes: UInt64 = 0

    public func contains(_ px: Double, _ py: Double) -> Bool {
        px >= x && py >= y && px < x + width && py < y + height
    }
}

public struct TreemapLayout: Equatable, Sendable {
    public var nodes: [TreemapNode]
    public var childIndex: [Int]
    public var root: Int
    public var options: TreemapOptions
    public var index: TileGrid

    public init(
        nodes: [TreemapNode] = [],
        childIndex: [Int] = [],
        root: Int = 0,
        options: TreemapOptions = TreemapOptions(),
        index: TileGrid = .empty
    ) {
        self.nodes = nodes
        self.childIndex = childIndex
        self.root = root
        self.options = options
        self.index = index
    }

    public static func build(store: NodeStore, rootID: UInt32, width: Double, height: Double, options: TreemapOptions) -> TreemapLayout {
        var layout = TreemapLayout(nodes: [], childIndex: [], root: 0, options: options)
        guard rootID != 0, width > 0, height > 0 else { return layout }
        layout.root = layout.place(store: store, id: rootID, x: 0, y: 0, width: width, height: height, depth: 0)
        layout.index = TileGrid.build(nodes: layout.nodes, root: layout.root)
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

    private mutating func place(
        store: NodeStore,
        id: UInt32,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        depth: Int,
        foldedCount: Int = 0,
        foldedBytes: UInt64 = 0
    ) -> Int {
        let remainder = TileFold.isRemainder(id)
        let chain = remainder
            ? ChainCollapse.Chain(leaf: id, title: "", names: [])
            : ChainCollapse.resolve(store: store, start: id, metric: options.metric)
        let leaf = chain.leaf
        let index = nodes.count
        let sizeBytes = remainder ? foldedBytes : store.bytes(leaf, options.metric)
        let labelName = !chain.title.isEmpty ? chain.title : (remainder ? "\(max(foldedCount, 1)) smaller items" : store.name(of: leaf))
        nodes.append(TreemapNode(
            id: leaf, x: x, y: y, width: width, height: height,
            header: 0, childStart: 0, childCount: 0, showsLabel: false, depth: depth,
            isRemainder: remainder, isDepthCapped: false, foldedCount: foldedCount,
            headerTitle: chain.title, sizeBytes: sizeBytes
        ))
        if remainder {
            nodes[index].showsLabel = labelFits(name: labelName, bytes: sizeBytes, width: width, height: height, header: 0)
            return index
        }

        let kids = childItems(store: store, id: leaf)
        let deepEnough = depth >= options.maxVisibleDepth
        let bigEnough = width >= options.minTileWidth && height >= options.minTileHeight
            && width >= options.minRecurseWidth && height >= options.minRecurseHeight
        let canRecurse = !kids.isEmpty && !deepEnough && bigEnough
        let depthCapped = store.isDirectory(leaf) && !kids.isEmpty && !canRecurse
        let header: Double = (canRecurse && depth >= 1 && depth <= max(1, options.maxHeaderDepth) && height >= options.headerHeight + 16 && width >= 48)
            ? options.headerHeight : 0
        nodes[index].isDepthCapped = depthCapped
        nodes[index].header = header
        if !canRecurse {
            nodes[index].showsLabel = labelFits(name: labelName, bytes: sizeBytes, width: width, height: height, header: header)
            return index
        }

        let bodyY = y + header
        let bodyH = max(0, height - header)
        let folded = TileFold.layoutMinimum(
            items: kids,
            x: x, y: bodyY, width: width, height: bodyH,
            gap: options.gap,
            minWidth: options.minTileWidth,
            minHeight: options.minTileHeight,
            parent: leaf
        )
        var childNodes: [Int] = []
        childNodes.reserveCapacity(folded.boxes.count)
        for box in folded.boxes where box.width > 0.5 && box.height > 0.5 {
            let childRemainder = TileFold.isRemainder(box.id)
            childNodes.append(place(
                store: store,
                id: box.id,
                x: box.x,
                y: box.y,
                width: box.width,
                height: box.height,
                depth: depth + 1,
                foldedCount: childRemainder ? folded.foldedCount : 0,
                foldedBytes: childRemainder ? UInt64(max(0, folded.foldedBytes.rounded())) : 0
            ))
        }
        let start = childIndex.count
        childIndex.append(contentsOf: childNodes)
        nodes[index].childStart = start
        nodes[index].childCount = childNodes.count
        nodes[index].showsLabel = labelFits(name: labelName, bytes: sizeBytes, width: width, height: height, header: header)
        return index
    }

    private func labelFits(name: String, bytes: UInt64, width: Double, height: Double, header: Double) -> Bool {
        LabelFit.fits(
            name: name,
            sizeText: ByteFormat.bytes(bytes),
            tileWidth: width,
            tileHeight: height,
            header: header
        )
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
        if layout.index.columns > 0 {
            return layout.index.hit(nodes: layout.nodes, x: x, y: y) ?? root.id
        }
        var index = layout.root
        while true {
            let node = layout.nodes[index]
            if node.header > 0, y < node.y + node.header {
                return node.id
            }
            var next: Int?
            var nextArea = Double.greatestFiniteMagnitude
            for child in layout.children(of: index) {
                let candidate = layout.nodes[child]
                guard candidate.contains(x, y) else { continue }
                let area = candidate.width * candidate.height
                if area < nextArea {
                    nextArea = area
                    next = child
                }
            }
            if let next {
                index = next
            } else {
                return node.id
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

    public struct MinimumFold: Equatable, Sendable {
        public var boxes: [LayoutBox]
        public var foldedCount: Int
        public var foldedBytes: Double
    }

    /// Lay out children so every tile is at least `minWidth` by `minHeight` (and that area).
    /// The leftovers become one remainder tile. The set is trimmed to what can fit before squarify runs.
    public static func layoutMinimum(
        items: [Squarify.Item],
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        gap: Double,
        minWidth: Double,
        minHeight: Double,
        parent: UInt32
    ) -> MinimumFold {
        guard width > 0, height > 0 else {
            return MinimumFold(boxes: [], foldedCount: 0, foldedBytes: 0)
        }
        let minArea = max(1, minWidth * minHeight)
        let capacity = max(1, Int(floor((width * height) / minArea)))
        var kept: [Squarify.Item] = []
        var foldedCount = 0
        var foldedBytes = 0.0
        if items.count > capacity {
            let ranked = items.sorted { $0.weight > $1.weight }
            let keepN = max(1, capacity - 1)
            kept = Array(ranked.prefix(keepN))
            for item in ranked.dropFirst(keepN) where item.weight > 0 {
                foldedCount += 1
                foldedBytes += item.weight
            }
        } else {
            kept = items.filter { $0.weight > 0 }
        }

        func tooSmall(_ box: LayoutBox) -> Bool {
            box.width + 0.01 < minWidth || box.height + 0.01 < minHeight || box.width * box.height + 0.01 < minArea
        }

        func layout(kept: [Squarify.Item], foldedBytes: Double) -> [LayoutBox] {
            var batch = kept
            if foldedBytes > 0 {
                batch.append(Squarify.Item(id: remainderID(parent: parent), weight: foldedBytes))
            }
            guard !batch.isEmpty else { return [] }
            if width < minWidth || height < minHeight || width * height < minArea {
                let id = foldedBytes > 0 ? remainderID(parent: parent) : batch[0].id
                return [LayoutBox(id: id, x: x, y: y, width: width, height: height)]
            }
            if batch.count == 1 {
                return [LayoutBox(id: batch[0].id, x: x, y: y, width: width, height: height)]
            }
            return Squarify.layout(items: batch, x: x, y: y, width: width, height: height, gap: gap)
        }

        func foldUndersized(_ boxes: [LayoutBox], kept: inout [Squarify.Item], foldedBytes: inout Double) -> Bool {
            let rejects = boxes.filter { !isRemainder($0.id) && tooSmall($0) }
            guard !rejects.isEmpty else { return false }
            let rejectIDs = Set(rejects.map(\.id))
            var next: [Squarify.Item] = []
            next.reserveCapacity(kept.count)
            for item in kept {
                if rejectIDs.contains(item.id) {
                    foldedCount += 1
                    foldedBytes += item.weight
                } else {
                    next.append(item)
                }
            }
            guard next.count < kept.count else { return false }
            kept = next
            return true
        }

        var boxes = layout(kept: kept, foldedBytes: foldedBytes)
        for _ in 0..<8 {
            guard foldUndersized(boxes, kept: &kept, foldedBytes: &foldedBytes) else { break }
            boxes = layout(kept: kept, foldedBytes: foldedBytes)
        }
        if boxes.contains(where: { !isRemainder($0.id) && tooSmall($0) }) {
            foldedCount += kept.count
            foldedBytes += kept.reduce(0) { $0 + $1.weight }
            kept = []
            boxes = layout(kept: kept, foldedBytes: foldedBytes)
        }
        if foldedBytes > 0,
           !kept.isEmpty,
           width >= minWidth * 2,
           height >= minHeight,
           let remIndex = boxes.firstIndex(where: { isRemainder($0.id) }),
           tooSmall(boxes[remIndex]) {
            let strip = min(width * 0.5, max(minWidth, min(boxes[remIndex].width, width - minWidth)))
            let gapUse = min(max(gap, 0), 4)
            let leftW = max(1, width - strip - gapUse)
            var left = Squarify.layout(items: kept, x: x, y: y, width: leftW, height: height, gap: gap)
            left.append(LayoutBox(
                id: remainderID(parent: parent),
                x: x + leftW + gapUse,
                y: y,
                width: max(minWidth, width - leftW - gapUse),
                height: height
            ))
            boxes = left
            if foldUndersized(boxes, kept: &kept, foldedBytes: &foldedBytes) {
                let strip2 = min(width * 0.5, max(minWidth, width * 0.2))
                let leftW2 = max(1, width - strip2 - gapUse)
                var again = kept.isEmpty
                    ? [LayoutBox]()
                    : Squarify.layout(items: kept, x: x, y: y, width: leftW2, height: height, gap: gap)
                again.append(LayoutBox(
                    id: remainderID(parent: parent),
                    x: x + leftW2 + gapUse,
                    y: y,
                    width: max(minWidth, width - leftW2 - gapUse),
                    height: height
                ))
                boxes = again
            }
        }
        return MinimumFold(boxes: boxes, foldedCount: foldedCount, foldedBytes: foldedBytes)
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
