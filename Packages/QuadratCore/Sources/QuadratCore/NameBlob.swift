import Foundation

/// Append-only UTF-8 names. A name that is ≤32 bytes and seen at least three times is interned.
public struct NameBlob: Equatable, Sendable {
    public private(set) var bytes: [UInt8] = []
    private var table: [String: Entry] = [:]

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
            let key = String(decoding: raw, as: UTF8.self)
            if let existing = table[key] {
                if existing.count >= 2 {
                    table[key]!.count = existing.count + 1
                    return (existing.offset, existing.length)
                }
                table[key]!.count = existing.count + 1
            } else {
                let offset = append(raw)
                table[key] = Entry(offset: offset, length: length, count: 1)
                return (offset, length)
            }
        }
        return (append(raw), length)
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
