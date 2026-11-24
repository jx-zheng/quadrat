import AppKit
import QuadratCore

/// Plays the disk picker, a scan, hover, drill-down, and the trash confirmation, then exits.
/// Nothing is moved to the Trash.
@MainActor
enum DemoRunner {
    static func start(model: AppModel) {
        model.volumes = DemoDisk.volumes()
        model.selectedVolumeID = "/"
        model.drawsTrafficLights = true
        model.phase = .picker
        model.showAccess = false
        model.showTrash = false

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            presentWindow()
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await playScan(model)
            showMap(model)
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            hover(model, named: "Docker.raw")
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            hover(model, named: "originals")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            model.clearHover()
            if let developer = find(model, named: "Developer"), model.store.isDirectory(developer) {
                model.zoom(into: developer)
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            hover(model, named: "Atlas-gyeunrzcfqpoti")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            model.clearHover()
            if let derived = find(model, named: "DerivedData") {
                model.selection = derived
                model.showTrash = true
            }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            model.showTrash = false
            model.selection = nil
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            model.zoomOut()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            NSApp.terminate(nil)
            exit(0)
        }
    }

    private static func playScan(_ model: AppModel) async {
        let volume = DemoDisk.volumes()[0]
        model.activeVolume = volume
        model.displayRoot = "/"
        model.homePrefix = "/Users/you"
        model.phase = .scanning
        model.store = DemoDisk.scanningStore()
        model.viewport = CGSize(width: 1100, height: 720)
        model.rebuildPicture()
        let total = DemoDisk.used
        let steps = 16
        for step in 1...steps {
            let scanned = total * UInt64(step) / UInt64(steps)
            let items = 1_862_400 * step / steps
            model.progressOverride = AppModel.ProgressReadout(
                scanned: scanned,
                total: total,
                items: items,
                rate: 214_000,
                skipped: step > 4 ? 312 : 0,
                path: "~/Library/Developer/CoreSimulator/Devices/4F1C…/data/Containers…"
            )
            model.scanFraction = (scanned, total)
            model.stats = ScanStatistics(
                items: items, directories: 4_000 * step, inaccessible: step > 4 ? 312 : 0, nodes: 800 * step,
                currentPath: model.progressOverride?.path ?? "", elapsed: Double(step), itemsPerSecond: 214_000,
                cancelled: false, usedBulkLister: true
            )
            model.rebuildPicture()
            try? await Task.sleep(nanoseconds: 1_100_000_000)
        }
    }

    private static func showMap(_ model: AppModel) {
        let demo = DemoDisk.mainStore()
        model.store = demo.store
        model.phase = .map
        model.activeVolume = DemoDisk.volumes()[0]
        model.displayRoot = "/"
        model.homePrefix = "/Users/you"
        model.zoomStack = []
        model.selection = nil
        model.hover = nil
        model.progressOverride = nil
        model.scanFraction = nil
        model.itemCountOverride = 2_910_027
        model.inaccessibleOverride = 312
        model.elapsedOverride = 38
        model.stats = ScanStatistics(
            items: 2_910_027, directories: 80_000, inaccessible: 312, nodes: 12_000,
            currentPath: "", elapsed: 38, itemsPerSecond: 0,
            cancelled: false, usedBulkLister: true
        )
        model.rebuildPicture()
    }

    private static func hover(_ model: AppModel, named name: String) {
        guard let id = find(model, named: name) else { return }
        model.selection = nil
        model.hover = id
    }

    private static func find(_ model: AppModel, named name: String) -> UInt32? {
        model.store.largestDescendant(under: model.store.rootID) {
            model.store.name(of: $0) == name
        }
    }

    private static func presentWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.setFrame(NSRect(x: 80, y: 80, width: 1440, height: 900), display: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}
