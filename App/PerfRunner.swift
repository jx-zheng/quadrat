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

        let directoryScan = scan(path: directory, displayName: URL(fileURLWithPath: directory).lastPathComponent)
        report["directoryScan"] = directoryScan.json
        var benchStore: NodeStore? = directoryScan.store

        if let store = benchStore, store.rootID != 0 {
            let frames = RenderBench.measure(store: store)
            report["frames"] = [
                "hoverP99Ms": frames.hoverP99Ms,
                "zoomP99Ms": frames.zoomP99Ms,
                "hoverSamples": frames.hoverSamples,
                "zoomSamples": frames.zoomSamples,
                "method": "NSView.display + CATransaction.flush"
            ]
        }
        benchStore = nil
        ResidentMemory.relieve()

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

    private struct Phase {
        var json: [String: Any]
        var store: NodeStore
    }

    private static func scanSynthetic() -> Phase {
        let listing = SyntheticListing(rootPath: "/synth", directories: 5_000, filesPerDirectory: 300)
        let engine = ScanEngine()
        let sampler = PeakSampler()
        sampler.start()
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
            "peakRSSBytes": Int(peak),
            "rssAfterBytes": Int(ResidentMemory.currentBytes()),
            "payloadBytes": store.estimatedPayloadBytes,
            "hardLinks": engine.hardLinkCount,
            "inaccessible": stats.inaccessible
        ], store: store)
    }

    private static func scan(path: String, displayName: String) -> Phase {
        let engine = ScanEngine(workerCount: 2)
        let sampler = PeakSampler()
        sampler.start()
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
            "peakRSSBytes": Int(peak),
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
    }

    static func measure(store: NodeStore) -> Result {
        let hoverSamples = 40
        let zoomSamples = 20
        var model = MapPicture.make(
            store: store,
            root: store.rootID,
            width: 1200,
            height: 740,
            metric: .allocated,
            scanned: nil,
            volumeUsed: nil,
            zoomed: false
        )
        let view = TreemapRenderView(frame: NSRect(x: 0, y: 0, width: 1200, height: 740))
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

        var hoverTimes: [Double] = []
        hoverTimes.reserveCapacity(hoverSamples)
        let hoverTargets = model.tiles.filter { $0.depth == 1 }
        for sample in 0..<hoverSamples {
            if hoverTargets.isEmpty {
                view.hover = nil
            } else {
                let tile = hoverTargets[sample % hoverTargets.count]
                view.hover = CGRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height)
            }
            let start = CACurrentMediaTime()
            view.needsDisplay = true
            view.display()
            CATransaction.flush()
            hoverTimes.append((CACurrentMediaTime() - start) * 1000)
        }

        let children = store.children(of: store.rootID)
        var zoomTimes: [Double] = []
        zoomTimes.reserveCapacity(zoomSamples)
        for sample in 0..<zoomSamples {
            let target = children.isEmpty ? store.rootID : children[sample % children.count]
            let started = CACurrentMediaTime()
            let picture = MapPicture.make(
                store: store,
                root: target,
                width: 1200,
                height: 740,
                metric: sample.isMultiple(of: 2) ? .allocated : .logical,
                scanned: nil,
                volumeUsed: nil,
                zoomed: true
            )
            view.tiles = picture.tiles
            view.hover = picture.tiles.first.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            view.needsDisplay = true
            view.display()
            CATransaction.flush()
            zoomTimes.append((CACurrentMediaTime() - started) * 1000)
        }
        _ = model
        return Result(
            hoverP99Ms: percentile(hoverTimes, 0.99),
            zoomP99Ms: percentile(zoomTimes, 0.99),
            hoverSamples: hoverTimes.count,
            zoomSamples: zoomTimes.count
        )
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((Double(sorted.count - 1) * p).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank))]
    }
}

/// Draws the treemap tiles itself so a hover or zoom frame is real AppKit/Core Animation work.
private final class TreemapRenderView: NSView {
    var tiles: [TileDraw] = []
    var hover: CGRect?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        dirtyRect.fill()
        for tile in tiles {
            let rect = NSRect(x: tile.x, y: tile.y, width: max(tile.width, 0), height: max(tile.height, 0))
            guard rect.intersects(dirtyRect) else { continue }
            NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.9, alpha: 1).setFill()
            rect.fill()
        }
        if let hover {
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: hover)
            path.lineWidth = 2
            path.stroke()
        }
    }
}

private final class PeakSampler {
    private let condition = NSCondition()
    private var running = false
    private var finished = false
    private var peak: UInt64 = 0

    func start() {
        running = true
        finished = false
        peak = ResidentMemory.currentBytes()
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            while self.running {
                // The scan's buffers are not all in the default zone. Purge every zone
                // so a sample is not a cache of freed Swift allocations.
                ResidentMemory.relieve()
                let sample = ResidentMemory.currentBytes()
                if sample > self.peak { self.peak = sample }
                Thread.sleep(forTimeInterval: 0.05)
            }
            self.condition.lock()
            self.finished = true
            self.condition.signal()
            self.condition.unlock()
        }
    }

    func stop() -> UInt64 {
        running = false
        condition.lock()
        while !finished { condition.wait() }
        condition.unlock()
        return max(peak, ResidentMemory.currentBytes())
    }
}
