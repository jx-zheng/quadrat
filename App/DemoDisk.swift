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
        let builder = Builder()
        let root = builder.root("Macintosh HD")
        let users = builder.dir(root, "Users", .developer)
        let you = builder.dir(users, "you", .developer)
        let library = builder.dir(you, "Library", .developer)

        let developer = builder.dir(library, "Developer", .developer)
        let xcode = builder.dir(developer, "Xcode", .developer)
        let derived = builder.dir(xcode, "DerivedData", .builds)
        builder.file(derived, "Atlas-gyeunrzcfqpoti", 14.6, .builds)
        builder.file(derived, "Satchel-bxqzfhkwnrlpe", 9.8, .builds)
        builder.file(derived, "Orbit-hfjzaewtrnlqcm", 8.4, .builds)
        builder.file(derived, "Ledger-dkvhqmspyxwqcf", 11.2, .builds)
        builder.file(derived, "ModuleCache.noindex", 7.7, .builds)
        builder.file(derived, "Pocket-aabxqyvtrwnmke", 6.9, .builds)
        builder.file(derived, "Breeze-cmwqoplh", 5.6, .builds)

        let support = builder.dir(xcode, "iOS DeviceSupport", .builds)
        builder.file(support, "iPhone16.2 18.1 (22B83)", 6.4, .builds)
        builder.file(support, "iPhone16.2 18.0 (22A3354)", 6.2, .builds)
        builder.file(support, "iPhone15.3 17.6.1 (21G93)", 8.7, .builds)
        builder.file(support, "Archives", 6.1, .builds)

        let sim = builder.dir(developer, "CoreSimulator", .developer)
        let devices = builder.dir(sim, "Devices", .developer)
        builder.file(devices, "iPhone 16 Pro — iOS 18.1", 12.4, .developer)
        builder.file(devices, "iPhone 16 — iOS 18.1", 9.1, .developer)
        builder.file(devices, "iPad Pro 13\" — iOS 18.1", 8.7, .developer)
        builder.file(devices, "Apple Watch Ultra", 4.2, .developer)
        builder.file(devices, "iPhone 15 — iOS 17.5", 7.3, .developer)
        builder.file(devices, "Apple TV 4K", 3.1, .developer)
        builder.file(sim, "Caches", 3.9, .caches)

        let containers = builder.dir(library, "Containers", .developer)
        let dockerApp = builder.dir(containers, "com.docker.docker", .vms)
        let data = builder.dir(dockerApp, "Data", .vms)
        let vms = builder.dir(data, "vms", .vms)
        let zero = builder.dir(vms, "0", .vms)
        let vmData = builder.dir(zero, "data", .vms)
        let docker = builder.file(vmData, "Docker.raw", 58.0, .vms, logicalGB: 128)

        builder.file(library, "Messages", 9.8, .caches)
        builder.file(library, "Caches", 6.3, .caches)
        builder.file(library, "Mail", 4.2, .other)
        builder.file(library, "Application Support", 8.4, .other)

        let pictures = builder.dir(you, "Pictures", .photos)
        builder.file(pictures, "originals", 129, .photos)
        builder.file(pictures, "exports", 13.9, .photos)
        let movies = builder.dir(you, "Movies", .media)
        builder.file(movies, "Final Cut Library.fcpbundle", 61, .media)
        builder.file(movies, "Screen Recordings", 21.4, .media)
        builder.file(you, "Documents", 28.4, .documents)
        let downloads = builder.dir(you, "Downloads", .documents)
        builder.file(downloads, "datasets", 9.7, .documents)
        builder.file(downloads, "Other downloads", 25.0, .documents)
        builder.file(you, "Desktop", 4.6, .documents)
        builder.file(you, "Music", 18.2, .media)
        let ollama = builder.dir(you, ".ollama", .vms)
        builder.file(ollama, "models", 26.1, .vms)
        let homeDev = builder.dir(you, "Developer", .developer)
        builder.file(homeDev, "resources", 11.8, .developer)
        builder.file(homeDev, "node_modules", 6.1, .nodeModules)
        builder.file(homeDev, "checkout", 31.2, .developer)
        builder.file(you, ".Trash", 6.2, .backups)
        builder.file(you, "Backup", 31.2, .backups)

        let apps = builder.dir(root, "Applications", .apps)
        builder.file(apps, "Xcode.app", 12.9, .apps)
        builder.file(apps, "Final Cut Pro.app", 6.1, .apps)
        builder.file(apps, "Logic Pro.app", 4.4, .apps)
        builder.file(apps, "Other apps", 24.8, .apps)

        let sysLib = builder.dir(root, "Library", .system)
        builder.file(sysLib, "Developer", 21.6, .developer)
        builder.file(sysLib, "Volumes (runtimes)", 21.6, .developer)
        builder.file(sysLib, "Application Support", 4.2, .other)

        let priv = builder.dir(root, "private", .system)
        let varr = builder.dir(priv, "var", .system)
        builder.file(varr, "vm", 8.0, .system)
        builder.file(varr, "folders", 6.9, .system)
        builder.file(root, "homebrew", 9.4, .developer)
        builder.file(root, "System & Other", 28.7, .system, flags: .hatched)

        builder.store.recomputeAll()
        builder.store.setItemCount(devices, 291_200)
        builder.store.setItemCount(derived, 417_300)
        builder.store.setItemCount(root, 2_910_027)
        return (builder.store, developer, devices, derived, docker)
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
