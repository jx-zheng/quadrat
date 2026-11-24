import Foundation

public struct LayoutBox: Equatable, Sendable {
    public var id: UInt32
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public var area: Double { max(0, width) * max(0, height) }
}

public enum Squarify {
    public struct Item: Equatable, Sendable {
        public var id: UInt32
        public var weight: Double
        public init(id: UInt32, weight: Double) {
            self.id = id
            self.weight = weight
        }
    }

    /// Deterministic squarified treemap. Equal weights keep ascending id order.
    /// `gap` insets every rect; area tests should pass 0.
    public static func layout(
        items: [Item],
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        gap: Double = 0
    ) -> [LayoutBox] {
        let filtered = items.filter { $0.weight > 0 }
        guard !filtered.isEmpty, width > 0, height > 0 else { return [] }
        let ordered = filtered.sorted { lhs, rhs in
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            return lhs.id < rhs.id
        }
        let total = ordered.reduce(0.0) { $0 + $1.weight }
        let canvas = width * height
        let areas = ordered.map { $0.weight / total * canvas }
        let ids = ordered.map(\.id)

        var rects: [LayoutBox] = []
        rects.reserveCapacity(ordered.count)
        var cursorX = x
        var cursorY = y
        var remainW = width
        var remainH = height
        var index = 0
        let count = areas.count

        while index < count && remainW > 1e-9 && remainH > 1e-9 {
            let horizontal = remainW >= remainH
            let side = horizontal ? remainW : remainH
            var end = index
            var sum = 0.0
            var peak = 0.0
            var floor = Double.greatestFiniteMagnitude
            var best = Double.greatestFiniteMagnitude
            while end < count {
                let area = areas[end]
                let nextSum = sum + area
                let nextPeak = max(peak, area)
                let nextFloor = min(floor, area)
                let ratio = worst(sum: nextSum, maxArea: nextPeak, minArea: nextFloor, side: side)
                if end == index || ratio <= best {
                    best = ratio
                    sum = nextSum
                    peak = nextPeak
                    floor = nextFloor
                    end += 1
                } else {
                    break
                }
            }
            let rowSum = (index..<end).reduce(0.0) { $0 + areas[$1] }
            if horizontal {
                let thickness = remainW > 0 ? rowSum / remainW : 0
                var pen = cursorX
                for row in index..<end {
                    let last = row == end - 1
                    let itemWidth = last ? (cursorX + remainW - pen) : (thickness > 0 ? areas[row] / thickness : 0)
                    rects.append(LayoutBox(id: ids[row], x: pen, y: cursorY, width: itemWidth, height: thickness))
                    pen += itemWidth
                }
                cursorY += thickness
                remainH -= thickness
            } else {
                let thickness = remainH > 0 ? rowSum / remainH : 0
                var pen = cursorY
                for row in index..<end {
                    let last = row == end - 1
                    let itemHeight = last ? (cursorY + remainH - pen) : (thickness > 0 ? areas[row] / thickness : 0)
                    rects.append(LayoutBox(id: ids[row], x: cursorX, y: pen, width: thickness, height: itemHeight))
                    pen += itemHeight
                }
                cursorX += thickness
                remainW -= thickness
            }
            index = end
        }

        if gap <= 0 { return rects }
        let inset = gap / 2
        return rects.map { box in
            LayoutBox(
                id: box.id,
                x: box.x + inset,
                y: box.y + inset,
                width: max(0, box.width - gap),
                height: max(0, box.height - gap)
            )
        }
    }

    static func worst(sum: Double, maxArea: Double, minArea: Double, side: Double) -> Double {
        guard sum > 0, side > 0, minArea > 0 else { return .infinity }
        let side2 = side * side
        let sum2 = sum * sum
        return max(side2 * maxArea / sum2, sum2 / (side2 * minArea))
    }
}
