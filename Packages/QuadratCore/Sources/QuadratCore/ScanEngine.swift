import Foundation

final class HardLinkSet {
    private let locks: [NSLock]
    private var shards: [Set<UInt64>]

    init(shardCount: Int = 16) {
        let count = max(1, shardCount)
        locks = (0..<count).map { _ in NSLock() }
        shards = Array(repeating: [], count: count)
    }

    /// Returns true when this is the first time `(device, file)` is seen.
    func insertFirst(device: UInt64, file: UInt64) -> Bool {
        guard file != 0 else { return true }
        var key = file &+ (device &* 0x9E3779B97F4A7C15)
        key ^= key >> 30
        let index = Int(key % UInt64(locks.count))
        locks[index].lock()
        defer { locks[index].unlock() }
        if shards[index].contains(key) { return false }
        shards[index].insert(key)
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
                process(node: job.node, path: job.path, worker: worker)
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

        let outcome = list(path)
        let entries: [ListedEntry]
        switch outcome {
        case .entries(let listed):
            entries = listed
        case .inaccessible:
            lock.lock()
            inaccessible += 1
            store.insertFlags([.inaccessible, .lowerBound], on: node)
            lock.unlock()
            complete(node)
            return
        case .unsupported, .failed:
            if let fallback, !(lister is POSIXListing) {
                let second = fallback.list(path: path, rootDevice: rootDevice)
                if case .entries(let listed) = second {
                    entries = listed
                    break
                }
            }
            lock.lock()
            inaccessible += 1
            store.insertFlags([.inaccessible, .lowerBound], on: node)
            lock.unlock()
            complete(node)
            return
        }

        var subdirs: [(UInt32, String)] = []
        var files: [(key: String, entry: ListedEntry)] = []

        lock.lock()
        items += entries.count
        let parentKind = store.kind(node)
        lock.unlock()

        for entry in entries {
            if entry.name == "." || entry.name == ".." || entry.name.isEmpty { continue }
            let childPath = join(path, entry.name)
            if skip?(childPath) == true {
                lock.lock()
                inaccessible += 1
                let kind = KindClassifier.classify(name: entry.name, parent: parentKind, isDirectory: true)
                _ = store.addNode(
                    parent: node,
                    name: entry.name,
                    allocBytes: 0,
                    logicalBytes: 0,
                    kind: kind,
                    flags: [.directory, .inaccessible, .lowerBound]
                )
                lock.unlock()
                continue
            }
            if entry.inaccessible {
                lock.lock()
                inaccessible += 1
                let flags: NodeFlags = entry.isDirectory
                    ? [.directory, .inaccessible, .lowerBound]
                    : [.inaccessible, .lowerBound]
                let kind = KindClassifier.classify(name: entry.name, parent: parentKind, isDirectory: entry.isDirectory)
                _ = store.addNode(
                    parent: node,
                    name: entry.name,
                    allocBytes: 0,
                    logicalBytes: 0,
                    kind: kind,
                    flags: flags
                )
                store.insertFlags(.lowerBound, on: node)
                lock.unlock()
                continue
            }

            let descend = entry.isDirectory && !entry.isSymlink && !entry.isMountPoint
            if descend {
                lock.lock()
                directories += 1
                let kind = KindClassifier.classify(name: entry.name, parent: parentKind, isDirectory: true)
                let child = store.addNode(
                    parent: node,
                    name: entry.name,
                    allocBytes: 0,
                    logicalBytes: 0,
                    kind: kind,
                    flags: .directory
                )
                lock.unlock()
                subdirs.append((child, childPath))
            } else {
                files.append((entry.name, entry))
            }
        }

        lock.lock()
        let depth = store.depth(of: node)
        lock.unlock()
        let decision = Folding.partition(
            files.map { Folding.FileChoice(key: $0.key, bytes: $0.entry.allocBytes) },
            keepCount: Folding.largestKept(depth: depth)
        )
        let keep = Set(decision.keep)
        var foldedAlloc: UInt64 = 0
        var foldedLogical: UInt64 = 0
        var foldedCount = 0
        var foldedShare = false

        lock.lock()
        for file in files {
            let entry = file.entry
            let kind = KindClassifier.classify(name: entry.name, parent: parentKind, isDirectory: false)
            let duplicate = entry.linkCount > 1 && !links.insertFirst(device: entry.device, file: entry.fileID)
            if keep.contains(file.key) {
                var flags: NodeFlags = []
                if entry.isSymlink { flags.insert(.symlink) }
                if entry.isMountPoint { flags.insert(.mountPoint) }
                if entry.mayShareBlocks { flags.insert(.mayShareBlocks) }
                if duplicate { flags.insert(.hardLinkDuplicate) }
                let alloc = duplicate ? 0 : entry.allocBytes
                let logical = duplicate ? 0 : entry.logicalBytes
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
            } else if !duplicate {
                foldedAlloc &+= entry.allocBytes
                foldedLogical &+= entry.logicalBytes
                foldedCount += 1
                if entry.mayShareBlocks { foldedShare = true }
            } else {
                foldedCount += 1
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

    private func list(_ path: String) -> ListOutcome {
        guard let lister else { return .failed }
        let outcome = lister.list(path: path, rootDevice: rootDevice)
        if case .unsupported = outcome, let fallback {
            return fallback.list(path: path, rootDevice: rootDevice)
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
        if parentDone {
            complete(parent)
        }
    }

    private func join(_ parent: String, _ name: String) -> String {
        if parent == "/" { return "/" + name }
        return parent + "/" + name
    }
}

/// Marker protocol so the engine can report whether the bulk lister ran.
public protocol BulkListing: DirectoryListing {}
