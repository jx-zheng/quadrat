import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum PathDevice {
    public static func device(of path: String) -> UInt64? {
        var info = stat()
        let rc = path.withCString { lstat($0, &info) }
        if rc != 0 { return nil }
        return UInt64(bitPattern: Int64(info.st_dev))
    }
}

/// `readdir` + `lstat`. Does not follow symlinks and treats a foreign `st_dev` as a mount point.
/// This is the Linux lister and the fallback when `getattrlistbulk` returns `ENOTSUP`.
public final class POSIXListing: DirectoryListing {
    public init() {}

    public func list(path: String, rootDevice: UInt64) -> ListOutcome {
        var entries: [ListedEntry] = []
        let outcome = enumerateStream(path: path, rootDevice: rootDevice) { entries.append($0.materialized()) }
        if case .entries = outcome { return .entries(entries) }
        return outcome
    }

    public func enumerate(path: String, rootDevice: UInt64, _ body: (ListedEntry) -> Void) -> ListOutcome {
        enumerateStream(path: path, rootDevice: rootDevice) { body($0.materialized()) }
    }

    public func enumerateStream(path: String, rootDevice: UInt64, _ body: (StreamedRecord) -> Void) -> ListOutcome {
        guard let dir = path.withCString({ opendir($0) }) else {
            if errno == EACCES || errno == EPERM { return .inaccessible }
            return .failed
        }
        defer { closedir(dir) }

        while true {
            errno = 0
            guard let ent = readdir(dir) else {
                if errno == 0 { break }
                return .failed
            }
            let nameBytes = Self.entryBytes(ent)
            if nameBytes.isEmpty || (nameBytes.count == 1 && nameBytes[0] == 46) || (nameBytes.count == 2 && nameBytes[0] == 46 && nameBytes[1] == 46) {
                continue
            }
            let name = String(decoding: nameBytes, as: UTF8.self)
            let child = path == "/" ? "/" + name : path + "/" + name
            var info = stat()
            let rc = child.withCString { lstat($0, &info) }
            if rc != 0 {
                let denied = errno == EACCES || errno == EPERM
                nameBytes.withUnsafeBufferPointer { buffer in
                    body(StreamedRecord(
                        name: buffer,
                        allocBytes: 0,
                        logicalBytes: 0,
                        linkCount: 1,
                        device: 0,
                        fileID: 0,
                        isDirectory: false,
                        isSymlink: false,
                        isMountPoint: false,
                        mayShareBlocks: false,
                        privateBytes: 0,
                        inaccessible: denied
                    ))
                }
                continue
            }
            let mode = info.st_mode
            let kind = mode & S_IFMT
            let isLink = kind == S_IFLNK
            let isDir = kind == S_IFDIR
            let device = UInt64(bitPattern: Int64(info.st_dev))
            let logical = UInt64(max(0, Int64(info.st_size)))
            let alloc = UInt64(max(0, info.st_blocks)) * 512
            let fileID = UInt64(info.st_ino)
            let links = UInt32(min(UInt64(info.st_nlink), UInt64(UInt32.max)))
            let mount = isDir && rootDevice != 0 && device != rootDevice
            nameBytes.withUnsafeBufferPointer { buffer in
                body(StreamedRecord(
                    name: buffer,
                    allocBytes: alloc,
                    logicalBytes: logical,
                    linkCount: links,
                    device: device,
                    fileID: fileID,
                    isDirectory: isDir,
                    isSymlink: isLink,
                    isMountPoint: mount,
                    mayShareBlocks: false,
                    privateBytes: 0,
                    inaccessible: false
                ))
            }
        }
        return .entries([])
    }

    private static func entryBytes(_ ent: UnsafeMutablePointer<dirent>) -> [UInt8] {
        withUnsafePointer(to: ent.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1024) { cString in
                let text = String(cString: cString)
                return Array(text.utf8)
            }
        }
    }
}
