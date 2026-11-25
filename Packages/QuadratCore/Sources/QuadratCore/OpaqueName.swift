import Foundation

/// Hash, UUID, and other machine-generated names. These never get their own labelled tile.
public enum OpaqueName {
    public static func isHashOrUUID(_ name: String) -> Bool {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return false }
        if looksLikeUUID(base) { return true }
        let compact = base.filter { $0.isHexDigit }
        if compact.count == base.count, compact.count >= 6 { return true }
        if compact.count == base.count, compact.count >= 2, compact.count <= 5,
           base == base.uppercased() || base == base.lowercased() {
            return true
        }
        if base.allSatisfy(\.isNumber), base.count >= 5 { return true }
        return false
    }

    private static func looksLikeUUID(_ name: String) -> Bool {
        let parts = name.split(separator: "-")
        let lengths = [8, 4, 4, 4, 12]
        guard parts.count == 5 else { return false }
        return zip(parts, lengths).allSatisfy { part, count in
            part.count == count && part.allSatisfy(\.isHexDigit)
        }
    }
}
