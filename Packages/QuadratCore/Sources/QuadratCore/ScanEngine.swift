import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Open-addressed set of hard-link identities. A Swift `Set` of every link on a
/// whole disk was about 120 MB; this table is one flat buffer and stops inserting
/// once it is full, so a scan cannot grow without bound. Past the cap, a repeat
/// link is counted again rather than stored.
final class HardLinkSet {
    private var slots: [UInt64]
    private var filled = 0
    private let limit: Int
    private let lock = NSLock()

    init(capacity: Int = 1 << 18) {
        let count = max(16, capacity)
        slots = Array(repeating: 0, count: count)
        limit = count * 3 / 4
    }

    var count: Int { filled }

    /// Returns true when this is the first time `(device, file)` is seen.
    func insertFirst(device: UInt64, file: UInt64) -> Bool {
        guard file != 0 else { return true }
        var key = file &+ (device &* 0x9E3779B97F4A7C15)
        key ^= key >> 30
        if key == 0 { key = 1 }
        lock.lock()
        defer { lock.unlock() }
        let mask = slots.count - 1
        var index = Int(key & UInt64(mask))
        var steps = 0
        while steps < 64 {
            let slot = slots[index]
            if slot == 0 {
                if filled >= limit { return true }
                slots[index] = key
                filled += 1
                return true
            }
            if slot == key { return false }
            index = (index + 1) & mask
            steps += 1
        }
        return true
    }
}

public struct ScanStatistics: Equatable, Sendable {
    public var items: Int
    public var directories: Int
    public var inaccessible: Int
    public var nodes: Int
    public var currentPath: String
    public var elapsed: TimeInterval
    public var itemsPerSecond: Double
    public var cancelled: Bool
    public var usedBulkLister: Bool

    public init(
        items: Int, directories: Int, inaccessible: Int, nodes: Int,
        currentPath: String, elapsed: TimeInterval, itemsPerSecond: Double,
        cancelled: Bool, usedBulkLister: Bool
    ) {
        self.items = items
        self.directories = directories
        self.inaccessible = inaccessible
        self.nodes = nodes
        self.currentPath = currentPath
        self.elapsed = elapsed
        self.itemsPerSecond = itemsPerSecond
        self.cancelled = cancelled
        self.usedBulkLister = usedBulkLister
    }
}

public final class ScanEngine {
    public private(set) var store = NodeStore()
    public private(set) var rootDevice: UInt64 = 0
    public private(set) var usedBulkLister = false

    private let lock = NSLock()
    private var completions = 0
    private var cancelled = false
    private var items = 0
    private var directories = 0
    private var inaccessible = 0
    private var currentPath = ""
    private var pendingChildren: [UInt32: Int] = [:]
    private let links = HardLinkSet()
    private var started = Date()
    private var lister: DirectoryListing?
    private var fallback: DirectoryListing?
    private var skip: ((String) -> Bool)?
    private var queue: WorkStealingQueue?
    private let workerCount: Int

    public init(workerCount: Int? = nil) {
        let active = ProcessInfo.processInfo.activeProcessorCount
        let chosen = workerCount ?? min(8, max(1, active))
        self.workerCount = max(1, min(8, chosen))
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func withStore<T>(_ body: (inout NodeStore) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&store)
    }

    public var hardLinkCount: Int { links.count }

    public func statistics() -> ScanStatistics {
        lock.lock()
        defer { lock.unlock() }
        let elapsed = Date().timeIntervalSince(started)
        let rate = elapsed > 0 ? Double(items) / elapsed : 0
        return ScanStatistics(
            items: items,
            directories: directories,
            inaccessible: inaccessible,
            nodes: store.nodeCount,
            currentPath: currentPath,
            elapsed: elapsed,
            itemsPerSecond: rate,
            cancelled: cancelled,
            usedBulkLister: usedBulkLister
        )
    }

    @discardableResult
    public func scan(
        rootPath: String,
        displayName: String,
        lister: DirectoryListing,
        fallback: DirectoryListing? = nil,
        rootDevice explicitDevice: UInt64? = nil,
        skip: ((String) -> Bool)? = nil
    ) -> NodeStore {
        self.lister = lister
        self.fallback = fallback
        self.skip = skip
        self.started = Date()
        self.store = NodeStore()
        self.store.reserve(65_536)
        let device = explicitDevice ?? PathDevice.device(of: rootPath) ?? 1
        self.rootDevice = device
        let root = store.addRoot(name: displayName, kind: .developer)
        let jobs = WorkStealingQueue(workers: workerCount)
        self.queue = jobs
        jobs.push(ScanJob(node: root, path: rootPath), worker: 0)

        if workerCount == 1 {
            drain(worker: 0)
        } else {
            let group = DispatchGroup()
            let pool = DispatchQueue(label: "com.kevinzheng.quadrat.scan", qos: .utility, attributes: .concurrent)
            for worker in 0..<workerCount {
                group.enter()
                pool.async {
                    self.drain(worker: worker)
                    group.leave()
                }
            }
            group.wait()
        }
        lock.lock()
        store.recomputeAll()
        pendingChildren.removeAll()
        lock.unlock()
        self.queue = nil
        return store
    }

    private func drain(worker: Int) {
        guard let jobs = queue else { return }
        while true {
            let job = jobs.popLocal(worker: worker) ?? jobs.steal(by: worker)
            if let job {
                #if canImport(ObjectiveC)
                autoreleasepool {
                    process(node: job.node, path: job.path, worker: worker)
                }
                #else
                process(node: job.node, path: job.path, worker: worker)
                #endif
                jobs.finishOne()
                continue
            }
            if !jobs.waitForWork() { return }
        }
    }

    private func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func process(node: UInt32, path: String, worker: Int) {
        lock.lock()
        currentPath = path
        let stop = cancelled
        lock.unlock()
        if stop {
            complete(node)
            return
        }

        var subdirs: [(UInt32, String)] = []
        lock.lock()
        let depth = store.depth(of: node)
        let parentKind = store.kind(node)
        lock.unlock()
        let keepCount = Folding.largestKept(depth: depth)
        var keptSmall: [(entry: ListedEntry, duplicate: Bool)] = []
        var largeFiles: [(entry: ListedEntry, duplicate: Bool)] = []
        var foldedAlloc: UInt64 = 0
        var foldedLogical: UInt64 = 0
        var foldedCount = 0
        var foldedShare = false

        func fold(_ entry: ListedEntry, duplicate: Bool) {
            if !duplicate {
                foldedAlloc &+= entry.allocBytes
                foldedLogical &+= entry.logicalBytes
                if entry.mayShareBlocks { foldedShare = true }
            }
            foldedCount += 1
        }

        var seen = 0
        let outcome = enumerate(path) { entry in
            if entry.isDotOrEmpty { return }
            seen += 1
            let descend = entry.isDirectory && !entry.isSymlink && !entry.isMountPoint
            let name: String
            if self.skip != nil || descend || entry.inaccessible {
                name = entry.nameString()
            } else {
                name = ""
            }
            let childPath: String
            if self.skip != nil || descend {
                childPath = self.join(path, name)
            } else {
                childPath = ""
            }
            if let skip = self.skip, skip(childPath) {
                self.lock.lock()
                self.inaccessible += 1
                let kind = KindClassifier.classify(name: name, parent: parentKind, isDirectory: true)
                _ = self.store.addNode(
                    parent: node,
                    name: name,
                    allocBytes: 0,
                    logicalBytes: 0,
                    kind: kind,
                    flags: [.directory, .inaccessible, .lowerBound]
                )
                self.lock.unlock()
                return
            }
            if entry.inaccessible {
                self.lock.lock()
                self.inaccessible += 1
                let flags: NodeFlags = entry.isDirectory
                    ? [.directory, .inaccessible, .lowerBound]
                    : [.inaccessible, .lowerBound]
                let kind = KindClassifier.classify(name: name, parent: parentKind, isDirectory: entry.isDirectory)
                _ = self.store.addNode(
                    parent: node,
                    name: name,
                    allocBytes: 0,
                    logicalBytes: 0,
                    kind: kind,
                    flags: flags
                )
                self.store.insertFlags(.lowerBound, on: node)
                self.lock.unlock()
                return
            }

            if descend {
                self.lock.lock()
                self.directories += 1
                let kind = KindClassifier.classify(name: name, parent: parentKind, isDirectory: true)
                let child = self.store.addNode(
                    parent: node,
                    name: name,
                    allocBytes: 0,
                    logicalBytes: 0,
                    kind: kind,
                    flags: .directory
                )
                self.lock.unlock()
                subdirs.append((child, childPath))
                return
            }

            let duplicate = entry.linkCount > 1 && !self.links.insertFirst(device: entry.device, file: entry.fileID)
            if entry.allocBytes >= Folding.minimumKeepBytes {
                largeFiles.append((entry.materialized(), duplicate))
                return
            }
            if keptSmall.count < keepCount {
                keptSmall.append((entry.materialized(), duplicate))
                return
            }
            var smallest = 0
            for index in 1..<keptSmall.count where keptSmall[index].entry.allocBytes < keptSmall[smallest].entry.allocBytes {
                smallest = index
            }
            if entry.allocBytes > keptSmall[smallest].entry.allocBytes {
                let dropped = keptSmall[smallest]
                fold(dropped.entry, duplicate: dropped.duplicate)
                keptSmall[smallest] = (entry.materialized(), duplicate)
            } else if !duplicate {
                foldedAlloc &+= entry.allocBytes
                foldedLogical &+= entry.logicalBytes
                foldedCount += 1
                if entry.mayShareBlocks { foldedShare = true }
            } else {
                foldedCount += 1
            }
        }

        lock.lock()
        items += seen
        lock.unlock()

        switch outcome {
        case .entries:
            break
        case .inaccessible:
            lock.lock()
            inaccessible += 1
            store.insertFlags([.inaccessible, .lowerBound], on: node)
            lock.unlock()
            complete(node)
            return
        case .unsupported, .failed:
            lock.lock()
            inaccessible += 1
            store.insertFlags([.inaccessible, .lowerBound], on: node)
            lock.unlock()
            complete(node)
            return
        }

        let smallKeep = max(0, keepCount - largeFiles.count)
        if smallKeep == 0 {
            for item in keptSmall {
                fold(item.entry, duplicate: item.duplicate)
            }
            keptSmall.removeAll()
        } else if keptSmall.count > smallKeep {
            keptSmall.sort { $0.entry.allocBytes > $1.entry.allocBytes }
            for item in keptSmall[smallKeep...] {
                fold(item.entry, duplicate: item.duplicate)
            }
            keptSmall.removeSubrange(smallKeep...)
        }

        lock.lock()
        for item in largeFiles + keptSmall {
            let entry = item.entry
            let kind = KindClassifier.classify(name: entry.name, parent: parentKind, isDirectory: false)
            var flags: NodeFlags = []
            if entry.isSymlink { flags.insert(.symlink) }
            if entry.isMountPoint { flags.insert(.mountPoint) }
            if entry.mayShareBlocks { flags.insert(.mayShareBlocks) }
            if item.duplicate { flags.insert(.hardLinkDuplicate) }
            let alloc = item.duplicate ? 0 : entry.allocBytes
            let logical = item.duplicate ? 0 : entry.logicalBytes
            let id = store.addNode(
                parent: node,
                name: entry.name,
                allocBytes: alloc,
                logicalBytes: logical,
                kind: kind,
                flags: flags,
                privateSize: entry.mayShareBlocks ? entry.privateBytes : nil
            )
            if entry.isMountPoint {
                store.insertFlags(.mountPoint, on: id)
            }
        }
        if foldedCount > 0 {
            let label = foldedCount == 1 ? "1 smaller file" : "\(foldedCount) smaller files"
            var flags: NodeFlags = .foldedAggregate
            if foldedShare { flags.insert(.mayShareBlocks) }
            _ = store.addNode(
                parent: node,
                name: label,
                allocBytes: foldedAlloc,
                logicalBytes: foldedLogical,
                kind: parentKind,
                flags: flags,
                items: UInt32(foldedCount)
            )
        }
        pendingChildren[node] = subdirs.count
        lock.unlock()

        if subdirs.isEmpty {
            complete(node)
            return
        }

        let jobs = queue
        for (child, childPath) in subdirs {
            if isCancelled() {
                complete(child)
                continue
            }
            let overCap = (jobs?.queuedCount ?? 0) >= WorkStealingQueue.queuedCap
            if overCap || jobs == nil {
                process(node: child, path: childPath, worker: worker)
            } else {
                jobs?.push(ScanJob(node: child, path: childPath), worker: worker)
            }
        }
    }

    private func enumerate(_ path: String, _ body: (StreamedRecord) -> Void) -> ListOutcome {
        guard let lister else { return .failed }
        let outcome = lister.enumerateStream(path: path, rootDevice: rootDevice, body)
        if case .unsupported = outcome, let fallback {
            return fallback.enumerateStream(path: path, rootDevice: rootDevice, body)
        }
        if lister is BulkListing, case .entries = outcome {
            lock.lock()
            usedBulkLister = true
            lock.unlock()
        }
        return outcome
    }

    private func complete(_ id: UInt32) {
        lock.lock()
        store.rollup(id)
        let depth = store.depth(of: id)
        let size = store.bytes(id, .allocated)
        if id != store.rootID, store.isDirectory(id), Folding.shouldCollapseSubtree(depth: depth, bytes: size) {
            store.collapseSubtree(id)
        } else if store.isDirectory(id) {
            store.foldSmallDirectories(id, keepCount: Folding.largestKept(depth: depth), minimumKeep: Folding.minimumKeepBytes)
            store.rollup(id)
        }
        let parent = id < UInt32(store.endIndex) ? store.parent[Int(id)] : 0
        var parentDone = false
        if parent != 0 {
            let left = (pendingChildren[parent] ?? 1) - 1
            pendingChildren[parent] = left
            parentDone = left <= 0
        }
        lock.unlock()
        reclaimIfNeeded()
        if parentDone {
            complete(parent)
        }
    }

    /// Return freed scanner pages so the resident set tracks the live tree.
    private func reclaimIfNeeded() {
        #if os(macOS)
        lock.lock()
        completions += 1
        let due = (completions & 127) == 0
        lock.unlock()
        if due {
            _ = malloc_zone_pressure_relief(nil, Int.max)
        }
        #endif
    }

    private func join(_ parent: String, _ name: String) -> String {
        if parent == "/" { return "/" + name }
        return parent + "/" + name
    }
}

/// Marker protocol so the engine can report whether the bulk lister ran.
public protocol BulkListing: DirectoryListing {}
