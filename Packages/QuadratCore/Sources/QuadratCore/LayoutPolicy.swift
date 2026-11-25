import Foundation

/// Bundles are one tile named after the bundle. Do not walk into Contents.
public enum BundleLeaf {
    public static let suffixes = [".app", ".jdk", ".framework", ".bundle", ".plugin", ".kext", ".xcarchive"]

    public static func isLeaf(_ name: String) -> Bool {
        let lower = name.lowercased()
        return suffixes.contains { lower.hasSuffix($0) }
    }

    public static func name(in names: [String]) -> String? {
        names.first { isLeaf($0) }
    }
}

public enum ChainCollapse {
    public struct Chain: Equatable, Sendable {
        public var leaf: UInt32
        public var title: String
        public var names: [String]
    }

    /// Directories that contain a single directory collapse into that leaf.
    /// `Users / jxzheng / Library` is one header; the leaf's children are what get drawn.
    public static func resolve(store: NodeStore, start: UInt32, metric: SizeMetric, limit: Int = 16) -> Chain {
        var leaf = start
        var names = [store.name(of: start)]
        var seen: Set<UInt32> = [start]
        var steps = 0
        while steps < limit {
            // A bundle is one tile. Do not walk into Contents.
            if BundleLeaf.isLeaf(store.name(of: leaf)) { break }
            guard let only = soleDirectoryChild(store: store, id: leaf, metric: metric), seen.insert(only).inserted else { break }
            leaf = only
            names.append(store.name(of: only))
            steps += 1
        }
        let title = displayTitle(names: names)
        return Chain(leaf: leaf, title: title, names: names)
    }

    /// `Users / you` stays a chain. `Xcode.app / Contents` is just `Xcode.app`.
    public static func displayTitle(names: [String]) -> String {
        if let bundle = BundleLeaf.name(in: names) {
            return bundle
        }
        let boring: Set<String> = ["contents", "macos", "resources", "frameworks", "versions", "helpers"]
        let kept = names.filter { !boring.contains($0.lowercased()) }
        let use = kept.isEmpty ? names : kept
        return use.count > 1 ? use.joined(separator: " / ") : ""
    }

    /// Walk upward while this node is the parent's only real child, so a drill-in
    /// at "User 1" can still be titled "Anki2 / User 1".
    public static func upward(store: NodeStore, from start: UInt32, metric: SizeMetric, limit: Int = 16) -> Chain {
        guard start != 0 else { return Chain(leaf: start, title: "", names: []) }
        var names = [store.name(of: start)]
        var current = start
        var steps = 0
        while steps < limit, Int(current) < store.parent.count {
            let parent = store.parent[Int(current)]
            if parent == 0 || parent == store.rootID { break }
            if BundleLeaf.isLeaf(store.name(of: parent)) { break }
            guard soleDirectoryChild(store: store, id: parent, metric: metric) == current else { break }
            names.insert(store.name(of: parent), at: 0)
            current = parent
            steps += 1
        }
        return Chain(leaf: start, title: displayTitle(names: names), names: names)
    }

    /// Full chain when it is readable, otherwise the first meaningful ancestor.
    public static func preferredTitle(names: [String]) -> String {
        let title = displayTitle(names: names)
        if !title.isEmpty { return title }
        return names.last ?? ""
    }

    /// When the full chain does not fit, use a meaningful ancestor, not the generic leaf.
    public static func titleThatFits(names: [String], width: Double, bytes: UInt64) -> String {
        let full = preferredTitle(names: names)
        if full.isEmpty { return names.last ?? "" }
        if LabelFit.fits(name: full, sizeText: ByteFormat.bytes(bytes), tileWidth: max(width, 80), tileHeight: 40, header: 0) {
            return full
        }
        let boring: Set<String> = ["contents", "macos", "resources", "frameworks", "versions", "helpers"]
        if let ancestor = names.first(where: {
            let n = $0.lowercased()
            return !boring.contains(n) && !OpaqueName.isHashOrUUID($0)
        }) {
            return ancestor
        }
        return names.first ?? full
    }

    private static func soleDirectoryChild(store: NodeStore, id: UInt32, metric: SizeMetric) -> UInt32? {
        guard id != 0, Int(id) < store.firstChild.count else { return nil }
        var child = store.firstChild[Int(id)]
        var found: UInt32?
        var count = 0
        var seen = 0
        // A real chain has one child. Stop after a handful of siblings so a wide folder is not walked.
        while child != 0, Int(child) < store.nextSibling.count, seen < 4 {
            seen += 1
            let next = store.nextSibling[Int(child)]
            if !store.flags(child).contains(.trashed), store.bytes(child, metric) > 0 {
                count += 1
                if count > 1 { return nil }
                found = store.isDirectory(child) ? child : nil
            }
            child = next
        }
        if child != 0 { return nil }
        return count == 1 ? found : nil
    }
}

public enum LabelFit {
    /// Both the full name and the size have to fit. Anything else gets no label.
    public static func fits(
        name: String,
        sizeText: String,
        tileWidth: Double,
        tileHeight: Double,
        header: Double,
        inset: Double = 8
    ) -> Bool {
        guard !name.isEmpty, tileWidth > inset * 2, tileHeight > 4 else { return false }
        if tooThin(width: tileWidth, height: tileHeight) { return false }
        let nameWidth = Double(name.count) * 7.6
        let sizeWidth = Double(sizeText.count) * 6.8
        let available = tileWidth - inset * 2
        if header > 0 {
            // A header may drop the size if the name alone is what fits.
            return header >= 16 && nameWidth <= available
        }
        if sizeWidth > available { return false }
        if nameWidth <= available {
            return tileHeight >= minLabelHeight
        }
        // A tall tile may wrap the full name. Never clip it to a fragment.
        guard available > 8 else { return false }
        let lines = Int((nameWidth / available).rounded(.up))
        if lines < 2 || lines > 3 { return false }
        let needed = Double(lines) * 16 + 16 + 8
        return tileHeight >= needed
    }

    public static let minLabelWidth: Double = 40
    public static let minLabelHeight: Double = 36

    /// A strip this small cannot hold a name and a size, so it must not be drawn.
    public static func tooThin(width: Double, height: Double) -> Bool {
        width + 0.5 < minLabelWidth || height + 0.5 < minLabelHeight
    }
}

public struct TileGrid: Equatable, Sendable {
    public var originX: Double
    public var originY: Double
    public var cellWidth: Double
    public var cellHeight: Double
    public var columns: Int
    public var rows: Int
    public var buckets: [[Int]]

    public static let empty = TileGrid(
        originX: 0, originY: 0, cellWidth: 1, cellHeight: 1, columns: 0, rows: 0, buckets: []
    )

    public static func build(nodes: [TreemapNode], root: Int) -> TileGrid {
        guard nodes.indices.contains(root) else { return .empty }
        let bounds = nodes[root]
        guard bounds.width > 0, bounds.height > 0 else { return .empty }
        let columns = min(96, max(1, Int(ceil(bounds.width / 64))))
        let rows = min(96, max(1, Int(ceil(bounds.height / 64))))
        let cellWidth = bounds.width / Double(columns)
        let cellHeight = bounds.height / Double(rows)
        guard cellWidth > 0, cellHeight > 0 else { return .empty }
        var buckets = Array(repeating: [Int](), count: columns * rows)
        for index in nodes.indices where index != root {
            let node = nodes[index]
            guard node.width > 0, node.height > 0 else { continue }
            let x0 = clamp(Int(floor((node.x - bounds.x) / cellWidth)), 0, columns - 1)
            let y0 = clamp(Int(floor((node.y - bounds.y) / cellHeight)), 0, rows - 1)
            let x1 = clamp(Int(floor((node.x + node.width - bounds.x - 1e-6) / cellWidth)), 0, columns - 1)
            let y1 = clamp(Int(floor((node.y + node.height - bounds.y - 1e-6) / cellHeight)), 0, rows - 1)
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 {
                for x in x0...x1 {
                    buckets[y * columns + x].append(index)
                }
            }
        }
        return TileGrid(
            originX: bounds.x,
            originY: bounds.y,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            columns: columns,
            rows: rows,
            buckets: buckets
        )
    }

    /// Smallest visible tile that contains the point. Looks only at the cells the rects were dropped into.
    public func hit(nodes: [TreemapNode], x: Double, y: Double) -> UInt32? {
        guard columns > 0, rows > 0, cellWidth > 0, cellHeight > 0 else { return nil }
        let gx = Self.clamp(Int(floor((x - originX) / cellWidth)), 0, columns - 1)
        let gy = Self.clamp(Int(floor((y - originY) / cellHeight)), 0, rows - 1)
        var best: Int?
        var bestArea = Double.greatestFiniteMagnitude
        for oy in -1...1 {
            for ox in -1...1 {
                let cx = gx + ox
                let cy = gy + oy
                guard cx >= 0, cy >= 0, cx < columns, cy < rows else { continue }
                for index in buckets[cy * columns + cx] {
                    guard nodes.indices.contains(index) else { continue }
                    let node = nodes[index]
                    guard node.contains(x, y) else { continue }
                    let area = node.width * node.height
                    let deeper = best.map { nodes[$0].depth < node.depth } ?? false
                    if area < bestArea || (area == bestArea && deeper) {
                        bestArea = area
                        best = index
                    }
                }
            }
        }
        return best.map { nodes[$0].id }
    }

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(high, max(low, value))
    }
}
