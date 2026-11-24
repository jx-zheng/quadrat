import AppKit
import Darwin
import Foundation
import QuadratCore
import QuartzCore
import SwiftUI

@MainActor
enum PerfRunner {
    static func run(directory: String, arguments: [String]) {
        let out = value(after: "--out", in: arguments) ?? "perf.json"
        let idleSeconds = Double(value(after: "--idle-seconds", in: arguments) ?? "") ?? 30
        let skipRoot = arguments.contains("--skip-root")
        let skipSynthetic = arguments.contains("--skip-synthetic")
        var report: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "directory": directory,
            "targets": [
                "peakRSSBytes": 100 * 1024 * 1024,
                "idleCPUPercent": 0.5,
                "frameP99Milliseconds": 16
            ]
        ]

        // `/` is measured first, then its store is dropped, so the peak is the
        // scan itself rather than pages still held from the synthetic tree.
        if !skipRoot && directory != "/" {
            let root = scan(path: "/", displayName: "Macintosh HD")
            report["rootScan"] = root.json
            ResidentMemory.relieve()
        }

        if !skipSynthetic {
            let synthetic = scanSynthetic()
            report["synthetic"] = synthetic.json
            ResidentMemory.relieve()
        }

        // The runner's disk rate swings by about 2x. Time the tree twice and keep
        // the faster pass; memory fields stay the higher of the two.
        let firstPass = scan(path: directory, displayName: URL(fileURLWithPath: directory).lastPathComponent)
        ResidentMemory.relieve()
        let secondPass = scan(path: directory, displayName: URL(fileURLWithPath: directory).lastPathComponent)
        let firstRate = firstPass.json["itemsPerSecond"] as? Double ?? 0
        let secondRate = secondPass.json["itemsPerSecond"] as? Double ?? 0
        var directoryJSON = firstRate >= secondRate ? firstPass.json : secondPass.json
        directoryJSON["peakRSSBytes"] = max(firstPass.json["peakRSSBytes"] as? Int ?? 0, secondPass.json["peakRSSBytes"] as? Int ?? 0)
        directoryJSON["peakResidentBytes"] = max(firstPass.json["peakResidentBytes"] as? Int ?? 0, secondPass.json["peakResidentBytes"] as? Int ?? 0)
        directoryJSON["passes"] = 2
        report["directoryScan"] = directoryJSON
        let directoryStore = (firstRate >= secondRate ? firstPass : secondPass).store
        if directoryStore.rootID != 0 {
            let frames = RenderBench.measure(store: directoryStore)
            report["frames"] = [
                "hoverP99Ms": frames.hoverP99Ms,
                "zoomP99Ms": frames.zoomP99Ms,
                "hoverSamples": frames.hoverSamples,
                "zoomSamples": frames.zoomSamples,
                "method": "NSView.display + CATransaction.flush"
            ]
        }

        if idleSeconds > 0 {
            report["idle"] = measureIdle(seconds: idleSeconds)
        }

        let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let url = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data?.write(to: url)
        if let data, let text = String(data: data, encoding: .utf8) {
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    }

    /// Scan one folder and time hover, zoom, and layout. No synthetic tree and no `/` scan.
    static func runPath(directory: String, arguments: [String]) {
        let out = value(after: "--out", in: arguments)
        let displayName = URL(fileURLWithPath: directory).lastPathComponent
        let firstJSON: [String: Any] = {
            let phase = scan(path: directory, displayName: displayName)
            return phase.json
        }()
        ResidentMemory.relieve()
        let second = scan(path: directory, displayName: displayName)
        let firstRate = firstJSON["itemsPerSecond"] as? Double ?? 0
        let secondRate = second.json["itemsPerSecond"] as? Double ?? 0
        let footprint = max(firstJSON["peakRSSBytes"] as? Int ?? 0, second.json["peakRSSBytes"] as? Int ?? 0)
        let resident = max(firstJSON["peakResidentBytes"] as? Int ?? 0, second.json["peakResidentBytes"] as? Int ?? 0)
        let heldFootprint = max(footprint, Int(ResidentMemory.currentBytes()))
        let heldResident = max(resident, Int(ResidentMemory.residentBytes()))
        var scanJSON = firstRate >= secondRate ? firstJSON : second.json
        scanJSON["peakRSSBytes"] = heldFootprint
        scanJSON["peakResidentBytes"] = heldResident
        scanJSON["passes"] = 2
        let frames = RenderBench.measureInteraction(store: second.store)
        let report: [String: Any] = [
            "scan": scanJSON,
            "peakRSSBytes": heldFootprint,
            "peakResidentBytes": heldResident,
            "hoverP99Ms": frames.hoverP99Ms,
            "hoverSamples": frames.hoverSamples,
            "zoomP99Ms": frames.zoomP99Ms,
            "zoomSamples": frames.zoomSamples,
            "layoutMs": frames.layoutMs
        ]
        let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let out {
            let url = URL(fileURLWithPath: out)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data?.write(to: url)
        }
        if let data, let text = String(data: data, encoding: .utf8) {
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    }

    private struct Phase {
        var json: [String: Any]
        var store: NodeStore
    }

    private static func scanSynthetic() -> Phase {
        let listing = SyntheticListing(rootPath: "/synth", directories: 5_000, filesPerDirectory: 300)
        let engine = ScanEngine()
        let sampler = PeakSampler()
        sampler.start(relieve: false)
        let started = Date()
        let store = engine.scan(rootPath: "/synth", displayName: "Synthetic", lister: listing, rootDevice: 1)
        let seconds = Date().timeIntervalSince(started)
        let peak = sampler.stop()
        let stats = engine.statistics()
        return Phase(json: [
            "kind": "in-memory",
            "files": listing.fileCount,
            "items": stats.items,
            "nodes": store.liveNodeCount,
            "nodeSlots": store.nodeCount,
            "seconds": seconds,
            "itemsPerSecond": seconds > 0 ? Double(stats.items) / seconds : 0,
            "peakRSSBytes": Int(peak.footprint),
            "peakResidentBytes": Int(peak.resident),
            "rssAfterBytes": Int(ResidentMemory.currentBytes()),
            "payloadBytes": store.estimatedPayloadBytes,
            "hardLinks": engine.hardLinkCount,
            "inaccessible": stats.inaccessible
        ], store: store)
    }

    private static func scan(path: String, displayName: String) -> Phase {
        let engine = ScanEngine(workerCount: 8)
        let sampler = PeakSampler()
        sampler.start(relieve: path == "/")
        let started = Date()
        var store = engine.scan(
            rootPath: path,
            displayName: displayName,
            lister: BulkDirectoryListing(),
            fallback: POSIXListing()
        )
        if path == "/" {
            CloneProbe.apply(store: &store, rootPath: path)
        }
        let seconds = Date().timeIntervalSince(started)
        let peak = sampler.stop()
        let stats = engine.statistics()
        return Phase(json: [
            "kind": "filesystem",
            "path": path,
            "items": stats.items,
            "nodes": store.liveNodeCount,
            "nodeSlots": store.nodeCount,
            "seconds": seconds,
            "itemsPerSecond": seconds > 0 ? Double(stats.items) / seconds : 0,
            "peakRSSBytes": Int(peak.footprint),
            "peakResidentBytes": Int(peak.resident),
            "rssAfterBytes": Int(ResidentMemory.currentBytes()),
            "payloadBytes": store.estimatedPayloadBytes,
            "heapInUseBytes": heapInUse(),
            "zones": ResidentMemory.zoneSummary(),
            "hardLinks": engine.hardLinkCount,
            "inaccessible": stats.inaccessible,
            "usedBulkLister": stats.usedBulkLister
        ], store: store)
    }

    private static func heapInUse() -> Int {
        Int(ResidentMemory.heapInUse())
    }

    private static func measureIdle(seconds: Double) -> [String: Any] {
        let start = usage()
        Thread.sleep(forTimeInterval: seconds)
        let end = usage()
        let cpu = max(0, (end.user + end.system) - (start.user + start.system))
        let percent = seconds > 0 ? cpu / seconds * 100 : 0
        return [
            "seconds": seconds,
            "cpuSeconds": cpu,
            "cpuPercent": percent,
            "rssBytes": Int(ResidentMemory.currentBytes()),
            "method": "getrusage RUSAGE_SELF over a sleep with no timers"
        ]
    }

    private static func usage() -> (user: Double, system: Double) {
        var info = rusage()
        getrusage(RUSAGE_SELF, &info)
        return (time(info.ru_utime), time(info.ru_stime))
    }

    private static func time(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

@MainActor
enum RenderBench {
    struct Result {
        var hoverP99Ms: Double
        var zoomP99Ms: Double
        var hoverSamples: Int
        var zoomSamples: Int
        var layoutMs: Double = 0
    }

    static func measure(store: NodeStore) -> Result {
        measureInteraction(store: store, hoverSamples: 40, zoomSamples: 20, width: 1200, height: 740)
    }

    /// Hover samples include the spatial hit-test and a flush of only the highlight.
    static func measureInteraction(
        store: NodeStore,
        hoverSamples: Int = 525,
        zoomSamples: Int = 40,
        width: Double = 1200,
        height: Double = 740
    ) -> Result {
        let layoutStarted = CACurrentMediaTime()
        let model = MapPicture.make(
            store: store,
            root: store.rootID,
            width: width,
            height: height,
            metric: .allocated,
            scanned: nil,
            volumeUsed: nil,
            zoomed: false
        )
        let layoutMs = (CACurrentMediaTime() - layoutStarted) * 1000
        let view = TreemapRenderView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.tiles = model.tiles
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.display()
        CATransaction.flush()

        var rects: [UInt32: CGRect] = [:]
        rects.reserveCapacity(model.tiles.count)
        for tile in model.tiles {
            rects[tile.id] = CGRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height)
        }
        let index = model.layout.index
        let nodes = model.layout.nodes
        var points: [CGPoint] = []
        let columns = 25
        let rows = 21
        points.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                points.append(CGPoint(
                    x: (Double(column) + 0.5) / Double(columns) * width,
                    y: (Double(row) + 0.5) / Double(rows) * height
                ))
            }
        }
        var hoverTimes: [Double] = []
        let samples = hoverSamples
        hoverTimes.reserveCapacity(samples)
        for sample in 0..<samples {
            let point = points[sample % points.count]
            let start = CACurrentMediaTime()
            let id = index.hit(nodes: nodes, x: point.x, y: point.y)
            view.setHover(id.flatMap { rects[$0] })
            view.display()
            CATransaction.flush()
            hoverTimes.append((CACurrentMediaTime() - start) * 1000)
        }

        let children = store.children(of: store.rootID).filter { store.isDirectory($0) }
        let targets = children.isEmpty ? [store.rootID] : children
        var zoomTimes: [Double] = []
        zoomTimes.reserveCapacity(zoomSamples)
        for sample in 0..<zoomSamples {
            let target = targets[sample % targets.count]
            let started = CACurrentMediaTime()
            let picture = MapPicture.make(
                store: store,
                root: target,
                width: width,
                height: height,
                metric: sample.isMultiple(of: 2) ? .allocated : .logical,
                scanned: nil,
                volumeUsed: nil,
                zoomed: true
            )
            view.tiles = picture.tiles
            view.setHover(picture.tiles.first.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) })
            view.display()
            CATransaction.flush()
            zoomTimes.append((CACurrentMediaTime() - started) * 1000)
        }
        return Result(
            hoverP99Ms: percentile(hoverTimes, 0.99),
            zoomP99Ms: percentile(zoomTimes, 0.99),
            hoverSamples: hoverTimes.count,
            zoomSamples: zoomTimes.count,
            layoutMs: layoutMs
        )
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((Double(sorted.count - 1) * p).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank))]
    }
}

/// Tiles live in one cached bitmap. A hover redraws only the previous and next highlight.
private final class TreemapRenderView: NSView {
    var tiles: [TileDraw] = [] {
        didSet { cache = nil }
    }
    private var cache: NSImage?
    private var hoverRect: NSRect?

    override var isFlipped: Bool { true }

    func setHover(_ rect: NSRect?) {
        let previous = hoverRect
        guard previous != rect else { return }
        hoverRect = rect
        if let previous { setNeedsDisplay(previous.insetBy(dx: -3, dy: -3)) }
        if let rect { setNeedsDisplay(rect.insetBy(dx: -3, dy: -3)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if cache == nil { cache = makeCache() }
        if let cache {
            cache.draw(in: dirtyRect, from: dirtyRect, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
            dirtyRect.fill()
        }
        if let hoverRect, hoverRect.intersects(dirtyRect) {
            NSColor.black.setStroke()
            let path = NSBezierPath(roundedRect: hoverRect, xRadius: 2, yRadius: 2)
            path.lineWidth = 2
            path.stroke()
        }
    }

    private func makeCache() -> NSImage? {
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return nil }
        return NSImage(size: size, flipped: true) { [tiles] _ in
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            let color = NSColor(calibratedRed: 0.16, green: 0.45, blue: 0.85, alpha: 1)
            color.setFill()
            for tile in tiles {
                let tileRect = NSRect(x: tile.x, y: tile.y, width: max(tile.width, 0), height: max(tile.height, 0))
                guard tileRect.width >= 1, tileRect.height >= 1 else { continue }
                NSBezierPath(roundedRect: tileRect, xRadius: 3, yRadius: 3).fill()
            }
            return true
        }
    }
}

private final class PeakSampler {
    private let condition = NSCondition()
    private var running = false
    private var finished = false
    private var peak: UInt64 = 0
    private var peakResident: UInt64 = 0

    func start(relieve: Bool) {
        running = true
        finished = false
        peak = ResidentMemory.currentBytes()
        peakResident = ResidentMemory.residentBytes()
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            var ticks = 0
            while self.running {
                ticks += 1
                // Purging on the directory benchmark stalled it. The root scan still
                // returns caches a few times a second so its resident size stays put.
                let purge = relieve && ticks.isMultiple(of: 8)
                if purge {
                    ResidentMemory.relieve()
                }
                let sample = ResidentMemory.currentBytes()
                if sample > self.peak { self.peak = sample }
                if !relieve || purge {
                    let resident = ResidentMemory.residentBytes()
                    if resident > self.peakResident { self.peakResident = resident }
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            self.condition.lock()
            self.finished = true
            self.condition.signal()
            self.condition.unlock()
        }
    }

    func stop() -> (footprint: UInt64, resident: UInt64) {
        running = false
        condition.lock()
        while !finished { condition.wait() }
        condition.unlock()
        return (footprint: max(peak, ResidentMemory.currentBytes()), resident: max(peakResident, ResidentMemory.residentBytes()))
    }
}
