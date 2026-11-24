import Foundation

public struct ListedEntry: Equatable, Sendable {
    public var name: String
    public var allocBytes: UInt64
    public var logicalBytes: UInt64
    public var linkCount: UInt32
    public var device: UInt64
    public var fileID: UInt64
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var isMountPoint: Bool
    public var mayShareBlocks: Bool
    public var privateBytes: UInt64
    public var inaccessible: Bool

    public init(
        name: String,
        allocBytes: UInt64 = 0,
        logicalBytes: UInt64 = 0,
        linkCount: UInt32 = 1,
        device: UInt64 = 0,
        fileID: UInt64 = 0,
        isDirectory: Bool = false,
        isSymlink: Bool = false,
        isMountPoint: Bool = false,
        mayShareBlocks: Bool = false,
        privateBytes: UInt64 = 0,
        inaccessible: Bool = false
    ) {
        self.name = name
        self.allocBytes = allocBytes
        self.logicalBytes = logicalBytes
        self.linkCount = linkCount
        self.device = device
        self.fileID = fileID
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isMountPoint = isMountPoint
        self.mayShareBlocks = mayShareBlocks
        self.privateBytes = privateBytes
        self.inaccessible = inaccessible
    }
}

public enum ListOutcome: Equatable, Sendable {
    case entries([ListedEntry])
    case inaccessible
    case unsupported
    case failed
}

public protocol DirectoryListing: AnyObject {
    func list(path: String, rootDevice: UInt64) -> ListOutcome
}

/// In-memory listing used by tests and the synthetic perf tree.
public final class MapListing: DirectoryListing {
    public var map: [String: ListOutcome]

    public init(map: [String: ListOutcome] = [:]) {
        self.map = map
    }

    public func list(path: String, rootDevice: UInt64) -> ListOutcome {
        map[path] ?? .entries([])
    }
}

/// A generated tree of `directories` folders, each with `filesPerDirectory` files.
/// Paths are `<root>` and `<root>/d<index>`. No disk I/O.
public final class SyntheticListing: DirectoryListing {
    public let rootPath: String
    public let directories: Int
    public let filesPerDirectory: Int
    public var smallFileBytes: UInt64
    public var largeFileBytes: UInt64
    public var largeStride: Int

    public init(
        rootPath: String,
        directories: Int,
        filesPerDirectory: Int,
        smallFileBytes: UInt64 = 4096,
        largeFileBytes: UInt64 = 2 << 20,
        largeStride: Int = 40
    ) {
        self.rootPath = rootPath
        self.directories = directories
        self.filesPerDirectory = filesPerDirectory
        self.smallFileBytes = smallFileBytes
        self.largeFileBytes = largeFileBytes
        self.largeStride = max(1, largeStride)
    }

    public var fileCount: Int { directories * filesPerDirectory }

    public func list(path: String, rootDevice: UInt64) -> ListOutcome {
        if path == rootPath {
            var entries: [ListedEntry] = []
            entries.reserveCapacity(directories)
            for index in 0..<directories {
                entries.append(ListedEntry(
                    name: "d\(index)",
                    allocBytes: 4096,
                    logicalBytes: 4096,
                    linkCount: 1,
                    device: 1,
                    fileID: UInt64(index + 1),
                    isDirectory: true
                ))
            }
            return .entries(entries)
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return .entries([]) }
        let leaf = path.dropFirst(prefix.count)
        guard leaf.first == "d", let index = Int(leaf.dropFirst()), index >= 0, index < directories else {
            return .entries([])
        }
        var files: [ListedEntry] = []
        files.reserveCapacity(filesPerDirectory)
        let base = UInt64(index) * UInt64(filesPerDirectory) + UInt64(directories) + 1
        for file in 0..<filesPerDirectory {
            let large = largeStride > 0 && file % largeStride == 0
            let size = large ? largeFileBytes : smallFileBytes
            files.append(ListedEntry(
                name: "f\(file)",
                allocBytes: size,
                logicalBytes: size,
                linkCount: 1,
                device: 1,
                fileID: base + UInt64(file),
                isDirectory: false
            ))
        }
        return .entries(files)
    }
}

/// A macOS-shaped tree: about a million directories and about four million items,
/// with a `node_modules`, `.git`, and `Caches` under every project. No disk I/O.
public final class MacShapedListing: DirectoryListing {
    public let rootPath: String
    public let projects: Int
    public let packages: Int
    public let gitObjects: Int
    public let cacheFolders: Int

    public init(
        rootPath: String,
        projects: Int = 4096,
        packages: Int = 200,
        gitObjects: Int = 40,
        cacheFolders: Int = 8
    ) {
        self.rootPath = rootPath
        self.projects = projects
        self.packages = packages
        self.gitObjects = gitObjects
        self.cacheFolders = cacheFolders
    }

    /// Root plus every project directory, container, package, git object, and cache folder.
    public var directoryCount: Int {
        1 + projects * (1 + 4 + packages + gitObjects + cacheFolders)
    }

    public var fileCount: Int {
        projects * (packages * 3 + gitObjects * 2 + cacheFolders * 4 + 3)
    }

    public func list(path: String, rootDevice: UInt64) -> ListOutcome {
        if path == rootPath {
            var entries: [ListedEntry] = []
            entries.reserveCapacity(projects)
            for index in 0..<projects {
                entries.append(directory("a\(index)", id: fileID(index, 0, 0)))
            }
            return .entries(entries)
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return .entries([]) }
        let parts = path[path.index(path.startIndex, offsetBy: prefix.count)...].split(separator: "/")
        guard let head = parts.first, let app = suffixIndex(head, prefix: "a"), app >= 0, app < projects else {
            return .entries([])
        }
        if parts.count == 1 {
            return .entries([
                directory("node_modules", id: fileID(app, 1, 0)),
                directory(".git", id: fileID(app, 2, 0)),
                directory("Caches", id: fileID(app, 3, 0)),
                directory("src", id: fileID(app, 4, 0))
            ])
        }
        switch parts[1] {
        case "node_modules":
            if parts.count == 2 { return packageDirectories(app) }
            let package = parts.count > 2 ? suffixIndex(parts[2], prefix: "pkg") ?? 0 : 0
            return packageFiles(app, package)
        case ".git":
            if parts.count == 2 { return gitDirectories(app) }
            let object = parts.count > 2 ? suffixIndex(parts[2], prefix: "o") ?? 0 : 0
            return gitFiles(app, object)
        case "Caches":
            if parts.count == 2 { return cacheDirectories(app) }
            let folder = parts.count > 2 ? suffixIndex(parts[2], prefix: "c") ?? 0 : 0
            return cacheFiles(app, folder)
        case "src":
            return srcFiles(app)
        default:
            return .entries([])
        }
    }

    private func packageDirectories(_ app: Int) -> ListOutcome {
        var entries: [ListedEntry] = []
        entries.reserveCapacity(packages)
        for index in 0..<packages {
            entries.append(directory("pkg\(index)", id: fileID(app, 5, index)))
        }
        return .entries(entries)
    }

    private func packageFiles(_ app: Int, _ package: Int) -> ListOutcome {
        .entries((0..<3).map { file("f\($0)", id: fileID(app, 6, package * 8 + $0), bytes: 4096) })
    }

    private func gitDirectories(_ app: Int) -> ListOutcome {
        var entries: [ListedEntry] = []
        entries.reserveCapacity(gitObjects)
        for index in 0..<gitObjects {
            entries.append(directory("o\(index)", id: fileID(app, 7, index)))
        }
        return .entries(entries)
    }

    private func gitFiles(_ app: Int, _ object: Int) -> ListOutcome {
        .entries((0..<2).map { file("b\($0)", id: fileID(app, 8, object * 4 + $0), bytes: 4096) })
    }

    private func cacheDirectories(_ app: Int) -> ListOutcome {
        var entries: [ListedEntry] = []
        entries.reserveCapacity(cacheFolders)
        for index in 0..<cacheFolders {
            entries.append(directory("c\(index)", id: fileID(app, 9, index)))
        }
        return .entries(entries)
    }

    private func cacheFiles(_ app: Int, _ folder: Int) -> ListOutcome {
        .entries((0..<4).map { file("k\($0)", id: fileID(app, 10, folder * 8 + $0), bytes: 4096) })
    }

    private func srcFiles(_ app: Int) -> ListOutcome {
        .entries([
            file("a.txt", id: fileID(app, 11, 0), bytes: 4096),
            file("b.txt", id: fileID(app, 11, 1), bytes: 4096),
            file("bundle.bin", id: fileID(app, 11, 2), bytes: 2 << 20)
        ])
    }

    private func directory(_ name: String, id: UInt64) -> ListedEntry {
        ListedEntry(name: name, allocBytes: 4096, logicalBytes: 4096, device: 1, fileID: id, isDirectory: true)
    }

    private func file(_ name: String, id: UInt64, bytes: UInt64) -> ListedEntry {
        ListedEntry(name: name, allocBytes: bytes, logicalBytes: bytes, device: 1, fileID: id, isDirectory: false)
    }

    private func fileID(_ app: Int, _ kind: Int, _ n: Int) -> UInt64 {
        UInt64(app) * 20_000_000 + UInt64(kind) * 200_000 + UInt64(n) + 1
    }

    private func suffixIndex(_ part: Substring, prefix: String) -> Int? {
        guard part.hasPrefix(prefix) else { return nil }
        return Int(part.dropFirst(prefix.count))
    }
}
