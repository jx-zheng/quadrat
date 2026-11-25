import Foundation

/// A tree shaped like a real macOS home folder: a large Library with Application
/// Support, Caches, and Developer/CoreSimulator, plus many hash and UUID directories.
/// Used by the wide-zoom fixture and by layout tests. It is much smaller than a
/// 425k-item disk so CI stays quick, but the width and depth are the same shape.
public enum HomeShapedTree {
    public static let libraryBytes: UInt64 = 38_000_000_000
    public static let homeBytes: UInt64 = 52_000_000_000

    public struct Result {
        public var store: NodeStore
        public var home: UInt32
        public var library: UInt32
        public var anki: UInt32
        public var user1: UInt32
        public var deviceVersion: UInt32
        public var homeDeveloper: UInt32
        public var libraryDeveloper: UInt32
        public var downloads: UInt32
    }

    public static func build(hashDirectories: Int = 3_000, cacheHashes: Int = 1_500, devices: Int = 80) -> Result {
        var store = NodeStore()
        @discardableResult func dir(_ parent: UInt32, _ name: String, _ kind: ContentKind = .other) -> UInt32 {
            store.addNode(parent: parent, name: name, allocBytes: 0, logicalBytes: 0, kind: kind, flags: .directory)
        }
        @discardableResult func file(_ parent: UInt32, _ name: String, _ bytes: UInt64, _ kind: ContentKind = .other) -> UInt32 {
            store.addNode(parent: parent, name: name, allocBytes: bytes, logicalBytes: bytes, kind: kind, flags: [])
        }

        let root = store.addRoot(name: "Macintosh HD", kind: .system)
        let users = dir(root, "Users", .developer)
        let home = dir(users, "you", .developer)
        let library = dir(home, "Library", .developer)

        let support = dir(library, "Application Support", .other)
        let anki = dir(support, "Anki2", .other)
        let user1 = dir(anki, "User 1", .other)
        file(user1, "collection.anki2", 655_000_000)
        file(support, "Google", 1_200_000_000)
        file(support, "discord", 800_000_000)
        let hashBytes: UInt64 = 16_000_000_000 / UInt64(max(1, hashDirectories))
        for index in 0..<hashDirectories {
            let name: String
            if index % 5 == 0 {
                name = String(format: "%08x-%04x-%04x-%04x-%012x", index, 0x4a00, 0x8f00, 0xb000, index)
            } else {
                name = String(format: "%012X", 0xFE8E1F000000 + index)
            }
            file(support, name, hashBytes)
        }

        let caches = dir(library, "Caches", .caches)
        let cacheBytes: UInt64 = 6_000_000_000 / UInt64(max(1, cacheHashes))
        file(caches, "com.apple.Safari", 400_000_000, .caches)
        for index in 0..<cacheHashes {
            file(caches, String(format: "%08X", 0x10078500 + index), cacheBytes, .caches)
        }

        let libraryDeveloper = dir(library, "Developer", .developer)
        let xcode = dir(libraryDeveloper, "Xcode", .developer)
        let supportDir = dir(xcode, "iOS DeviceSupport", .builds)
        let phone = dir(supportDir, "iPhone17,4", .builds)
        let deviceVersion = dir(phone, "26.6.1 (23G83)", .builds)
        file(deviceVersion, "Symbols", 2_400_000_000, .builds)
        let sim = dir(libraryDeveloper, "CoreSimulator", .developer)
        let deviceRoot = dir(sim, "Devices", .developer)
        let perDevice = 13_800_000_000 / 4 / UInt64(max(1, devices))
        for index in 0..<devices {
            let uuid = String(format: "%08x-11ee-4f00-9c00-%012x", 0x4F1C0000 + index, index)
            let device = dir(deviceRoot, uuid, .developer)
            file(device, "data", perDevice, .developer)
        }
        file(library, "Messages", 1_800_000_000, .caches)
        file(library, "Mail", 900_000_000)

        let pictures = dir(home, "Pictures", .photos)
        file(pictures, "Photos Library.photoslibrary", 4_000_000_000, .photos)
        file(home, "Documents", 2_800_000_000, .documents)
        let downloads = dir(home, "Downloads", .documents)
        file(downloads, "datasets", 1_100_000_000, .documents)
        file(home, "Desktop", 400_000_000, .documents)
        let movies = dir(home, "Movies", .media)
        file(movies, "Screen Recordings", 1_200_000_000, .media)
        let homeDeveloper = dir(home, "Developer", .developer)
        file(homeDeveloper, "checkout", 3_200_000_000, .developer)

        let apps = dir(root, "Applications", .apps)
        file(apps, "Xcode.app", 4_200_000_000, .apps)
        file(apps, "Microsoft Word.app", 3_000_000_000, .apps)
        file(apps, "Microsoft Outlook.app", 2_900_000_000, .apps)
        file(apps, "Microsoft Excel.app", 2_800_000_000, .apps)
        file(apps, "Final Cut Pro.app", 2_100_000_000, .apps)
        file(apps, "Logic Pro.app", 1_800_000_000, .apps)
        file(apps, "Safari.app", 700_000_000, .apps)

        let system = dir(root, "System", .system)
        let sysLib = dir(system, "Library", .system)
        let assets = dir(sysLib, "AssetsV2", .system)
        for index in 0..<400 {
            file(assets, String(format: "com_apple_%08x", index), 17_700_000_000 / 400, .system)
        }

        store.recomputeAll()
        return Result(
            store: store,
            home: home,
            library: library,
            anki: anki,
            user1: user1,
            deviceVersion: deviceVersion,
            homeDeveloper: homeDeveloper,
            libraryDeveloper: libraryDeveloper,
            downloads: downloads
        )
    }
}
