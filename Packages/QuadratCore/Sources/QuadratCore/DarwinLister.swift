import Foundation

#if os(macOS)
import Darwin

/// Parallel-friendly `getattrlistbulk` lister. One open directory fd per call; the caller
/// bounds how many calls run at once. Symlinks are not followed (`O_NOFOLLOW`, `FSOPT_NOFOLLOW`).
public final class BulkDirectoryListing: DirectoryListing, BulkListing {
    public init() {}

    public func list(path: String, rootDevice: UInt64) -> ListOutcome {
        let fd = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        if fd < 0 {
            if errno == EACCES || errno == EPERM { return .inaccessible }
            if errno == ELOOP || errno == ENOTDIR { return .failed }
            return .failed
        }
        defer { close(fd) }

        var attr = attrlist()
        memset(&attr, 0, MemoryLayout<attrlist>.size)
        attr.bitmapcount = u_short(truncatingIfNeeded: ATTR_BIT_MAP_COUNT)
        attr.commonattr = Self.group(ATTR_CMN_RETURNED_ATTRS)
            | Self.group(ATTR_CMN_NAME)
            | Self.group(ATTR_CMN_DEVID)
            | Self.group(ATTR_CMN_OBJTYPE)
            | Self.group(ATTR_CMN_FILEID)
            | Self.group(ATTR_CMN_FLAGS)
            | Self.group(ATTR_CMN_ERROR)
        attr.dirattr = Self.group(ATTR_DIR_MOUNTSTATUS)
        attr.fileattr = Self.group(ATTR_FILE_LINKCOUNT)
            | Self.group(ATTR_FILE_TOTALSIZE)
            | Self.group(ATTR_FILE_ALLOCSIZE)

        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        let options = UInt64(truncatingIfNeeded: FSOPT_NOFOLLOW) | UInt64(truncatingIfNeeded: FSOPT_PACK_INVAL_ATTRS)
        var entries: [ListedEntry] = []

        while true {
            let count: Int32 = buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                return getattrlistbulk(fd, &attr, base, raw.count, options)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == ENOTSUP || errno == ENOTTY { return .unsupported }
                if errno == EACCES || errno == EPERM { return .inaccessible }
                return .failed
            }
            if !Self.parse(buffer: buffer, count: Int(count), rootDevice: rootDevice, into: &entries) {
                return .unsupported
            }
        }
        if Self.looksCorrupt(entries) { return .unsupported }
        return .entries(entries)
    }

    /// Targeted probe for APFS clones. Failures are ignored; tiles keep allocated size.
    public static func cloneProbe(path: String) -> (shares: Bool, privateBytes: UInt64)? {
        var attr = attrlist()
        memset(&attr, 0, MemoryLayout<attrlist>.size)
        attr.bitmapcount = u_short(truncatingIfNeeded: ATTR_BIT_MAP_COUNT)
        attr.commonattr = Self.group(ATTR_CMNEXT_PRIVATESIZE) | Self.group(ATTR_CMNEXT_EXT_FLAGS)
        var buffer = [UInt8](repeating: 0, count: 64)
        let rc: Int32 = buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            return path.withCString { cPath in
                getattrlist(
                    cPath,
                    &attr,
                    base,
                    raw.count,
                    UInt32(truncatingIfNeeded: FSOPT_NOFOLLOW) | UInt32(truncatingIfNeeded: FSOPT_ATTR_CMN_EXTENDED)
                )
            }
        }
        if rc != 0 { return nil }
        // FSOPT_ATTR_CMN_EXTENDED: common bits are the extended group.
        // PRIVATESIZE (0x8) precedes EXT_FLAGS (0x200). Both are 4-byte aligned.
        guard buffer.count >= 16 else { return nil }
        let length = Self.readU32(buffer, 0)
        guard length >= 16 else { return nil }
        let privateSize = Self.readU64(buffer, 4)
        let extFlags = Self.readU32(buffer, 12)
        let shares = (extFlags & 0x80) != 0 // EF_MAY_SHARE_BLOCKS
        return (shares, privateSize)
    }

    private static func parse(buffer: [UInt8], count: Int, rootDevice: UInt64, into entries: inout [ListedEntry]) -> Bool {
        var cursor = 0
        for _ in 0..<count {
            if cursor + 4 > buffer.count { return false }
            let length = Int(readU32(buffer, cursor))
            if length < 4 || cursor + length > buffer.count { return false }
            let record = cursor
            var field = cursor + 4
            // ATTR_CMN_RETURNED_ATTRS is always first: attribute_set_t is 5 × UInt32.
            guard field + 20 <= record + length else { return false }
            field += 20
            guard field + 8 <= record + length else { return false }
            let nameRef = field
            let nameDelta = Int(readI32(buffer, field))
            let nameLength = Int(readU32(buffer, field + 4))
            field += 8
            let nameStart = nameRef + nameDelta
            let nameEnd = nameStart + nameLength
            let name: String
            if nameStart >= 0, nameEnd <= buffer.count, nameLength > 0 {
                let slice = buffer[nameStart..<nameEnd]
                let trimmed = slice[slice.startIndex..<slice.endIndex].prefix { $0 != 0 }
                name = String(decoding: trimmed, as: UTF8.self)
            } else {
                name = ""
            }
            func take32() -> UInt32 {
                let value = field + 4 <= buffer.count ? readU32(buffer, field) : 0
                field += 4
                return value
            }
            func take64() -> UInt64 {
                let value = field + 8 <= buffer.count ? readU64(buffer, field) : 0
                field += 8
                return value
            }
            let devid = take32()
            let objType = take32()
            _ = take32() // ATTR_CMN_FLAGS
            let fileID = take64()
            let error = take32()
            let mountStatus = take32()
            let linkCount = take32()
            let totalSize = take64()
            let allocSize = take64()

            if name != "." && name != ".." && !name.isEmpty {
                let isDir = objType == VDIR.rawValue
                let isLink = objType == VLNK.rawValue
                let device = UInt64(devid)
                let mountBit = UInt32(truncatingIfNeeded: DIR_MNTSTATUS_MNTPOINT)
                let mount = isDir && ((mountStatus & mountBit) != 0 || (rootDevice != 0 && device != rootDevice && devid != 0))
                let denied = error == UInt32(EACCES) || error == UInt32(EPERM)
                entries.append(ListedEntry(
                    name: name,
                    allocBytes: allocSize,
                    logicalBytes: totalSize,
                    linkCount: linkCount == 0 ? 1 : linkCount,
                    device: device,
                    fileID: fileID,
                    isDirectory: isDir,
                    isSymlink: isLink,
                    isMountPoint: mount,
                    inaccessible: denied
                ))
            }
            let aligned = (length + 7) & ~7
            cursor += max(aligned, 8)
        }
        return true
    }

    /// Darwin imports some `ATTR_*` constants as `Int32` and others as `UInt32`.
    private static func group<T: BinaryInteger>(_ value: T) -> attrgroup_t {
        attrgroup_t(truncatingIfNeeded: value)
    }

    private static func looksCorrupt(_ entries: [ListedEntry]) -> Bool {
        guard !entries.isEmpty else { return false }
        let blank = entries.reduce(0) { $0 + ($1.name.isEmpty ? 1 : 0) }
        if blank * 2 > entries.count { return true }
        let absurd = entries.contains { $0.logicalBytes > (1 << 50) || $0.allocBytes > (1 << 50) }
        return absurd
    }

    private static func readU32(_ buffer: [UInt8], _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        withUnsafeMutableBytes(of: &value) { dest in
            dest.copyBytes(from: buffer[offset..<(offset + 4)])
        }
        return value
    }

    private static func readI32(_ buffer: [UInt8], _ offset: Int) -> Int32 {
        Int32(bitPattern: readU32(buffer, offset))
    }

    private static func readU64(_ buffer: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        withUnsafeMutableBytes(of: &value) { dest in
            dest.copyBytes(from: buffer[offset..<(offset + 8)])
        }
        return value
    }
}

public enum CloneProbe {
    public static func apply(store: inout NodeStore, rootPath: String) {
        guard store.rootID != 0 else { return }
        func walk(_ id: UInt32, _ path: String) {
            let flags = store.flags(id)
            if flags.contains(.directory) {
                store.forEachChild(id) { child in
                    let childPath = path == "/" ? "/" + store.name(of: child) : path + "/" + store.name(of: child)
                    walk(child, childPath)
                }
                return
            }
            let size = store.bytes(id, .allocated)
            if size < (1 << 20) || flags.contains(.foldedAggregate) || flags.contains(.hardLinkDuplicate) {
                return
            }
            guard let probe = BulkDirectoryListing.cloneProbe(path: path), probe.shares else { return }
            store.insertFlags(.mayShareBlocks, on: id)
            store.privateBytes[id] = probe.privateBytes
        }
        walk(store.rootID, rootPath)
        store.recomputeAll()
    }
}
#else
public enum CloneProbe {
    public static func apply(store: inout NodeStore, rootPath: String) {}
}
#endif
