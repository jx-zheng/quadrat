import Foundation
import QuadratCore

/// The made-up 1 TB disk from the approved treemap mockups.
enum DemoDisk {
    static let capacity: UInt64 = 995_000_000_000
    static let free: UInt64 = 129_000_000_000
    static let used: UInt64 = 866_000_000_000
    static let purgeable: UInt64 = 18_200_000_000
    static let snapshots: UInt64 = 6_500_000_000

    static func volumes() -> [DiskVolume] {
        let scanned = Date().addingTimeInterval(-86_400)
        return [
            DiskVolume(
                id: "/",
                name: "Macintosh HD",
                detail: "Internal · APFS",
                symbol: "internaldrive",
                capacity: capacity,
                available: free,
                purgeable: purgeable,
                isNetwork: false,
                isStartup: true,
                isRemovable: false,
                lastScanned: scanned,
                snapshotCount: 4
            ),
            DiskVolume(
                id: "/Volumes/Samsung T7",
                name: "Samsung T7",
                detail: "USB · APFS",
                symbol: "externaldrive",
                capacity: 1_000_000_000_000,
                available: 588_000_000_000,
                purgeable: 0,
                isNetwork: false,
                isStartup: false,
                isRemovable: true,
                lastScanned: nil,
                snapshotCount: 0
            ),
            DiskVolume(
                id: "/Volumes/Studio NAS",
                name: "Studio NAS",
                detail: "SMB · network",
                symbol: "globe",
                capacity: 8_000_000_000_000,
                available: 4_900_000_000_000,
                purgeable: 0,
                isNetwork: true,
                isStartup: false,
                isRemovable: false,
                lastScanned: nil,
                snapshotCount: 0
            )
        ]
    }

    static func mainStore() -> (store: NodeStore, developer: UInt32, devices: UInt32, derived: UInt32, docker: UInt32) {
        let tree = MacintoshDemoTree.build()
        return (tree.store, tree.developer, tree.devices, tree.derived, tree.docker)
    }

    static func scanningStore() -> NodeStore {
        let builder = Builder()
        let root = builder.root("Macintosh HD")
        let users = builder.dir(root, "Users", .developer)
        let you = builder.dir(users, "you", .developer)
        builder.file(you, "DerivedData", 39.0, .builds)
        builder.file(you, "iOS DeviceSupport", 15.4, .builds)
        builder.file(you, "Devices", 23.2, .developer)
        builder.file(you, "Archives", 6.1, .builds)
        builder.file(you, "Caches", 4.4, .caches)
        builder.file(you, "Docker.raw", 58.0, .vms, logicalGB: 128)
        builder.file(you, "Messages", 9.8, .caches)
        builder.file(you, "Other", 9.6, .other)
        builder.file(you, "Home", 5.0, .documents)
        builder.file(you, "Screen Recordings", 21.4, .media)
        builder.file(you, "Exports", 6.4, .photos)
        builder.file(you, "node_modules", 6.1, .nodeModules)
        builder.file(you, "node_modules", 4.8, .nodeModules)
        builder.file(you, "Documents", 28.4, .documents)
        builder.file(you, "resources", 11.8, .developer)
        builder.file(you, "Xcode.app", 3.6, .apps)
        builder.file(you, "ubuntu", 2.2, .other)
        builder.file(you, "Desktop", 4.6, .documents)
        builder.store.recomputeAll()
        return builder.store
    }

    private final class Builder {
        var store = NodeStore()

        func root(_ name: String) -> UInt32 {
            store.addRoot(name: name, kind: .developer)
        }

        @discardableResult
        func dir(_ parent: UInt32, _ name: String, _ kind: ContentKind) -> UInt32 {
            store.addNode(parent: parent, name: name, allocBytes: 0, logicalBytes: 0, kind: kind, flags: .directory)
        }

        @discardableResult
        func file(_ parent: UInt32, _ name: String, _ gigabytes: Double, _ kind: ContentKind, logicalGB: Double? = nil, flags extra: NodeFlags = []) -> UInt32 {
            let alloc = UInt64(gigabytes * 1_000_000_000)
            let logical = UInt64((logicalGB ?? gigabytes) * 1_000_000_000)
            return store.addNode(
                parent: parent,
                name: name,
                allocBytes: alloc,
                logicalBytes: logical,
                kind: kind,
                flags: extra
            )
        }
    }
}
