import AppKit
import Foundation
import QuadratCore

final class ScanBox {
    let lock = NSLock()
    var running = false
    var viewport = CGSize(width: 1000, height: 700)
    var metric: SizeMetric = .allocated
    var zoom: UInt32 = 0
    var engine: ScanEngine?
}

final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case picker
        case scanning
        case map
    }

    @Published var phase: Phase = .picker
    @Published var volumes: [DiskVolume] = []
    @Published var selectedVolumeID: String?
    @Published var showAccess = false
    @Published var accessWaiting = false
    @Published var store = NodeStore()
    @Published var metric: SizeMetric = .allocated
    @Published var zoomStack: [UInt32] = []
    @Published var forwardStack: [UInt32] = []
    @Published var selection: UInt32?
    @Published var hover: UInt32?
    @Published var hoverPoint: CGPoint = .zero
    @Published var showTrash = false
    @Published var trashError: String?
    @Published var searchText = ""
    @Published var stats = ScanStatistics(
        items: 0, directories: 0, inaccessible: 0, nodes: 0,
        currentPath: "", elapsed: 0, itemsPerSecond: 0, cancelled: false, usedBulkLister: true
    )
    @Published var picture = MapPicture()
    @Published var viewport = CGSize(width: 1000, height: 720)
    @Published var drawsTrafficLights = false
    @Published var itemCountOverride: UInt64?
    @Published var inaccessibleOverride: Int?
    @Published var elapsedOverride: TimeInterval?
    @Published var progressOverride: ProgressReadout?
    @Published var scanFraction: (scanned: UInt64, used: UInt64)?
    @Published var homePrefix = NSHomeDirectory()
    @Published var displayRoot = "/"
    @Published var activeVolume: DiskVolume?
    @Published var statusNote = ""

    let quickLook = QuickLookBridge()
    private var box: ScanBox?
    private var keyMonitor: Any?
    private var pendingVolume: DiskVolume?
    private var pendingLimited = false

    struct ProgressReadout: Equatable {
        var scanned: UInt64
        var total: UInt64
        var items: Int
        var rate: Double
        var skipped: Int
        var path: String
    }

    var zoomID: UInt32 {
        zoomStack.last ?? store.rootID
    }

    var isZoomed: Bool {
        guard let root = Optional(store.rootID), root != 0 else { return false }
        return zoomID != root
    }

    var selectedVolume: DiskVolume? {
        volumes.first { $0.id == selectedVolumeID } ?? volumes.first { !$0.isNetwork }
    }

    func refreshVolumes() {
        let loaded = VolumeCatalog.current()
        if loaded.isEmpty {
            volumes = DemoDisk.volumes()
            selectedVolumeID = "/"
            return
        }
        volumes = loaded
        if selectedVolumeID == nil {
            selectedVolumeID = loaded.first(where: { !$0.isNetwork })?.id
        }
    }

    func recheckAccess() {
        guard showAccess, accessWaiting, let volume = pendingVolume else { return }
        if FullDiskAccess.isGranted() {
            showAccess = false
            accessWaiting = false
            launchScan(volume, limited: false)
        }
    }

    func choose(_ volume: DiskVolume) {
        guard !volume.isNetwork else { return }
        selectedVolumeID = volume.id
    }

    func requestScan() {
        guard let volume = selectedVolume, !volume.isNetwork else { return }
        if volume.isStartup && !FullDiskAccess.isGranted() {
            pendingVolume = volume
            pendingLimited = false
            showAccess = true
            accessWaiting = true
            return
        }
        launchScan(volume, limited: false)
    }

    func continueLimited() {
        guard let volume = pendingVolume ?? selectedVolume else { return }
        pendingLimited = true
        showAccess = false
        accessWaiting = false
        launchScan(volume, limited: true)
    }

    func openAccessSettings() {
        accessWaiting = true
        FullDiskAccess.openSettings()
    }

    func scanFolder(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        let volume = DiskVolume(
            id: url.path,
            name: url.lastPathComponent,
            detail: "Folder",
            symbol: "folder",
            capacity: 0,
            available: 0,
            purgeable: 0,
            isNetwork: false,
            isStartup: url.path.hasPrefix(NSHomeDirectory()) || url.path == "/",
            isRemovable: false,
            lastScanned: LastScanStore.date(for: url.path),
            snapshotCount: 0
        )
        if !FullDiskAccess.isGranted() {
            pendingVolume = volume
            showAccess = true
            accessWaiting = true
            phase = .picker
            return
        }
        launchScan(volume, limited: false)
    }

    func stopScan() {
        box?.engine?.cancel()
        box?.running = false
        phase = .picker
    }

    func rescan() {
        guard let volume = activeVolume else { return }
        launchScan(volume, limited: pendingLimited)
    }

    func updateViewport(_ size: CGSize) {
        guard size.width > 10, size.height > 10 else { return }
        viewport = size
        box?.lock.lock()
        box?.viewport = size
        box?.metric = metric
        box?.zoom = zoomID
        box?.lock.unlock()
        if phase != .scanning {
            rebuildPicture()
        }
    }

    func setMetric(_ metric: SizeMetric) {
        self.metric = metric
        rebuildPicture()
    }

    func click(at point: CGPoint) {
        guard let id = hit(point), id != zoomID else {
            selection = nil
            return
        }
        if let node = picture.layout.nodes.first(where: { $0.id == id }),
           node.header > 0,
           point.y < node.y + node.header,
           store.isDirectory(id) {
            zoom(into: id)
            return
        }
        if selection == id, store.isDirectory(id), id != zoomID {
            zoom(into: id)
            return
        }
        selection = id
    }

    func hover(at point: CGPoint) {
        hoverPoint = point
        let id = hit(point)
        hover = (id == nil || id == zoomID) ? nil : id
    }

    func clearHover() {
        hover = nil
    }

    func zoom(into id: UInt32) {
        guard store.isDirectory(id), id != zoomID else { return }
        if store.flags(id).contains(.collapsed), let path = url(for: id)?.path {
            let built = ScanEngine(workerCount: 1).scan(
                rootPath: path,
                displayName: store.name(of: id),
                lister: BulkDirectoryListing(),
                fallback: POSIXListing()
            )
            store.graft(from: built, onto: id)
        }
        forwardStack.removeAll()
        zoomStack.append(id)
        selection = nil
        hover = nil
        rebuildPicture()
    }

    func zoomOut() {
        guard !zoomStack.isEmpty else { return }
        let popped = zoomStack.removeLast()
        forwardStack.append(popped)
        selection = popped
        rebuildPicture()
    }

    func zoomForward() {
        guard let next = forwardStack.popLast() else { return }
        zoomStack.append(next)
        selection = nil
        rebuildPicture()
    }

    func zoomToRoot() {
        guard !zoomStack.isEmpty else { return }
        forwardStack.append(contentsOf: zoomStack.reversed())
        zoomStack.removeAll()
        selection = nil
        rebuildPicture()
    }

    func zoomTo(index: Int) {
        let chain = breadcrumbIDs
        guard chain.indices.contains(index) else { return }
        let target = chain[index]
        if target == store.rootID {
            zoomToRoot()
            return
        }
        zoomStack = Array(chain.dropFirst().prefix(index))
        rebuildPicture()
    }

    var breadcrumbIDs: [UInt32] {
        guard store.rootID != 0 else { return [] }
        return store.chain(to: zoomID)
    }

    func moveSelection(dx: CGFloat, dy: CGFloat) {
        let candidates = picture.tiles.filter { $0.depth == 1 }
        guard !candidates.isEmpty else { return }
        let current = candidates.first { $0.id == selection } ?? candidates.max { $0.width * $0.height < $1.width * $1.height }
        guard let current else { return }
        let origin = CGPoint(x: current.x + current.width / 2, y: current.y + current.height / 2)
        let ranked = candidates.filter { $0.id != current.id }.compactMap { tile -> (UInt32, CGFloat)? in
            let center = CGPoint(x: tile.x + tile.width / 2, y: tile.y + tile.height / 2)
            let vx = center.x - origin.x
            let vy = center.y - origin.y
            if dx > 0 && vx <= 8 { return nil }
            if dx < 0 && vx >= -8 { return nil }
            if dy > 0 && vy <= 8 { return nil }
            if dy < 0 && vy >= -8 { return nil }
            return (tile.id, vx * vx + vy * vy)
        }
        if let next = ranked.min(by: { $0.1 < $1.1 })?.0 {
            selection = next
        }
    }

    func quickLookSelection() {
        guard let url = url(for: selection ?? hover) else { return }
        quickLook.url = url
        quickLook.toggle()
    }

    func revealSelection() {
        guard let url = url(for: selection ?? zoomID) else { return }
        RevealService.show(url)
    }

    func askTrash() {
        guard let id = selection, canTrash(id) else { return }
        trashError = nil
        showTrash = true
    }

    func confirmTrash() {
        guard let id = selection else { return }
        guard let url = url(for: id) else { return }
        do {
            _ = try TrashService.moveToTrash(url)
            store.removeAndSubtract(id)
            selection = nil
            showTrash = false
            rebuildPicture()
        } catch {
            trashError = error.localizedDescription
        }
    }

    func canTrash(_ id: UInt32) -> Bool {
        let flags = store.flags(id)
        if flags.contains(.hatched) || flags.contains(.mountPoint) || id == store.rootID { return false }
        return url(for: id) != nil
    }

    func findSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, store.rootID != 0 else { return }
        guard let match = store.largestDescendant(under: store.rootID, where: { name in
            store.name(of: name).localizedCaseInsensitiveContains(query)
        }) else { return }
        let parent = store.parent[Int(match)]
        if parent != 0 && parent != store.rootID {
            zoomStack = Array(store.chain(to: parent).dropFirst())
        } else {
            zoomStack = []
        }
        selection = match
        rebuildPicture()
    }

    func jump(to name: String) {
        guard store.rootID != 0 else { return }
        let needle = name.replacingOccurrences(of: "~/", with: "")
        guard let match = store.largestDescendant(under: store.rootID, where: {
            store.name(of: $0).caseInsensitiveCompare(needle) == .orderedSame || store.path(of: $0).localizedCaseInsensitiveContains(needle)
        }) else { return }
        if store.isDirectory(match) {
            zoomStack = Array(store.chain(to: match).dropFirst())
            selection = nil
        } else {
            let parent = store.parent[Int(match)]
            zoomStack = parent == store.rootID ? [] : Array(store.chain(to: parent).dropFirst())
            selection = match
        }
        rebuildPicture()
    }

    func path(of id: UInt32) -> String {
        let raw = store.path(of: id, displayRoot: displayRoot)
        if homePrefix != "/", raw.hasPrefix(homePrefix) {
            return "~" + raw.dropFirst(homePrefix.count)
        }
        return raw
    }

    func url(for id: UInt32?) -> URL? {
        guard let id, id != store.rootID, store.rootID != 0 else {
            if let id, id == store.rootID { return URL(fileURLWithPath: displayRoot == "/" ? "/" : displayRoot) }
            return nil
        }
        let raw = store.path(of: id, displayRoot: displayRoot)
        let path = raw.hasPrefix("~") ? NSString(string: raw).expandingTildeInPath : raw
        return URL(fileURLWithPath: path)
    }

    func nodeBytes(_ id: UInt32) -> UInt64 {
        store.bytes(id, metric)
    }

    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    func loadDemoMap() {
        let demo = DemoDisk.mainStore()
        store = demo.store
        activeVolume = DemoDisk.volumes()[0]
        volumes = DemoDisk.volumes()
        selectedVolumeID = "/"
        displayRoot = "/"
        homePrefix = "/Users/you"
        phase = .map
        itemCountOverride = 2_910_027
        inaccessibleOverride = 312
        elapsedOverride = 38
        zoomStack = []
        rebuildPicture()
    }

    func rebuildPicture() {
        let root = zoomID
        guard root != 0 else {
            picture = MapPicture()
            return
        }
        let scanned = phase == .scanning ? scanFraction?.scanned : nil
        let used = phase == .scanning ? scanFraction?.used : nil
        picture = MapPicture.make(
            store: store,
            root: root,
            width: viewport.width,
            height: viewport.height,
            metric: metric,
            scanned: scanned,
            volumeUsed: used,
            zoomed: isZoomed
        )
    }

    private func hit(_ point: CGPoint) -> UInt32? {
        HitTest.hit(picture.layout, x: point.x, y: point.y)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard phase == .map || phase == .scanning else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.keyCode == 51 { // delete
            askTrash()
            return true
        }
        if flags.contains(.command), event.keyCode == 126 { // up arrow
            zoomOut()
            return true
        }
        switch event.keyCode {
        case 126: moveSelection(dx: 0, dy: -1); return true
        case 125: moveSelection(dx: 0, dy: 1); return true
        case 123: moveSelection(dx: -1, dy: 0); return true
        case 124: moveSelection(dx: 1, dy: 0); return true
        case 36, 76: // return
            if let selection, store.isDirectory(selection) { zoom(into: selection) }
            return true
        case 49: // space
            quickLookSelection()
            return true
        case 53: // escape
            if showTrash { showTrash = false; return true }
            if isZoomed { zoomOut(); return true }
            return false
        default:
            return false
        }
    }

    private func launchScan(_ volume: DiskVolume, limited: Bool) {
        phase = .scanning
        showTrash = false
        showAccess = false
        activeVolume = volume
        displayRoot = volume.mountPathOrRoot
        homePrefix = NSHomeDirectory()
        zoomStack = []
        selection = nil
        hover = nil
        itemCountOverride = nil
        inaccessibleOverride = nil
        elapsedOverride = nil
        progressOverride = nil
        store = NodeStore()
        picture = MapPicture()
        let scanRoot = volume.scanRoot
        let home = NSHomeDirectory()
        let skips = limited ? [home + "/Desktop", home + "/Documents", home + "/Downloads"] : []
        let engine = ScanEngine()
        let box = ScanBox()
        box.engine = engine
        box.running = true
        box.viewport = viewport
        box.metric = metric
        self.box = box
        if volume.used > 0 {
            scanFraction = (0, volume.used)
        }
        Thread.detachNewThread { [weak self] in
            let result = engine.scan(
                rootPath: scanRoot,
                displayName: volume.name,
                lister: BulkDirectoryListing(),
                fallback: POSIXListing(),
                skip: { path in
                    skips.contains { path == $0 || path.hasPrefix($0 + "/") }
                }
            )
            box.running = false
            var finished = result
            let scanned = finished.rootID == 0 ? 0 : finished.bytes(finished.rootID, .allocated)
            if volume.used > scanned, finished.rootID != 0 {
                _ = finished.addNode(
                    parent: finished.rootID,
                    name: "System & Other",
                    allocBytes: volume.used - scanned,
                    logicalBytes: volume.used - scanned,
                    kind: .system,
                    flags: [.hatched]
                )
                finished.rollup(finished.rootID)
            }
            CloneProbe.apply(store: &finished, rootPath: scanRoot)
            let finalStats = engine.statistics()
            DispatchQueue.main.async {
                guard let self else { return }
                self.store = finished
                self.stats = finalStats
                self.scanFraction = nil
                self.phase = .map
                LastScanStore.record(volume.id)
                self.refreshVolumes()
                self.rebuildPicture()
            }
        }
        Thread.detachNewThread { [weak self] in
            while box.running {
                let stats = engine.statistics()
                box.lock.lock()
                let size = box.viewport
                let metric = box.metric
                box.lock.unlock()
                let scanned = engine.withStore { store -> UInt64 in
                    store.rootID == 0 ? 0 : store.bytes(store.rootID, metric)
                }
                let frame = engine.withStore { store -> MapPicture in
                    MapPicture.make(
                        store: store,
                        root: store.rootID,
                        width: size.width,
                        height: size.height,
                        metric: metric,
                        scanned: volume.used > 0 ? scanned : nil,
                        volumeUsed: volume.used > 0 ? volume.used : nil,
                        zoomed: false
                    )
                }
                DispatchQueue.main.async {
                    guard let self, self.phase == .scanning else { return }
                    self.stats = stats
                    self.picture = frame
                    if volume.used > 0 {
                        self.scanFraction = (scanned, volume.used)
                    }
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }
}

extension DiskVolume {
    var mountPathOrRoot: String { id }
    var scanRoot: String {
        if id == "/", FileManager.default.fileExists(atPath: "/System/Volumes/Data") {
            return "/System/Volumes/Data"
        }
        return id
    }
}

extension NodeStore {
    func path(of id: UInt32) -> String {
        self.path(of: id, displayRoot: "/")
    }
}
