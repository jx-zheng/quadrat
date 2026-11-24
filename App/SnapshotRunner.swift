import AppKit
import QuadratCore
import QuartzCore
import SwiftUI

@MainActor
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

    /// One large depth-capped tile. The centre must be a flat colour, not a stretched placeholder.
    static func renderLeafProbe(to path: String) {
        let view = TreemapMapView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        view.backingScale = 2
        var picture = MapPicture()
        picture.tiles = [
            TileDraw(
                id: 7, x: 0, y: 0, width: 230, height: 320, header: 0,
                kind: .developer, name: "Library", sizeText: "40.6 GB",
                showsLabel: true, hatched: false, depth: 1, hasChildren: false,
                isRemainder: false, isDepthCapped: true, bytes: 40_600_000_000
            ),
            TileDraw(
                id: 8, x: 242, y: 0, width: 238, height: 320, header: 0,
                kind: .photos, name: "Pictures", sizeText: "12.0 GB",
                showsLabel: true, hatched: false, depth: 1, hasChildren: false,
                isRemainder: false, isDepthCapped: true, bytes: 12_000_000_000
            )
        ]
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.show(picture: picture, scheme: .light)
        CATransaction.flush()
        let scale: CGFloat = 2
        let pixelsWide = Int(view.bounds.width * scale)
        let pixelsHigh = Int(view.bounds.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            FileHandle.standardError.write(Data("pixel check could not allocate a bitmap\n".utf8))
            exit(1)
        }
        rep.size = view.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let context = NSGraphicsContext.current?.cgContext {
            context.translateBy(x: 0, y: CGFloat(pixelsHigh))
            context.scaleBy(x: scale, y: -scale)
            view.layer?.render(in: context)
        }
        NSGraphicsContext.restoreGraphicsState()
        func sample(_ x: Int, _ y: Int) -> [Int]? {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
            return [
                Int((color.redComponent * 255).rounded()),
                Int((color.greenComponent * 255).rounded()),
                Int((color.blueComponent * 255).rounded())
            ]
        }
        func spread(x0: Int, x1: Int, y0: Int, y1: Int) -> Int {
            var low = [255, 255, 255]
            var high = [0, 0, 0]
            for y in y0...y1 {
                for x in x0...x1 {
                    guard let channels = sample(x, y) else { continue }
                    for index in 0..<3 {
                        low[index] = min(low[index], channels[index])
                        high[index] = max(high[index], channels[index])
                    }
                }
            }
            return zip(low, high).map { abs($0 - $1) }.max() ?? 255
        }
        let midY = pixelsHigh / 2
        let interior = spread(x0: 80, x1: 160, y0: midY - 20, y1: midY + 20)
        guard let left = sample(120, midY), let right = sample(pixelsWide - 80, midY) else { exit(1) }
        if interior > 8 || left[2] < 40 {
            FileHandle.standardError.write(Data("leaf tile interior is not a flat colour (spread \(interior), blue \(left[2]))\n".utf8))
            exit(1)
        }
        var ramp = 0
        var previous = left
        for x in 0..<pixelsWide {
            guard let pixel = sample(x, midY) else { continue }
            let jumped = zip(pixel, previous).map { abs($0 - $1) }.max() ?? 0
            if jumped > 12 { ramp += 1 }
            previous = pixel
        }
        _ = right
        if ramp > 16 {
            FileHandle.standardError.write(Data("tile edge is blurred (\(ramp) steep steps)\n".utf8))
            exit(1)
        }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try? data.write(to: url)
    }

    /// Scan a real directory and write the main window at 1440×900 pt, @2x.
    static func render(path: String, to out: String, scheme: ColorScheme, drill: Bool = false) {
        let model = scannedModel(path: path)
        if drill, let target = largestDirectory(in: model) {
            model.zoom(into: target)
        }
        NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let view = RootView(model: model)
            .frame(width: 1440, height: 900)
            .environment(\.colorScheme, scheme)
        let url = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !write(view, to: url) {
            FileHandle.standardError.write(Data("failed to render \(out)\n".utf8))
            exit(1)
        }
    }

    /// Volume root, home, and one drill-in, each in light and dark. Each root is scanned once.
    static func renderSuite(into directory: String) {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        renderPair(path: "/", prefix: folder.appendingPathComponent("volume").path, drill: true)
        renderPair(path: NSHomeDirectory(), prefix: folder.appendingPathComponent("home").path, drill: false)
    }

    private static func renderPair(path: String, prefix: String, drill: Bool) {
        let model = scannedModel(path: path)
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let name = scheme == .light ? "light" : "dark"
            render(model: model, scheme: scheme, to: "\(prefix)-\(name).png")
        }
        guard drill, let target = largestDirectory(in: model) else { return }
        model.zoom(into: target)
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let name = scheme == .light ? "light" : "dark"
            render(model: model, scheme: scheme, to: "\(prefix)-drill-\(name).png")
        }
    }

    private static func scannedModel(path: String) -> AppModel {
        let session = VolumeMode.prepare(path: path)
        let engine = ScanEngine(workerCount: 8)
        var store = engine.scan(
            rootPath: session.scanRoot,
            displayName: session.volume.name,
            lister: BulkDirectoryListing(),
            fallback: POSIXListing()
        )
        VolumeMode.addUnscannedGap(store: &store, volume: session.volume)
        if session.scanRoot == "/" || session.scanRoot == "/System/Volumes/Data" {
            CloneProbe.apply(store: &store, rootPath: session.scanRoot)
        }
        let model = AppModel()
        model.store = store
        model.stats = engine.statistics()
        model.phase = .map
        model.displayRoot = session.displayRoot
        model.homePrefix = NSHomeDirectory()
        model.drawsTrafficLights = true
        model.viewport = CGSize(width: 1000, height: 760)
        model.activeVolume = session.volume
        model.volumes = [session.volume]
        model.selectedVolumeID = session.volume.id
        model.rebuildPicture()
        return model
    }

    private static func largestDirectory(in model: AppModel) -> UInt32? {
        model.store.children(of: model.store.rootID)
            .filter { model.store.isDirectory($0) && !model.store.flags($0).contains(.hatched) }
            .max { model.store.bytes($0, .allocated) < model.store.bytes($1, .allocated) }
    }

    private static func render(model: AppModel, scheme: ColorScheme, to path: String) {
        NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let view = RootView(model: model)
            .frame(width: 1440, height: 900)
            .environment(\.colorScheme, scheme)
        if !write(view, to: URL(fileURLWithPath: path)) {
            FileHandle.standardError.write(Data("failed to render \(path)\n".utf8))
            exit(1)
        }
    }

    private static func write<V: View>(_ view: V, to url: URL) -> Bool {
        autoreleasepool {
            let host = NSHostingView(rootView: view)
            let points = NSRect(x: 0, y: 0, width: 1440, height: 900)
            host.frame = points
            host.wantsLayer = true
            // Borderless, so the window does not draw a second set of traffic lights.
            let window = NSWindow(contentRect: points, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.displayIfNeeded()
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()
            for _ in 0..<4 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                host.layoutSubtreeIfNeeded()
            }
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 2880,
                pixelsHigh: 1800,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return false }
            rep.size = NSSize(width: 1440, height: 900)
            host.cacheDisplay(in: points, to: rep)
            // One release only. close() would free the window, and the pool would free it again.
            window.isReleasedWhenClosed = false
            window.contentView = nil
            window.orderOut(nil)
            guard let data = rep.representation(using: .png, properties: [:]) else { return false }
            do {
                try data.write(to: url)
                return FileManager.default.fileExists(atPath: url.path)
            } catch {
                return false
            }
        }
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
