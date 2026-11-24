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
