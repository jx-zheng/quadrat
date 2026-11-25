import Foundation

/// Append-only UTF-8 names. A name that is ≤32 bytes and seen at least three times is interned.
/// The intern table is capped so a scan of millions of unique filenames does not keep a String per name.
public struct NameBlob: Equatable, Sendable {
    public private(set) var bytes: [UInt8] = []
    private var table: [UInt64: Entry] = [:]
    private static let tableCap = 8192

    private struct Entry: Equatable {
        var offset: UInt32
        var length: UInt8
        var count: UInt32
    }

    public init() {}

    public var storedBytes: Int { bytes.count }

    public mutating func add(_ name: String) -> (offset: UInt32, length: UInt8) {
        let raw = Array(name.utf8.prefix(255))
        let length = UInt8(raw.count)
        if raw.count <= 32 {
            let hash = Self.fnv(raw)
            if let existing = table[hash], matches(existing, raw) {
                if existing.count >= 2 {
                    table[hash]!.count = existing.count &+ 1
                    return (existing.offset, existing.length)
                }
                table[hash]!.count = existing.count &+ 1
            } else if table[hash] == nil, table.count < Self.tableCap {
                let offset = append(raw)
                table[hash] = Entry(offset: offset, length: length, count: 1)
                return (offset, length)
            }
        }
        return (append(raw), length)
    }

    private func matches(_ entry: Entry, _ raw: [UInt8]) -> Bool {
        let start = Int(entry.offset)
        let end = start + Int(entry.length)
        guard end <= bytes.count, raw.count == Int(entry.length) else { return false }
        return bytes[start..<end].elementsEqual(raw)
    }

    private static func fnv(_ raw: [UInt8]) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in raw {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }

    public func string(offset: UInt32, length: UInt8) -> String {
        let start = Int(offset)
        let end = start + Int(length)
        guard start >= 0, end <= bytes.count, start <= end else { return "" }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private mutating func append(_ raw: [UInt8]) -> UInt32 {
        let offset = UInt32(bytes.count)
        bytes.append(contentsOf: raw)
        return offset
    }
}
