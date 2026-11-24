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
        gap: Double = 1.5,
        headerHeight: Double = 19,
        maxHeaderDepth: Int = 4,
        minRecurseWidth: Double = 34,
        minRecurseHeight: Double = 26,
        minChildExtent: Double = 3,
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
            header: 0, childStart: 0, childCount: 0, showsLabel: false, depth: depth
        ))
        let kids = childItems(store: store, id: id)
        let canRecurse = width >= options.minRecurseWidth && height >= options.minRecurseHeight && !kids.isEmpty
        let header: Double = (canRecurse && depth >= 1 && depth <= options.maxHeaderDepth && height >= options.headerHeight + 16 && width >= 48)
            ? options.headerHeight : 0
        if !canRecurse {
            nodes[index].showsLabel = width >= 36 && height >= 22
            return index
        }

        let bodyY = y + header
        let bodyH = max(0, height - header)
        let boxes = boxesForChildren(store: store, kids: kids, x: x, y: bodyY, width: width, height: bodyH)
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
        nodes[index].showsLabel = header > 0 || (childNodes.isEmpty && width >= 36 && height >= 22)
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

    private func boxesForChildren(store: NodeStore, kids: [Squarify.Item], x: Double, y: Double, width: Double, height: Double) -> [LayoutBox] {
        let hatched = kids.filter { store.flags($0.id).contains(.hatched) }
        let solid = kids.filter { !store.flags($0.id).contains(.hatched) }
        guard options.pinHatchedAside, let hatch = hatched.max(by: { $0.weight < $1.weight }), !solid.isEmpty, width > 0 else {
            return Squarify.layout(items: kids, x: x, y: y, width: width, height: height, gap: options.gap)
        }
        let total = solid.reduce(0.0) { $0 + $1.weight } + hatch.weight
        let fraction = total > 0 ? solid.reduce(0.0) { $0 + $1.weight } / total : 0.5
        let scannedW = max(0, min(width, width * fraction))
        var boxes = Squarify.layout(items: solid, x: x, y: y, width: max(scannedW, 1), height: height, gap: options.gap)
        boxes.append(LayoutBox(id: hatch.id, x: x + scannedW, y: y, width: max(0, width - scannedW), height: height))
        return boxes
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
                return node.id
            }
        }
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
