import Darwin
import Foundation
import QuadratCore

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

        var benchStore: NodeStore?
        if !skipSynthetic {
            let synthetic = scanSynthetic()
            report["synthetic"] = synthetic.json
            benchStore = synthetic.store
        }

        let directoryScan = scan(path: directory, displayName: URL(fileURLWithPath: directory).lastPathComponent)
        report["directoryScan"] = directoryScan.json
        if benchStore == nil { benchStore = directoryScan.store }

        if !skipRoot && directory != "/" {
            let root = scan(path: "/", displayName: "Macintosh HD")
            report["rootScan"] = root.json
        }

        if let store = benchStore, store.rootID != 0 {
            let frames = LayoutBench.measure(store: store, hoverSamples: 300, zoomSamples: 30)
            report["frames"] = [
                "hoverP99Ms": frames.hoverP99Ms,
                "zoomP99Ms": frames.zoomP99Ms,
                "hoverSamples": frames.hoverSamples,
                "zoomSamples": frames.zoomSamples
            ]
        }
        benchStore = nil

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
            "nodes": store.nodeCount,
            "seconds": seconds,
            "itemsPerSecond": seconds > 0 ? Double(stats.items) / seconds : 0,
            "peakRSSBytes": Int(peak),
            "rssAfterBytes": Int(ResidentMemory.currentBytes()),
            "payloadBytes": store.estimatedPayloadBytes,
            "inaccessible": stats.inaccessible
        ], store: store)
    }

    private static func scan(path: String, displayName: String) -> Phase {
        let engine = ScanEngine()
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
            "nodes": store.nodeCount,
            "seconds": seconds,
            "itemsPerSecond": seconds > 0 ? Double(stats.items) / seconds : 0,
            "peakRSSBytes": Int(peak),
            "rssAfterBytes": Int(ResidentMemory.currentBytes()),
            "payloadBytes": store.estimatedPayloadBytes,
            "inaccessible": stats.inaccessible,
            "usedBulkLister": stats.usedBulkLister
        ], store: store)
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
