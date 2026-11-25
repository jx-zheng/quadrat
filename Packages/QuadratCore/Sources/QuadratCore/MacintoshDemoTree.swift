import Foundation

/// The made-up Macintosh HD tree used by the screen-4 snapshot and the named-tile count test.
public enum MacintoshDemoTree {
    public static let used: UInt64 = 866_000_000_000

    public struct Result {
        public var store: NodeStore
        public var developer: UInt32
        public var devices: UInt32
        public var derived: UInt32
        public var docker: UInt32
        public var checkout: UInt32
    }

    public static func build() -> Result {
        var store = NodeStore()
        func dir(_ parent: UInt32, _ name: String, _ kind: ContentKind) -> UInt32 {
            store.addNode(parent: parent, name: name, allocBytes: 0, logicalBytes: 0, kind: kind, flags: .directory)
        }
        func file(_ parent: UInt32, _ name: String, _ gigabytes: Double, _ kind: ContentKind, logicalGB: Double? = nil, flags: NodeFlags = []) -> UInt32 {
            let alloc = UInt64(gigabytes * 1_000_000_000)
            let logical = UInt64((logicalGB ?? gigabytes) * 1_000_000_000)
            return store.addNode(parent: parent, name: name, allocBytes: alloc, logicalBytes: logical, kind: kind, flags: flags)
        }

        let root = store.addRoot(name: "Macintosh HD", kind: .developer)
        let users = dir(root, "Users", .developer)
        let you = dir(users, "you", .developer)
        let library = dir(you, "Library", .developer)

        let developer = dir(library, "Developer", .developer)
        let xcode = dir(developer, "Xcode", .developer)
        let derived = dir(xcode, "DerivedData", .builds)
        file(derived, "Atlas-gyeunrzcfqpoti", 14.6, .builds)
        file(derived, "Satchel-bxqzfhkwnrlpe", 9.8, .builds)
        file(derived, "Orbit-hfjzaewtrnlqcm", 8.4, .builds)
        file(derived, "Ledger-dkvhqmspyxwqcf", 11.2, .builds)
        file(derived, "ModuleCache.noindex", 7.7, .builds)
        file(derived, "Pocket-aabxqyvtrwnmke", 6.9, .builds)
        file(derived, "Breeze-cmwqoplh", 5.6, .builds)

        let support = dir(xcode, "iOS DeviceSupport", .builds)
        file(support, "iPhone16.2 18.1 (22B83)", 6.4, .builds)
        file(support, "iPhone16.2 18.0 (22A3354)", 6.2, .builds)
        file(support, "iPhone15.3 17.6.1 (21G93)", 8.7, .builds)
        file(support, "Archives", 6.1, .builds)

        let sim = dir(developer, "CoreSimulator", .developer)
        let devices = dir(sim, "Devices", .developer)
        file(devices, "iPhone 16 Pro — iOS 18.1", 12.4, .developer)
        file(devices, "iPhone 16 — iOS 18.1", 9.1, .developer)
        file(devices, "iPad Pro 13\" — iOS 18.1", 8.7, .developer)
        file(devices, "Apple Watch Ultra", 4.2, .developer)
        file(devices, "iPhone 15 — iOS 17.5", 7.3, .developer)
        file(devices, "Apple TV 4K", 3.1, .developer)
        file(sim, "Caches", 3.9, .caches)

        let containers = dir(library, "Containers", .developer)
        let dockerApp = dir(containers, "com.docker.docker", .vms)
        let data = dir(dockerApp, "Data", .vms)
        let vms = dir(data, "vms", .vms)
        let zero = dir(vms, "0", .vms)
        let vmData = dir(zero, "data", .vms)
        let docker = file(vmData, "Docker.raw", 58.0, .vms, logicalGB: 128)

        file(library, "Messages", 9.8, .caches)
        file(library, "Caches", 6.3, .caches)
        file(library, "Mail", 12.0, .other)
        file(library, "Application Support", 8.4, .other)
        file(library, "Group Containers", 9.6, .other)
        file(library, "Fonts", 8.1, .other)

        let pictures = dir(you, "Pictures", .photos)
        file(pictures, "originals", 129, .photos)
        file(pictures, "exports", 24.0, .photos)
        let movies = dir(you, "Movies", .media)
        file(movies, "Final Cut Library.fcpbundle", 61, .media)
        file(movies, "Screen Recordings", 21.4, .media)
        file(you, "Documents", 28.4, .documents)
        let downloads = dir(you, "Downloads", .documents)
        file(downloads, "datasets", 9.7, .documents)
        file(downloads, "Other downloads", 25.0, .documents)
        let desktop = dir(you, "Desktop", .documents)
        file(desktop, "files", 22.0, .documents)
        file(you, "Music", 18.2, .media)
        let ollama = dir(you, ".ollama", .vms)
        file(ollama, "models", 26.1, .vms)
        let homeDev = dir(you, "Developer", .developer)
        file(homeDev, "resources", 11.8, .developer)
        file(homeDev, "node_modules", 12.0, .nodeModules)
        let checkout = dir(homeDev, "checkout", .developer)
        file(checkout, "src", 12.4, .developer)
        file(checkout, "build", 8.6, .developer)
        file(checkout, ".git", 6.1, .developer)
        file(checkout, "docs", 4.1, .developer)
        let trash = dir(you, ".Trash", .backups)
        file(trash, "items", 20.0, .backups)
        file(you, "Backup", 31.2, .backups)

        let apps = dir(root, "Applications", .apps)
        file(apps, "Xcode.app", 12.9, .apps)
        file(apps, "Final Cut Pro.app", 10.0, .apps)
        file(apps, "Logic Pro.app", 8.0, .apps)
        file(apps, "Other apps", 17.3, .apps)

        let sysLib = dir(root, "Library", .system)
        file(sysLib, "Developer", 21.6, .developer)
        file(sysLib, "Volumes (runtimes)", 21.6, .developer)
        file(sysLib, "Application Support", 4.2, .other)

        let priv = dir(root, "private", .system)
        let varr = dir(priv, "var", .system)
        file(varr, "vm", 8.0, .system)
        file(varr, "folders", 6.9, .system)
        file(root, "homebrew", 18.0, .developer)
        let system = file(root, "System & Other", 28.7, .system, flags: .hatched)

        store.recomputeAll()
        let have = store.bytes(root, .allocated)
        if have < used {
            let current = store.bytes(system, .allocated)
            store.setAllocatedBytes(system, current + (used - have))
            store.recomputeAll()
        }
        store.setItemCount(devices, 291_200)
        store.setItemCount(derived, 417_300)
        store.setItemCount(root, 2_910_027)
        return Result(store: store, developer: developer, devices: devices, derived: derived, docker: docker, checkout: checkout)
    }

    /// Named tiles in a browsing layout of this tree, using the screen-4 map size.
    public static func namedTiles(width: Double = 1200, height: Double = 760) -> [TreemapNode] {
        let tree = build()
        let layout = TreemapLayout.build(
            store: tree.store, rootID: tree.store.rootID, width: width, height: height,
            options: .browsing(metric: .allocated, zoomed: false)
        )
        return layout.nodes.filter { $0.depth > 0 && $0.width > 1 && $0.height > 1 && $0.showsLabel && !$0.label.isEmpty }
    }
}
