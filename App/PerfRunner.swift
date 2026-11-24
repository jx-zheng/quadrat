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
        let session = VolumeMode.prepare(path: directory)
        let process = PeakSampler()
        process.start(relieve: false)
        var bestJSON: [String: Any] = [:]
        var bestRate = -1.0
        var store = NodeStore()
        for _ in 0..<3 {
            let phase = scan(path: session.scanRoot, displayName: session.volume.name)
            let rate = phase.json["itemsPerSecond"] as? Double ?? 0
            if rate >= bestRate {
                bestRate = rate
                bestJSON = phase.json
                store = phase.store
            }
            ResidentMemory.relieve()
        }
        VolumeMode.addUnscannedGap(store: &store, volume: session.volume)
        var scanJSON = bestJSON
        scanJSON["passes"] = 3
        scanJSON["path"] = session.scanRoot
        let frames = RenderBench.measureInteraction(store: store, width: 1440, height: 900, scale: 2)
        let peak = process.stop()
        let heldFootprint = Int(peak.footprint)
        let heldResident = Int(peak.resident)
        scanJSON["peakRSSBytes"] = heldFootprint
        scanJSON["peakResidentBytes"] = heldResident
        let report: [String: Any] = [
            "scan": scanJSON,
            "peakRSSBytes": heldFootprint,
            "peakResidentBytes": heldResident,
            "hoverP99Ms": frames.hoverP99Ms,
            "hoverSamples": frames.hoverSamples,
            "zoomP99Ms": frames.zoomP99Ms,
            "zoomSamples": frames.zoomSamples,
            "layoutMs": frames.layoutMs,
            "backingScale": frames.backingScale,
            "hoverDrawCount": frames.hoverDrawCount,
            "windowPoints": "1440x900"
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
        if path == "/" || path == "/System/Volumes/Data" {
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
        var backingScale: Double = 2
        var hoverDrawCount: Int = 0
    }

    static func measure(store: NodeStore) -> Result {
        measureInteraction(store: store, hoverSamples: 40, zoomSamples: 20, width: 1200, height: 740, scale: 2)
    }

    /// Real mouse-moved events on a 2x layer-backed view. Hover must not redraw the tile bitmap.
    static func measureInteraction(
        store: NodeStore,
        hoverSamples: Int = 525,
        zoomSamples: Int = 40,
        width: Double = 1440,
        height: Double = 900,
        scale: CGFloat = 2
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
        let view = TreemapMapView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.backingScale = scale
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        autoreleasepool {
            view.show(picture: model, scheme: .light)
        }
        CATransaction.flush()
        view.drawRects.removeAll()

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
            let windowPoint = view.convert(NSPoint(x: point.x, y: point.y), to: nil)
            guard let event = NSEvent.mouseEvent(
                with: .mouseMoved,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: sample,
                clickCount: 0,
                pressure: 0
            ) else { continue }
            let start = CACurrentMediaTime()
            view.mouseMoved(with: event)
            hoverTimes.append((CACurrentMediaTime() - start) * 1000)
        }
        let hoverDrawCount = view.drawRects.count

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
            view.show(picture: picture, scheme: .light)
            CATransaction.flush()
            zoomTimes.append((CACurrentMediaTime() - started) * 1000)
        }
        window.orderOut(nil)
        return Result(
            hoverP99Ms: percentile(hoverTimes, 0.99),
            zoomP99Ms: percentile(zoomTimes, 0.99),
            hoverSamples: hoverTimes.count,
            zoomSamples: zoomTimes.count,
            layoutMs: layoutMs,
            backingScale: Double(view.resolvedScale),
            hoverDrawCount: hoverDrawCount
        )
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((Double(sorted.count - 1) * p).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank))]
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
