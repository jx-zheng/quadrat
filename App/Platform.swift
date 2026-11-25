import AppKit
import Darwin
import Foundation
import QuadratCore
import Quartz

struct DiskVolume: Identifiable, Equatable {
    var id: String
    var name: String
    var detail: String
    var symbol: String
    var capacity: UInt64
    var available: UInt64
    var purgeable: UInt64
    var isNetwork: Bool
    var isStartup: Bool
    var isRemovable: Bool
    var lastScanned: Date?
    var snapshotCount: Int

    /// Free space is this one figure. Used is capacity minus that same figure, so the
    /// title and the footer cannot round two different numbers into 99.6 and 99.5.
    var freeBytes: UInt64 { available }
    var used: UInt64 { capacity > freeBytes ? capacity - freeBytes : 0 }
    var free: UInt64 { freeBytes }
    var freeText: String { ByteFormat.bytes(freeBytes) }
    var usedText: String { ByteFormat.bytes(used) }
}

/// Title, sidebar, and footer all read these, so they cannot disagree.
enum VolumeChrome {
    static func used(_ volume: DiskVolume) -> String { volume.usedText }
    static func percent(_ volume: DiskVolume) -> String {
        ByteFormat.percent(volume.used, of: volume.capacity)
    }
    static func title(_ volume: DiskVolume) -> String {
        "\(used(volume)) used · \(percent(volume)) · \(volume.freeText) free"
    }
}

enum VolumeCatalog {
    static func current() -> [DiskVolume] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsLocalKey,
            .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsBrowsableKey,
            .volumeUUIDStringKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: []) ?? []
        var volumes: [DiskVolume] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.volumeIsBrowsable == false { continue }
            let path = url.path
            let name = values?.volumeName ?? url.lastPathComponent
            let capacity = UInt64(values?.volumeTotalCapacity ?? 0)
            let available = UInt64(values?.volumeAvailableCapacity ?? 0)
            let important = values?.volumeAvailableCapacityForImportantUsage.map { UInt64($0) } ?? available
            let purgeable = important > available ? important - available : 0
            let local = values?.volumeIsLocal ?? true
            let fstype = filesystemType(path)
            let network = !local || ["smbfs", "nfs", "afpfs", "webdav", "autofs"].contains(fstype)
            let removable = values?.volumeIsRemovable ?? false
            let startup = path == "/"
            let detail: String
            if network {
                detail = fstype == "smbfs" ? "SMB · network" : "Network"
            } else if removable {
                detail = "USB · \(fstype.uppercased())"
            } else if startup {
                detail = "Internal · \(fstype.isEmpty ? "APFS" : fstype.uppercased())"
            } else {
                detail = fstype.isEmpty ? "Volume" : fstype.uppercased()
            }
            let symbol = network ? "globe" : (removable ? "externaldrive" : "internaldrive")
            volumes.append(DiskVolume(
                id: path,
                name: name.isEmpty ? path : name,
                detail: detail,
                symbol: symbol,
                capacity: capacity,
                // Finder's free space includes purgeable space. Used is what's left.
                available: important,
                purgeable: purgeable,
                isNetwork: network,
                isStartup: startup,
                isRemovable: removable,
                lastScanned: LastScanStore.date(for: path),
                snapshotCount: startup ? snapshotCount(path) : 0
            ))
        }
        volumes.sort { lhs, rhs in
            if lhs.isStartup != rhs.isStartup { return lhs.isStartup }
            if lhs.isNetwork != rhs.isNetwork { return !lhs.isNetwork }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return volumes
    }

    private static func filesystemType(_ path: String) -> String {
        var buffer = statfs()
        guard statfs(path, &buffer) == 0 else { return "" }
        return withUnsafeBytes(of: buffer.f_fstypename) { raw in
            let bytes = raw.bindMemory(to: CChar.self)
            guard let base = bytes.baseAddress else { return "" }
            return String(cString: base)
        }
    }

    private static func snapshotCount(_ path: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return 0
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").filter { $0.contains("com.apple") }.count
    }
}

enum LastScanStore {
    private static let prefix = "lastScanned."

    static func date(for path: String) -> Date? {
        let value = UserDefaults.standard.double(forKey: prefix + path)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    static func record(_ path: String, at date: Date = Date()) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: prefix + path)
    }
}

enum FullDiskAccess {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static let probePath = "/Library/Application Support/com.apple.TCC/TCC.db"

    static func isGranted() -> Bool {
        let fd = open(probePath, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        return errno != EPERM && errno != EACCES
    }

    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}

enum TrashService {
    static func moveToTrash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}

enum RevealService {
    static func show(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

final class QuickLookBridge: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var url: URL?

    func toggle() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.dataSource = self
            panel.delegate = self
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL?
    }
}
