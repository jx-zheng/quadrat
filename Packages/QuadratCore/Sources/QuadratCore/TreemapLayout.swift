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
    /// Hard cap on tiles drawn in one view, including the folded remainder.
    public var maxTiles: Int

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
        minTileHeight: Double = 24,
        maxTiles: Int = 60
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
        self.maxTiles = min(60, max(1, maxTiles))
    }

    public static func browsing(metric: SizeMetric, zoomed: Bool) -> TreemapOptions {
        // Drilling in starts a new view, so the cap stays two levels either way.
        _ = zoomed
        return TreemapOptions(
            metric: metric,
            headerHeight: 0,
            maxHeaderDepth: 0,
            // Two levels of named children under the current root. Three is the ceiling.
            maxVisibleDepth: 3,
            minTileWidth: 40,
            minTileHeight: 24,
            maxTiles: 60
        )
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
    /// Full name. Never a clipped fragment. Empty only for the view root.
    public var label: String = ""

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
        foldedBytes: UInt64 = 0,
        opening: Bool = true
    ) -> Int {
        let remainder = TileFold.isRemainder(id)
        let files = TileFold.isFiles(id)
        let chain = (remainder || files)
            ? ChainCollapse.Chain(leaf: id, title: "", names: [])
            : ChainCollapse.resolve(store: store, start: id, metric: options.metric)
        let leaf = chain.leaf
        let index = nodes.count
        let sizeBytes = (remainder || files) ? foldedBytes : store.bytes(leaf, options.metric)
        let labelName: String
        if files {
            labelName = "\(max(foldedCount, 1)) files"
        } else if !chain.title.isEmpty {
            labelName = chain.title
        } else if remainder {
            labelName = "\(max(foldedCount, 1)) smaller items"
        } else {
            labelName = store.name(of: leaf)
        }
        nodes.append(TreemapNode(
            id: leaf, x: x, y: y, width: width, height: height,
            header: 0, childStart: 0, childCount: 0, showsLabel: false, depth: depth,
            isRemainder: remainder, isDepthCapped: false, foldedCount: foldedCount,
            headerTitle: chain.title, sizeBytes: sizeBytes, label: labelName
        ))
        if remainder || files {
            nodes[index].showsLabel = labelFits(name: labelName, bytes: sizeBytes, width: width, height: height, header: 0)
            return index
        }

        let deepEnough = depth >= options.maxVisibleDepth
        let bigEnough = width >= options.minTileWidth && height >= options.minTileHeight
            && width >= options.minRecurseWidth && height >= options.minRecurseHeight
        let minArea = options.minTileWidth * options.minTileHeight
        let canHoldChildren = width >= options.minTileWidth * 2
            && height >= options.minTileHeight * 2
            && width * height >= minArea * 2
        let room = max(0, options.maxTiles - visibleCount())
        // No header bars inside the map. A single-child chain is the top breadcrumb.
        if !opening || deepEnough || !bigEnough || !canHoldChildren || room < 2 {
            let hasChild = Int(leaf) < store.firstChild.count && store.firstChild[Int(leaf)] != 0
            nodes[index].isDepthCapped = store.isDirectory(leaf) && hasChild
            nodes[index].showsLabel = labelFits(name: labelName, bytes: sizeBytes, width: width, height: height, header: 0)
            return index
        }

        if !installChildren(store: store, index: index, parent: leaf, x: x, y: y, width: width, height: height, depth: depth, header: 0) {
            nodes[index].showsLabel = labelFits(name: labelName, bytes: sizeBytes, width: width, height: height, header: 0)
            return index
        }
        if depth == 0 {
            openLargestFolders(store: store)
        }
        return index
    }

    /// Deeper levels fill whatever of the 60-tile budget the level above did not use.
    private mutating func openLargestFolders(store: NodeStore) {
        var level = 1
        while level < options.maxVisibleDepth {
            let opened = openFolders(store: store, depth: level)
            if !opened { break }
            level += 1
        }
    }

    private mutating func openFolders(store: NodeStore, depth: Int) -> Bool {
        var order = nodes.indices.filter { nodes[$0].depth == depth && nodes[$0].isDepthCapped && !nodes[$0].isRemainder }
        order.sort { lhs, rhs in
            let a = nodes[lhs].width * nodes[lhs].height
            let b = nodes[rhs].width * nodes[rhs].height
            return a > b
        }
        var opened = false
        for index in order {
            let room = options.maxTiles - visibleCount()
            if room < 2 { break }
            let node = nodes[index]
            guard node.width >= options.minTileWidth * 2, node.height >= options.minTileHeight * 2 else { continue }
            let header = 18.0
            guard node.height > header + options.minTileHeight else { continue }
            guard labelFits(name: node.label, bytes: node.sizeBytes, width: node.width, height: node.height, header: header) else { continue }
            guard installChildren(
                store: store, index: index, parent: node.id,
                x: node.x, y: node.y, width: node.width, height: node.height,
                depth: node.depth, header: header
            ) else { continue }
            opened = true
        }
        return opened
    }

    private func visibleCount() -> Int {
        nodes.reduce(0) { $0 + ($1.depth > 0 ? 1 : 0) }
    }

    /// Drop tiles whose full name cannot be drawn, and fold them into one labelled remainder.
    /// A remainder that is itself too small to read is omitted so it does not become a blank sliver.
    private func retainReadable(
        store: NodeStore,
        fold: TileFold.MinimumFold,
        items: [Squarify.Item],
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        parent: UInt32
    ) -> TileFold.MinimumFold {
        var rejected: Set<UInt32> = []
        var current = fold
        for _ in 0..<6 {
            var newly: Set<UInt32> = []
            for box in current.boxes where !TileFold.isRemainder(box.id) {
                let name = store.name(of: box.id)
                let bytes = store.bytes(box.id, options.metric)
                if !labelFits(name: name, bytes: bytes, width: box.width, height: box.height, header: 0) {
                    newly.insert(box.id)
                }
            }
            let remainderFits: Bool = {
                guard let rem = current.boxes.first(where: { TileFold.isRemainder($0.id) }), current.foldedCount > 0 else { return true }
                let name = "\(current.foldedCount) smaller items"
                let bytes = UInt64(max(0, current.foldedBytes.rounded()))
                return labelFits(name: name, bytes: bytes, width: rem.width, height: rem.height, header: 0)
            }()
            if newly.isEmpty && remainderFits {
                return current
            }
            // A crowded first cut can fail every label at once. Keep the largest tiles and
            // try again so a big folder shows named children instead of one giant fold.
            if newly.count > 1 {
                let real = current.boxes.filter { !TileFold.isRemainder($0.id) && newly.contains($0.id) }
                if real.count == newly.count {
                    let ranked = real.sorted { ($0.width * $0.height) > ($1.width * $1.height) }
                    let keep = Set(ranked.prefix(max(1, ranked.count / 2)).map(\.id))
                    newly.subtract(keep)
                }
            }
            if !remainderFits && newly.isEmpty {
                let keptIDs = Set(current.boxes.filter { !TileFold.isRemainder($0.id) }.map(\.id))
                let kept = items.filter { keptIDs.contains($0.id) }
                let boxes = kept.isEmpty ? [] : Squarify.layout(items: kept, x: x, y: y, width: width, height: height, gap: options.gap)
                return TileFold.MinimumFold(boxes: boxes, foldedCount: 0, foldedBytes: 0)
            }
            rejected.formUnion(newly)
            let kept = items.filter { !rejected.contains($0.id) }
            let seededBytes = items.filter { rejected.contains($0.id) }.reduce(0.0) { $0 + $1.weight }
            current = TileFold.layoutMinimum(
                items: kept,
                x: x, y: y, width: width, height: height,
                gap: options.gap,
                minWidth: options.minTileWidth,
                minHeight: options.minTileHeight,
                parent: parent,
                maxCount: max(1, kept.count + 1),
                seededFoldCount: rejected.count,
                seededFoldBytes: seededBytes
            )
        }
        return current
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

    /// Lay the parent's bytes out as named children, one "<N> files" tile, and a tail fold.
    /// The boxes fill `rect`. The fold's weight is only the children that were not named.
    private mutating func installChildren(
        store: NodeStore,
        index: Int,
        parent: UInt32,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        depth: Int,
        header: Double
    ) -> Bool {
        let room = options.maxTiles - visibleCount()
        guard room >= 2, height > header + 8 else { return false }
        // Named tiles plus the files tile plus the tail fold have to fit in the budget,
        // so a later tile is never dropped and its rectangle left blank.
        let budget = min(12, room)
        let packed = packChildren(store: store, id: parent, limit: max(1, budget - 2))
        let bodyY = y + header
        let bodyH = height - header
        let laid = layoutCovering(store: store, packed: packed, parent: parent, x: x, y: bodyY, width: width, height: bodyH)
        guard !laid.boxes.isEmpty else { return false }
        var childNodes: [Int] = []
        childNodes.reserveCapacity(laid.boxes.count)
        for box in laid.boxes where box.width > 0.5 && box.height > 0.5 {
            let count: Int
            let bytes: UInt64
            if TileFold.isRemainder(box.id) {
                count = laid.foldCount
                bytes = UInt64(max(0, laid.foldBytes.rounded()))
            } else if TileFold.isFiles(box.id) {
                count = laid.filesCount
                bytes = UInt64(max(0, laid.filesBytes.rounded()))
            } else {
                count = 0
                bytes = 0
            }
            childNodes.append(place(
                store: store,
                id: box.id,
                x: box.x,
                y: box.y,
                width: box.width,
                height: box.height,
                depth: depth + 1,
                foldedCount: count,
                foldedBytes: bytes,
                opening: false
            ))
        }
        guard !childNodes.isEmpty else { return false }
        let start = childIndex.count
        childIndex.append(contentsOf: childNodes)
        nodes[index].childStart = start
        nodes[index].childCount = childNodes.count
        nodes[index].header = header
        nodes[index].isDepthCapped = false
        nodes[index].showsLabel = labelFits(
            name: nodes[index].label,
            bytes: nodes[index].sizeBytes,
            width: nodes[index].width,
            height: nodes[index].height,
            header: header
        )
        return true
    }

    private struct Packed {
        var named: [Squarify.Item]
        var filesCount: Int
        var filesBytes: Double
        var foldCount: Int
        var foldBytes: Double
    }

    /// Largest children stay named. Small direct files become one files tile.
    /// Anything else is the tail fold, and its weight is only those leftover bytes.
    private func packChildren(store: NodeStore, id: UInt32, limit: Int) -> Packed {
        let keep = max(1, limit)
        struct Cand { var id: UInt32; var weight: Double; var isDir: Bool }
        var best: [Cand] = []
        best.reserveCapacity(keep)
        var minIndex = 0
        var total = 0.0
        var fileTailCount = 0
        var fileTailBytes = 0.0
        var dirTailCount = 0
        var dirTailBytes = 0.0
        store.forEachChild(id) { child in
            if store.flags(child).contains(.trashed) { return }
            let weight = Double(store.bytes(child, options.metric))
            if weight <= 0 { return }
            total += weight
            let isDir = store.isDirectory(child)
            let cand = Cand(id: child, weight: weight, isDir: isDir)
            if best.count < keep {
                if best.isEmpty || weight < best[minIndex].weight { minIndex = best.count }
                best.append(cand)
                return
            }
            if weight <= best[minIndex].weight {
                if isDir {
                    dirTailCount += 1
                    dirTailBytes += weight
                } else {
                    fileTailCount += 1
                    fileTailBytes += weight
                }
                return
            }
            let dropped = best[minIndex]
            if dropped.isDir {
                dirTailCount += 1
                dirTailBytes += dropped.weight
            } else {
                fileTailCount += 1
                fileTailBytes += dropped.weight
            }
            best[minIndex] = cand
            minIndex = 0
            for index in best.indices where best[index].weight < best[minIndex].weight {
                minIndex = index
            }
        }
        let cutoff = total * 0.015
        var named: [Squarify.Item] = []
        named.reserveCapacity(best.count)
        for cand in best.sorted(by: { $0.weight > $1.weight }) {
            let large = cand.weight >= cutoff
            if large && named.count < keep {
                named.append(Squarify.Item(id: cand.id, weight: cand.weight))
            } else if cand.isDir {
                dirTailCount += 1
                dirTailBytes += cand.weight
            } else {
                fileTailCount += 1
                fileTailBytes += cand.weight
            }
        }
        return Packed(
            named: named,
            filesCount: fileTailCount,
            filesBytes: fileTailBytes,
            foldCount: dirTailCount,
            foldBytes: dirTailBytes
        )
    }

    private struct Covered {
        var boxes: [LayoutBox]
        var foldCount: Int
        var foldBytes: Double
        var filesCount: Int
        var filesBytes: Double
    }

    /// Squarify named children plus the files tile plus the tail. Every byte is in exactly one box,
    /// and the boxes fill the rect. A child that cannot hold its label joins the tail and the rest reflow.
    private func layoutCovering(
        store: NodeStore,
        packed: Packed,
        parent: UInt32,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) -> Covered {
        var named = packed.named
        var foldCount = packed.foldCount
        var foldBytes = packed.foldBytes
        var filesCount = packed.filesCount
        var filesBytes = packed.filesBytes
        func lay() -> [LayoutBox] {
            var batch = named
            if filesCount > 0, filesBytes > 0 {
                batch.append(Squarify.Item(id: TileFold.filesID(parent: parent), weight: filesBytes))
            }
            if foldCount > 0, foldBytes > 0 {
                batch.append(Squarify.Item(id: TileFold.remainderID(parent: parent), weight: foldBytes))
            }
            guard !batch.isEmpty, width > 1, height > 1 else { return [] }
            if batch.count == 1 {
                return [LayoutBox(id: batch[0].id, x: x, y: y, width: width, height: height)]
            }
            return Squarify.layout(items: batch, x: x, y: y, width: width, height: height, gap: options.gap)
        }
        func fits(_ box: LayoutBox) -> Bool {
            if TileFold.isRemainder(box.id) {
                let name = "\(max(foldCount, 1)) smaller items"
                return labelFits(name: name, bytes: UInt64(max(0, foldBytes.rounded())), width: box.width, height: box.height, header: 0)
            }
            if TileFold.isFiles(box.id) {
                let name = "\(max(filesCount, 1)) files"
                return labelFits(name: name, bytes: UInt64(max(0, filesBytes.rounded())), width: box.width, height: box.height, header: 0)
            }
            let name = store.name(of: box.id)
            let bytes = store.bytes(box.id, options.metric)
            let tooSmall = box.width + 0.5 < options.minTileWidth || box.height + 0.5 < options.minTileHeight
            return !tooSmall && labelFits(name: name, bytes: bytes, width: box.width, height: box.height, header: 0)
        }
        var boxes = lay()
        for _ in 0..<12 {
            let unfit = boxes.filter { !fits($0) && !TileFold.isRemainder($0.id) && !TileFold.isFiles($0.id) }
            guard let victim = unfit.min(by: { $0.width * $0.height < $1.width * $1.height }),
                  let item = named.first(where: { $0.id == victim.id }),
                  named.count > 1 else { break }
            named.removeAll { $0.id == item.id }
            if store.isDirectory(item.id) {
                foldCount += 1
                foldBytes += item.weight
            } else {
                filesCount += 1
                filesBytes += item.weight
            }
            boxes = lay()
        }
        // A tail that cannot be read is removed and the named tiles are laid out again, filling the rect.
        if boxes.contains(where: { TileFold.isRemainder($0.id) && !fits($0) }) {
            foldCount = 0
            foldBytes = 0
            boxes = lay()
        }
        if boxes.contains(where: { TileFold.isFiles($0.id) && !fits($0) }) {
            filesCount = 0
            filesBytes = 0
            boxes = lay()
        }
        if boxes.isEmpty, let only = packed.named.max(by: { $0.weight < $1.weight }) {
            boxes = [LayoutBox(id: only.id, x: x, y: y, width: width, height: height)]
        }
        return Covered(boxes: boxes, foldCount: foldCount, foldBytes: foldBytes, filesCount: filesCount, filesBytes: filesBytes)
    }

    private struct Gathered {
        var items: [Squarify.Item]
        var foldedCount: Int
        var foldedBytes: Double
    }

    /// Keep only the largest `limit` children. The rest become one fold, without sorting the whole directory.
    private func gatherChildren(store: NodeStore, id: UInt32, limit: Int) -> Gathered {
        let keep = max(1, limit)
        var best: [Squarify.Item] = []
        best.reserveCapacity(keep)
        var minIndex = 0
        var foldedCount = 0
        var foldedBytes = 0.0
        store.forEachChild(id) { child in
            if store.flags(child).contains(.trashed) { return }
            let weight = Double(store.bytes(child, options.metric))
            if weight <= 0 { return }
            if best.count < keep {
                if best.isEmpty || weight < best[minIndex].weight { minIndex = best.count }
                best.append(Squarify.Item(id: child, weight: weight))
                return
            }
            if weight <= best[minIndex].weight {
                foldedCount += 1
                foldedBytes += weight
                return
            }
            foldedCount += 1
            foldedBytes += best[minIndex].weight
            best[minIndex] = Squarify.Item(id: child, weight: weight)
            minIndex = 0
            for index in best.indices where best[index].weight < best[minIndex].weight {
                minIndex = index
            }
        }
        return Gathered(items: best, foldedCount: foldedCount, foldedBytes: foldedBytes)
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

    /// Direct files that are too small to name on their own. Not a directory fold.
    public static func filesID(parent: UInt32) -> UInt32 { parent | 0x4000_0000 }
    public static func isFiles(_ id: UInt32) -> Bool { (id & 0xC000_0000) == 0x4000_0000 }
    public static func filesParent(_ id: UInt32) -> UInt32 { id & 0x3FFF_FFFF }

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
        parent: UInt32,
        maxCount: Int = .max,
        seededFoldCount: Int = 0,
        seededFoldBytes: Double = 0
    ) -> MinimumFold {
        guard width > 0, height > 0 else {
            return MinimumFold(boxes: [], foldedCount: 0, foldedBytes: 0)
        }
        let minArea = max(1, minWidth * minHeight)
        let capacity = max(1, Int(floor((width * height) / minArea)))
        var kept: [Squarify.Item] = []
        var foldedCount = seededFoldCount
        var foldedBytes = seededFoldBytes
        let ranked = items.sorted { $0.weight > $1.weight }
        if ranked.isEmpty {
            guard seededFoldBytes > 0 else { return MinimumFold(boxes: [], foldedCount: 0, foldedBytes: 0) }
            return MinimumFold(
                boxes: [LayoutBox(id: remainderID(parent: parent), x: x, y: y, width: width, height: height)],
                foldedCount: seededFoldCount,
                foldedBytes: seededFoldBytes
            )
        }
        let limit = max(1, min(capacity, maxCount))
        if ranked.count > limit {
            let keepN = max(1, limit - 1)
            kept = Array(ranked.prefix(keepN))
            for item in ranked.dropFirst(keepN) where item.weight > 0 {
                foldedCount += 1
                foldedBytes += item.weight
            }
        } else {
            kept = ranked.filter { $0.weight > 0 }
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
            var rejects = boxes.filter { !isRemainder($0.id) && tooSmall($0) }
            guard !rejects.isEmpty else { return false }
            let real = boxes.filter { !isRemainder($0.id) }
            if rejects.count == real.count, real.count > 1 {
                let ranked = real.sorted { ($0.width * $0.height) > ($1.width * $1.height) }
                let keepIDs = Set(ranked.prefix(max(1, ranked.count / 2)).map(\.id))
                rejects = rejects.filter { !keepIDs.contains($0.id) }
            }
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

public enum LayoutAudit {
    public struct Report: Equatable, Sendable {
        public var tiles: Int
        public var unlabeled: Int
    }

    public static func check(store: NodeStore, width: Double = 1200, height: Double = 800) -> Report {
        let layout = TreemapLayout.build(
            store: store,
            rootID: store.rootID,
            width: width,
            height: height,
            options: .browsing(metric: .allocated, zoomed: false)
        )
        var tiles = 0
        var unlabeled = 0
        for node in layout.nodes where node.depth > 0 {
            tiles += 1
            let fits = LabelFit.fits(
                name: node.label,
                sizeText: ByteFormat.bytes(node.sizeBytes),
                tileWidth: node.width,
                tileHeight: node.height,
                header: node.header
            )
            if node.label.isEmpty || !node.showsLabel || !fits {
                unlabeled += 1
            }
        }
        return Report(tiles: tiles, unlabeled: unlabeled)
    }
}
