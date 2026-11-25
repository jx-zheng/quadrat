import Foundation

public enum Folding {
    public static let minimumKeepBytes: UInt64 = 1 << 20
    public static let largestKept = 32

    /// Near the root, keep the familiar 32. Deeper folders keep fewer siblings so a million tiny directories do not each retain a private top 32.
    public static func largestKept(depth: Int) -> Int {
        if depth <= 1 { return 32 }
        if depth <= 3 { return 8 }
        return 4
    }

    /// A fully scanned directory below 1 MiB, at depth 2 or more, becomes one leaf. Zooming re-lists it.
    public static func shouldCollapseSubtree(depth: Int, bytes: UInt64) -> Bool {
        depth >= 2 && bytes < minimumKeepBytes
    }

    public struct FileChoice {
        public var key: String
        public var bytes: UInt64
    }

    /// Keep a file when it is at least 1 MiB or among the directory's 32 largest.
    /// The rest fold into one aggregate. Ordering of equal sizes is by key, so the choice is stable.
    public static func partition(_ files: [FileChoice], keepCount: Int = largestKept) -> (keep: [String], fold: [String]) {
        let ranked = files.enumerated().sorted { lhs, rhs in
            if lhs.element.bytes != rhs.element.bytes { return lhs.element.bytes > rhs.element.bytes }
            if lhs.element.key != rhs.element.key { return lhs.element.key < rhs.element.key }
            return lhs.offset < rhs.offset
        }
        var keep: [String] = []
        var fold: [String] = []
        keep.reserveCapacity(min(files.count, largestKept))
        for (rank, entry) in ranked.enumerated() {
            if entry.element.bytes >= minimumKeepBytes || rank < keepCount {
                keep.append(entry.element.key)
            } else {
                fold.append(entry.element.key)
            }
        }
        return (keep, fold)
    }
}
