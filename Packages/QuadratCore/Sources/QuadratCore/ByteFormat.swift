import Foundation

/// How a folder's size is shown against the disk that holds it.
public struct DiskShare: Equatable, Sendable {
    public var capacity: UInt64
    public var free: UInt64
    public var volumeName: String

    public init(capacity: UInt64, free: UInt64, volumeName: String) {
        self.capacity = capacity
        self.free = free
        self.volumeName = volumeName
    }

    /// 0...100. A missing capacity is 0%, never a divide-by-one blow-up.
    public static func percent(_ part: UInt64, of capacity: UInt64) -> Double {
        guard capacity > 0 else { return 0 }
        return min(100, Double(part) / Double(capacity) * 100)
    }

    public func percent(of bytes: UInt64) -> Double {
        Self.percent(bytes, of: capacity)
    }
}

/// One breadcrumb line. Firmlink prefixes and repeated names are collapsed.
public enum BreadcrumbLine {
    public static func segments(from parts: [String]) -> [String] {
        var out: [String] = []
        for part in parts {
            let cleaned = part
                .replacingOccurrences(of: "/System/Volumes/Data", with: "")
                .replacingOccurrences(of: "System/Volumes/Data/", with: "")
                .replacingOccurrences(of: "System/Volumes/Data", with: "")
            let pieces = cleaned.split { $0 == "/" || $0 == "\\" }.map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            let bits = pieces.isEmpty && !part.trimmingCharacters(in: .whitespaces).isEmpty
                ? [part.trimmingCharacters(in: .whitespaces)]
                : pieces
            for bit in bits {
                if out.last == bit { continue }
                out.append(bit)
            }
        }
        return out
    }

    public static func line(from parts: [String]) -> String {
        segments(from: parts).joined(separator: " / ")
    }
}

public enum ByteFormat {
    /// Finder-style decimal units (1 KB = 1,000 bytes).
    public static func bytes(_ value: UInt64) -> String {
        let tb = 1_000_000_000_000.0
        let gb = 1_000_000_000.0
        let mb = 1_000_000.0
        let kb = 1_000.0
        let v = Double(value)
        if v >= tb {
            return v >= 10 * tb ? String(format: "%.1f TB", v / tb) : String(format: "%.2f TB", v / tb)
        }
        if v >= gb {
            return v >= 100 * gb ? String(format: "%.0f GB", v / gb) : String(format: "%.1f GB", v / gb)
        }
        if v >= mb {
            return v >= 100 * mb ? String(format: "%.0f MB", v / mb) : String(format: "%.1f MB", v / mb)
        }
        if v >= kb {
            return v >= 100 * kb ? String(format: "%.0f KB", v / kb) : String(format: "%.1f KB", v / kb)
        }
        return "\(value) B"
    }

    public static func percent(_ part: UInt64, of whole: UInt64) -> String {
        String(format: "%.1f%%", DiskShare.percent(part, of: whole))
    }

    public static func grouped(_ value: UInt64) -> String {
        var n = value
        if n == 0 { return "0" }
        var digits: [String] = []
        while n > 0 {
            let chunk = n % 1000
            n /= 1000
            if n > 0 {
                digits.append(String(format: "%03d", chunk))
            } else {
                digits.append(String(chunk))
            }
        }
        return digits.reversed().joined(separator: ",")
    }

    public static func rate(_ itemsPerSecond: Double) -> String {
        guard itemsPerSecond.isFinite, itemsPerSecond > 0 else { return "0 items/s" }
        return grouped(UInt64(itemsPerSecond.rounded())) + " items/s"
    }
}
