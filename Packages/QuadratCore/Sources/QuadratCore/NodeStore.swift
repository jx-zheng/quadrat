import Foundation

public struct NodeFlags: OptionSet, Equatable, Sendable {
    public var rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let directory = NodeFlags(rawValue: 1 << 0)
    public static let hardLinkDuplicate = NodeFlags(rawValue: 1 << 1)
    public static let inaccessible = NodeFlags(rawValue: 1 << 2)
    public static let foldedAggregate = NodeFlags(rawValue: 1 << 3)
    public static let mountPoint = NodeFlags(rawValue: 1 << 4)
    public static let mayShareBlocks = NodeFlags(rawValue: 1 << 5)
    public static let sparse = NodeFlags(rawValue: 1 << 6)
    public static let symlink = NodeFlags(rawValue: 1 << 7)
    public static let hatched = NodeFlags(rawValue: 1 << 8)
    /// A descendant could not be read, so totals are a lower bound.
    public static let lowerBound = NodeFlags(rawValue: 1 << 9)
    public static let trashed = NodeFlags(rawValue: 1 << 10)
    /// Children were dropped. The size and item count are the whole subtree.
    /// Zooming re-lists the folder from disk.
    public static let collapsed = NodeFlags(rawValue: 1 << 11)
}

public enum SizeMetric: String, Equatable, Hashable, Sendable {
    case allocated
    case logical
}

public enum SizeUnits {
    public static let block: UInt64 = 4096

    public static func units(for bytes: UInt64) -> UInt32 {
        if bytes == 0 { return 0 }
        let units = (bytes &+ (block &- 1)) / block
        if units > UInt64(UInt32.max) { return .max }
        return UInt32(units)
    }

    public static func bytes(for units: UInt32) -> UInt64 {
        UInt64(units) &* block
    }
}

/// Struct-of-arrays node arena. Index 0 is the null sentinel; the root is index 1.
public struct NodeStore: Equatable, Sendable {
    public static let nullID: UInt32 = 0

    public private(set) var parent: [UInt32] = [0]
    public private(set) var firstChild: [UInt32] = [0]
    public private(set) var nextSibling: [UInt32] = [0]
    /// Build-time tail pointer so appending a child is O(1). Not required after the tree is sealed.
    private var lastChild: [UInt32] = [0]
    public private(set) var nameOff: [UInt32] = [0]
    public private(set) var alloc4K: [UInt32] = [0]
    public private(set) var logical4K: [UInt32] = [0]
    public private(set) var itemCount: [UInt32] = [0]
    public private(set) var nameLen: [UInt8] = [0]
    public private(set) var kindRaw: [UInt8] = [0]
    public private(set) var flagsRaw: [UInt16] = [0]
    public var names = NameBlob()
    /// Bytes unique to this file (not shared with an APFS clone). Sparse side table.
    public var privateBytes: [UInt32: UInt64] = [:]
    /// Recycled node ids. Slots stay in the arrays so the high-water mark is the peak, not the total ever created.
    private var freeList: [UInt32] = []

    public init() {}

    public var endIndex: Int { parent.count }
    public var nodeCount: Int { max(0, parent.count - 1) }
    /// Nodes that are still part of the tree. Recycled slots are not counted.
    public var liveNodeCount: Int { max(0, nodeCount - freeList.count) }

    public var rootID: UInt32 {
        parent.count > 1 ? 1 : 0
    }

    public var estimatedPayloadBytes: Int {
        let n = parent.count
        let fixed = n * (MemoryLayout<UInt32>.size * 8 + MemoryLayout<UInt8>.size * 2 + MemoryLayout<UInt16>.size)
        let priv = privateBytes.count * (MemoryLayout<UInt32>.size + MemoryLayout<UInt64>.size + 16)
        return fixed + names.storedBytes + priv
    }

    public mutating func reserve(_ minimum: Int) {
        parent.reserveCapacity(minimum)
        firstChild.reserveCapacity(minimum)
        nextSibling.reserveCapacity(minimum)
        lastChild.reserveCapacity(minimum)
        nameOff.reserveCapacity(minimum)
        alloc4K.reserveCapacity(minimum)
        logical4K.reserveCapacity(minimum)
        itemCount.reserveCapacity(minimum)
        nameLen.reserveCapacity(minimum)
        kindRaw.reserveCapacity(minimum)
        flagsRaw.reserveCapacity(minimum)
    }

    @discardableResult
    public mutating func addNode(
        parent parentID: UInt32,
        name: String,
        allocBytes: UInt64,
        logicalBytes: UInt64,
        kind: ContentKind,
        flags: NodeFlags,
        items: UInt32 = 0,
        privateSize: UInt64? = nil
    ) -> UInt32 {
        let placed = names.add(name)
        let id: UInt32
        if let reused = freeList.popLast() {
            id = reused
            parent[Int(id)] = parentID
            firstChild[Int(id)] = 0
            nextSibling[Int(id)] = 0
            lastChild[Int(id)] = 0
            nameOff[Int(id)] = placed.offset
            alloc4K[Int(id)] = SizeUnits.units(for: allocBytes)
            logical4K[Int(id)] = SizeUnits.units(for: logicalBytes)
            itemCount[Int(id)] = items
            nameLen[Int(id)] = placed.length
            kindRaw[Int(id)] = kind.rawValue
            flagsRaw[Int(id)] = flags.rawValue
        } else {
            id = UInt32(parent.count)
            parent.append(parentID)
            firstChild.append(0)
            nextSibling.append(0)
            lastChild.append(0)
            nameOff.append(placed.offset)
            alloc4K.append(SizeUnits.units(for: allocBytes))
            logical4K.append(SizeUnits.units(for: logicalBytes))
            itemCount.append(items)
            nameLen.append(placed.length)
            kindRaw.append(kind.rawValue)
            flagsRaw.append(flags.rawValue)
        }
        if let privateSize {
            privateBytes[id] = privateSize
        }
        if parentID != 0 {
            link(child: id, to: parentID)
        }
        if logicalBytes > allocBytes + allocBytes / 20 {
            flagsRaw[Int(id)] |= NodeFlags.sparse.rawValue
        }
        return id
    }

    public mutating func addRoot(name: String, kind: ContentKind = .other) -> UInt32 {
        addNode(parent: 0, name: name, allocBytes: 0, logicalBytes: 0, kind: kind, flags: .directory)
    }

    public func flags(_ id: UInt32) -> NodeFlags {
        guard valid(id) else { return [] }
        return NodeFlags(rawValue: flagsRaw[Int(id)])
    }

    public mutating func insertFlags(_ extra: NodeFlags, on id: UInt32) {
        guard valid(id) else { return }
        flagsRaw[Int(id)] |= extra.rawValue
    }

    public func kind(_ id: UInt32) -> ContentKind {
        guard valid(id) else { return .other }
        return ContentKind(rawValue: kindRaw[Int(id)]) ?? .other
    }

    public func name(of id: UInt32) -> String {
        guard valid(id) else { return "" }
        return names.string(offset: nameOff[Int(id)], length: nameLen[Int(id)])
    }

    public mutating func setAllocatedBytes(_ id: UInt32, _ bytes: UInt64) {
        guard valid(id) else { return }
        alloc4K[Int(id)] = SizeUnits.units(for: bytes)
    }

    public mutating func setItemCount(_ id: UInt32, _ count: UInt32) {
        guard Int(id) < itemCount.count else { return }
        itemCount[Int(id)] = count
    }

    public func bytes(_ id: UInt32, _ metric: SizeMetric) -> UInt64 {
        guard valid(id) else { return 0 }
        switch metric {
        case .allocated: return SizeUnits.bytes(for: alloc4K[Int(id)])
        case .logical: return SizeUnits.bytes(for: logical4K[Int(id)])
        }
    }

    public func isDirectory(_ id: UInt32) -> Bool {
        flags(id).contains(.directory)
    }

    public func forEachChild(_ id: UInt32, _ body: (UInt32) -> Void) {
        guard valid(id) else { return }
        var child = firstChild[Int(id)]
        var guardrail = 0
        while child != 0 && valid(child) && guardrail < parent.count {
            let next = nextSibling[Int(child)]
            body(child)
            child = next
            guardrail += 1
        }
    }

    public func children(of id: UInt32) -> [UInt32] {
        var result: [UInt32] = []
        forEachChild(id) { result.append($0) }
        return result
    }

    public func path(of id: UInt32, displayRoot: String) -> String {
        guard valid(id) else { return displayRoot }
        if id == rootID { return displayRoot }
        var parts: [String] = []
        var cursor = id
        var guardrail = 0
        while cursor != 0 && cursor != rootID && valid(cursor) && guardrail < parent.count {
            parts.append(name(of: cursor))
            cursor = parent[Int(cursor)]
            guardrail += 1
        }
        let suffix = parts.reversed().joined(separator: "/")
        if displayRoot == "/" { return "/" + suffix }
        if displayRoot.hasSuffix("/") { return displayRoot + suffix }
        return displayRoot + "/" + suffix
    }

    public func chain(to id: UInt32) -> [UInt32] {
        var parts: [UInt32] = []
        var cursor = id
        var guardrail = 0
        while cursor != 0 && valid(cursor) && guardrail < parent.count {
            parts.append(cursor)
            if cursor == rootID { break }
            cursor = parent[Int(cursor)]
            guardrail += 1
        }
        return parts.reversed()
    }

    public func depth(of id: UInt32) -> Int {
        var depth = 0
        var cursor = id
        var guardrail = 0
        while valid(cursor), parent[Int(cursor)] != 0, guardrail < parent.count {
            depth += 1
            cursor = parent[Int(cursor)]
            guardrail += 1
        }
        return depth
    }

    /// Drop every descendant. The node keeps its name, size, and item count and becomes a leaf.
    public mutating func collapseSubtree(_ id: UInt32) {
        guard valid(id) else { return }
        recycleDescendants(of: id)
        flagsRaw[Int(id)] |= NodeFlags.collapsed.rawValue | NodeFlags.directory.rawValue
    }

    /// Keep the largest directories (and any at least `minimumKeep` bytes). Fold the rest into one node and recycle them.
    public mutating func foldSmallDirectories(_ id: UInt32, keepCount: Int, minimumKeep: UInt64) {
        guard valid(id) else { return }
        var directories: [(id: UInt32, bytes: UInt64)] = []
        forEachChild(id) { child in
            guard isDirectory(child) else { return }
            directories.append((child, bytes(child, .allocated)))
        }
        guard directories.count > keepCount else { return }
        let ranked = directories.sorted { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.id < rhs.id
        }
        var folded: [UInt32] = []
        for (index, entry) in ranked.enumerated() {
            if entry.bytes >= minimumKeep || index < keepCount { continue }
            folded.append(entry.id)
        }
        guard !folded.isEmpty else { return }
        var alloc: UInt64 = 0
        var logical: UInt64 = 0
        var items: UInt64 = 0
        for child in folded {
            alloc &+= bytes(child, .allocated)
            logical &+= bytes(child, .logical)
            let childFlags = flags(child)
            if childFlags.contains(.directory) || childFlags.contains(.foldedAggregate) {
                items &+= UInt64(itemCount[Int(child)])
            } else {
                items &+= 1
            }
            recycleDescendants(of: child)
            unlink(child)
            release(child)
        }
        let label = folded.count == 1 ? "1 smaller folder" : "\(folded.count) smaller folders"
        _ = addNode(
            parent: id,
            name: label,
            allocBytes: alloc,
            logicalBytes: logical,
            kind: kind(id),
            flags: .foldedAggregate,
            items: items > UInt64(UInt32.max) ? .max : UInt32(items)
        )
    }

    /// Copy `other`'s children onto `id`, replacing a collapsed leaf with a freshly scanned tree.
    public mutating func graft(from other: NodeStore, onto id: UInt32) {
        guard valid(id), other.rootID != 0 else { return }
        recycleDescendants(of: id)
        flagsRaw[Int(id)] &= ~NodeFlags.collapsed.rawValue
        func copy(_ source: UInt32, parent parentID: UInt32) {
            let child = addNode(
                parent: parentID,
                name: other.name(of: source),
                allocBytes: other.bytes(source, .allocated),
                logicalBytes: other.bytes(source, .logical),
                kind: other.kind(source),
                flags: other.flags(source),
                items: other.itemCount[Int(source)]
            )
            other.forEachChild(source) { copy($0, parent: child) }
        }
        other.forEachChild(other.rootID) { copy($0, parent: id) }
    }

    /// Directory totals are the sum of children. Collapsed directories keep the totals they already stored.
    public mutating func rollup(_ id: UInt32) {
        guard valid(id), isDirectory(id), !flags(id).contains(.collapsed) else { return }
        var alloc: UInt64 = 0
        var logical: UInt64 = 0
        var items: UInt64 = 0
        var lower = false
        var share = false
        forEachChild(id) { child in
            alloc &+= SizeUnits.bytes(for: alloc4K[Int(child)])
            logical &+= SizeUnits.bytes(for: logical4K[Int(child)])
            let childFlags = flags(child)
            if childFlags.contains(.directory) || childFlags.contains(.foldedAggregate) {
                items &+= UInt64(itemCount[Int(child)])
            } else {
                items &+= 1
            }
            if childFlags.contains(.lowerBound) || childFlags.contains(.inaccessible) {
                lower = true
            }
            if childFlags.contains(.mayShareBlocks) { share = true }
        }
        alloc4K[Int(id)] = SizeUnits.units(for: alloc)
        logical4K[Int(id)] = SizeUnits.units(for: logical)
        itemCount[Int(id)] = items > UInt64(UInt32.max) ? .max : UInt32(items)
        if lower { flagsRaw[Int(id)] |= NodeFlags.lowerBound.rawValue }
        if share { flagsRaw[Int(id)] |= NodeFlags.mayShareBlocks.rawValue }
    }

    public mutating func recomputeAll() {
        guard rootID != 0 else { return }
        func walk(_ id: UInt32) {
            forEachChild(id) { child in
                if isDirectory(child), !flags(child).contains(.collapsed) { walk(child) }
            }
            if isDirectory(id), !flags(id).contains(.collapsed) { rollup(id) }
        }
        walk(rootID)
    }

    /// Drop a trashed node and subtract its size from ancestors. O(depth).
    public mutating func removeAndSubtract(_ id: UInt32) {
        guard valid(id), id != rootID else { return }
        let alloc = alloc4K[Int(id)]
        let logical = logical4K[Int(id)]
        let items = contributedItems(id)
        var cursor = parent[Int(id)]
        var guardrail = 0
        while cursor != 0 && valid(cursor) && guardrail < parent.count {
            alloc4K[Int(cursor)] = alloc4K[Int(cursor)] > alloc ? alloc4K[Int(cursor)] - alloc : 0
            logical4K[Int(cursor)] = logical4K[Int(cursor)] > logical ? logical4K[Int(cursor)] - logical : 0
            itemCount[Int(cursor)] = itemCount[Int(cursor)] > items ? itemCount[Int(cursor)] - items : 0
            cursor = parent[Int(cursor)]
            guardrail += 1
        }
        unlink(id)
        flagsRaw[Int(id)] |= NodeFlags.trashed.rawValue
        alloc4K[Int(id)] = 0
        logical4K[Int(id)] = 0
    }

    public func freedIfDeleted(_ id: UInt32) -> UInt64 {
        guard valid(id) else { return 0 }
        if flags(id).contains(.mayShareBlocks) {
            if let own = privateBytes[id], !isDirectory(id) { return own }
            var sum: UInt64 = 0
            var sawChild = false
            forEachChild(id) { child in
                sawChild = true
                sum &+= freedIfDeleted(child)
            }
            if sawChild { return sum }
            return privateBytes[id] ?? bytes(id, .allocated)
        }
        return bytes(id, .allocated)
    }

    public func largestDescendant(under root: UInt32, where predicate: (UInt32) -> Bool) -> UInt32? {
        var best: UInt32?
        var bestBytes: UInt64 = 0
        func walk(_ id: UInt32) {
            forEachChild(id) { child in
                if predicate(child) {
                    let size = bytes(child, .allocated)
                    if best == nil || size > bestBytes {
                        best = child
                        bestBytes = size
                    }
                }
                if isDirectory(child) { walk(child) }
            }
        }
        walk(root)
        return best
    }

    public func findChild(named name: String, of parentID: UInt32) -> UInt32? {
        var found: UInt32?
        forEachChild(parentID) { child in
            if found == nil && self.name(of: child) == name { found = child }
        }
        return found
    }

    private func contributedItems(_ id: UInt32) -> UInt32 {
        let f = flags(id)
        if f.contains(.directory) || f.contains(.foldedAggregate) {
            return itemCount[Int(id)]
        }
        return 1
    }

    private mutating func link(child: UInt32, to parentID: UInt32) {
        let first = firstChild[Int(parentID)]
        if first == 0 {
            firstChild[Int(parentID)] = child
        } else {
            let tail = lastChild[Int(parentID)]
            if tail != 0 {
                nextSibling[Int(tail)] = child
            }
        }
        lastChild[Int(parentID)] = child
    }

    private mutating func recycleDescendants(of id: UInt32) {
        var pending: [UInt32] = []
        var child = firstChild[Int(id)]
        var guardrail = 0
        while child != 0, valid(child), guardrail < parent.count {
            pending.append(child)
            child = nextSibling[Int(child)]
            guardrail += 1
        }
        var index = 0
        while index < pending.count {
            let node = pending[index]
            index += 1
            var next = firstChild[Int(node)]
            var steps = 0
            while next != 0, valid(next), steps < parent.count {
                pending.append(next)
                next = nextSibling[Int(next)]
                steps += 1
            }
        }
        for node in pending.reversed() {
            release(node)
        }
        if valid(id) {
            firstChild[Int(id)] = 0
            lastChild[Int(id)] = 0
        }
    }

    private mutating func release(_ id: UInt32) {
        guard valid(id), id != 0 else { return }
        parent[Int(id)] = 0
        firstChild[Int(id)] = 0
        nextSibling[Int(id)] = 0
        lastChild[Int(id)] = 0
        alloc4K[Int(id)] = 0
        logical4K[Int(id)] = 0
        itemCount[Int(id)] = 0
        flagsRaw[Int(id)] = 0
        privateBytes[id] = nil
        freeList.append(id)
    }

    private mutating func unlink(_ id: UInt32) {
        let parentID = parent[Int(id)]
        guard parentID != 0 else { return }
        var cursor = firstChild[Int(parentID)]
        var previous: UInt32 = 0
        var guardrail = 0
        while cursor != 0 && guardrail < parent.count {
            let next = nextSibling[Int(cursor)]
            if cursor == id {
                if previous == 0 {
                    firstChild[Int(parentID)] = next
                } else {
                    nextSibling[Int(previous)] = next
                }
                if lastChild.indices.contains(Int(parentID)), lastChild[Int(parentID)] == id {
                    lastChild[Int(parentID)] = previous
                }
                nextSibling[Int(id)] = 0
                return
            }
            previous = cursor
            cursor = next
            guardrail += 1
        }
    }

    private func valid(_ id: UInt32) -> Bool {
        Int(id) < parent.count
    }
}
