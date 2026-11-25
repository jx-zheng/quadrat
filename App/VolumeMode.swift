import Foundation
import QuadratCore

/// One path for the running app, `--snapshot-path`, and `--perf-path`.
/// A volume root uses the volume's real capacity and free space. `/` is the
/// startup volume: the scan walks `/System/Volumes/Data` when that firmlink
/// target exists, so the sealed system is not walked twice and is not missed
/// from the used-space total. The gap is a single "System & Other" tile.
enum VolumeMode {
    struct Session {
        var volume: DiskVolume
        var scanRoot: String
        var displayRoot: String
    }

    static func prepare(path: String) -> Session {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let catalog = VolumeCatalog.current()
        let dataRoot = "/System/Volumes/Data"
        let startup = catalog.first { $0.isStartup }
        if standardized == "/" || standardized == dataRoot, let startup {
            let scanRoot = FileManager.default.fileExists(atPath: dataRoot) ? dataRoot : "/"
            return Session(volume: startup, scanRoot: scanRoot, displayRoot: "/")
        }
        if let match = catalog.first(where: { $0.id == standardized }) {
            return Session(volume: match, scanRoot: match.scanRoot, displayRoot: match.id)
        }
        let container = containingVolume(of: standardized, catalog: catalog)
        let name = URL(fileURLWithPath: standardized).lastPathComponent
        let folder = DiskVolume(
            id: standardized,
            name: name.isEmpty ? standardized : name,
            detail: container.map { "On \($0.name)" } ?? "Folder",
            symbol: "folder",
            capacity: container?.capacity ?? 0,
            available: container?.available ?? 0,
            purgeable: container?.purgeable ?? 0,
            isNetwork: container?.isNetwork ?? false,
            isStartup: false,
            isRemovable: container?.isRemovable ?? false,
            lastScanned: nil,
            snapshotCount: 0
        )
        return Session(volume: folder, scanRoot: standardized, displayRoot: standardized)
    }

    /// Adds the unscanned gap so a volume map sums to used space. A folder keeps the
    /// disk's capacity for percentages, but does not invent a System & Other tile.
    static func addUnscannedGap(store: inout NodeStore, volume: DiskVolume) {
        guard !volume.detail.hasPrefix("On "), volume.capacity > 0, store.rootID != 0 else { return }
        let scanned = store.bytes(store.rootID, .allocated)
        let used = volume.used
        guard used > scanned + (1 << 20) else { return }
        _ = store.addNode(
            parent: store.rootID,
            name: "System & Other",
            allocBytes: used - scanned,
            logicalBytes: used - scanned,
            kind: .system,
            flags: [.hatched]
        )
        store.rollup(store.rootID)
    }

    private static func containingVolume(of path: String, catalog: [DiskVolume]) -> DiskVolume? {
        let url = URL(fileURLWithPath: path)
        if let volumePath = try? url.resourceValues(forKeys: [.volumeURLKey]).volume?.path,
           let match = catalog.first(where: { $0.id == volumePath }) {
            return match
        }
        return catalog
            .filter { item in
                item.id == "/" ? path.hasPrefix("/") : path == item.id || path.hasPrefix(item.id + "/")
            }
            .max { $0.id.count < $1.id.count }
    }
}
