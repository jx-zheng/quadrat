import AppKit
import QuadratCore
import SwiftUI

enum SnapshotRunner {
    static func render(into directory: String) {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scenes: [(Int, String, () -> AppModel)] = [
            (1, "disk picker", makePicker),
            (2, "full disk access", makeAccess),
            (3, "scanning", makeScanning),
            (4, "main hover", makeHover),
            (5, "drill down", makeDrill),
            (6, "trash confirm", makeTrash)
        ]
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let name = scheme == .light ? "light" : "dark"
            for (index, _, factory) in scenes {
                let model = factory()
                model.drawsTrafficLights = true
                let view = RootView(model: model)
                    .frame(width: 1440, height: 900)
                    .environment(\.colorScheme, scheme)
                let url = folder.appendingPathComponent("screen-\(index)-\(name).png")
                if !write(view, to: url) {
                    FileHandle.standardError.write(Data("failed to render \(url.lastPathComponent)\n".utf8))
                    exit(1)
                }
            }
        }
    }

    private static func write<V: View>(_ view: V, to url: URL) -> Bool {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        for _ in 0..<4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        if let data = renderedPNG(view) {
            do {
                try data.write(to: url)
                return FileManager.default.fileExists(atPath: url.path)
            } catch {
                return false
            }
        }
        let bounds = NSRect(x: 0, y: 0, width: 1440, height: 900)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        host.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
            return FileManager.default.fileExists(atPath: url.path)
        } catch {
            return false
        }
    }

    /// 1440×900 points at 2×, matching the approved mockups.
    private static func renderedPNG<V: View>(_ view: V) -> Data? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(width: 1440, height: 900)
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        guard rep.pixelsWide >= 2000, rep.pixelsHigh >= 1200 else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func base() -> AppModel {
        let model = AppModel()
        model.volumes = DemoDisk.volumes()
        model.selectedVolumeID = "/"
        model.drawsTrafficLights = true
        return model
    }

    private static func makePicker() -> AppModel {
        let model = base()
        model.phase = .picker
        return model
    }

    private static func makeAccess() -> AppModel {
        let model = makePicker()
        model.showAccess = true
        model.accessWaiting = true
        return model
    }

    private static func makeScanning() -> AppModel {
        let model = base()
        model.phase = .scanning
        model.activeVolume = DemoDisk.volumes()[0]
        model.store = DemoDisk.scanningStore()
        model.displayRoot = "/"
        model.homePrefix = "/Users/you"
        model.viewport = CGSize(width: 1200, height: 760)
        model.progressOverride = AppModel.ProgressReadout(
            scanned: 302_000_000_000,
            total: 866_000_000_000,
            items: 1_862_400,
            rate: 214_000,
            skipped: 312,
            path: "~/Library/Developer/CoreSimulator/Devices/4F1C…/data/Containers…"
        )
        model.scanFraction = (302_000_000_000, 866_000_000_000)
        model.stats = ScanStatistics(
            items: 1_862_400, directories: 40_000, inaccessible: 312, nodes: 8_000,
            currentPath: model.progressOverride?.path ?? "", elapsed: 8, itemsPerSecond: 214_000,
            cancelled: false, usedBulkLister: true
        )
        model.rebuildPicture()
        return model
    }

    private static func makeHover() -> AppModel {
        let model = mapped()
        if let docker = find(model, named: "Docker.raw") {
            model.hover = docker
            model.selection = nil
        }
        return model
    }

    private static func makeDrill() -> AppModel {
        let model = mapped()
        if let developer = find(model, named: "Developer"), model.store.isDirectory(developer) {
            model.zoomStack = Array(model.store.chain(to: developer).dropFirst())
            model.rebuildPicture()
        }
        if let devices = find(model, named: "Devices") {
            model.hover = devices
        }
        return model
    }

    private static func makeTrash() -> AppModel {
        let model = mapped()
        if let developer = find(model, named: "Developer"), model.store.isDirectory(developer) {
            model.zoomStack = Array(model.store.chain(to: developer).dropFirst())
        }
        if let derived = find(model, named: "DerivedData") {
            model.selection = derived
        }
        model.showTrash = true
        model.rebuildPicture()
        return model
    }

    private static func mapped() -> AppModel {
        let model = base()
        let demo = DemoDisk.mainStore()
        model.store = demo.store
        model.phase = .map
        model.activeVolume = DemoDisk.volumes()[0]
        model.displayRoot = "/"
        model.homePrefix = "/Users/you"
        model.itemCountOverride = 2_910_027
        model.inaccessibleOverride = 312
        model.elapsedOverride = 38
        model.viewport = CGSize(width: 1200, height: 760)
        model.rebuildPicture()
        return model
    }

    private static func find(_ model: AppModel, named name: String) -> UInt32? {
        model.store.largestDescendant(under: model.store.rootID) {
            model.store.name(of: $0) == name
        }
    }
}
