import Foundation

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
        guard whole > 0 else { return "0%" }
        let p = Double(part) / Double(whole) * 100
        return String(format: "%.1f%%", p)
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
