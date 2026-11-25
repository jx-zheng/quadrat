import Foundation

/// Where the hover card sits relative to the cursor and the highlighted tile.
public enum HoverCardLayout {
    public static let offset: Double = 16
    public static let padding: Double = 8
    public static let cardWidth: Double = 280
    public static let cardHeight: Double = 140

    public struct Rect: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var minX: Double { x }
        public var minY: Double { y }
        public var maxX: Double { x + width }
        public var maxY: Double { y + height }

        public func intersects(_ other: Rect) -> Bool {
            minX < other.maxX && maxX > other.minX && minY < other.maxY && maxY > other.minY
        }
    }

    /// Top-left of the card. Prefers 16 pt below-right of the cursor, flips at the
    /// window edge, and never covers the hovered tile.
    public static func origin(
        cursorX: Double,
        cursorY: Double,
        tile: Rect,
        boundsWidth: Double,
        boundsHeight: Double,
        cardWidth: Double = cardWidth,
        cardHeight: Double = cardHeight
    ) -> (x: Double, y: Double) {
        var x = cursorX + offset
        var y = cursorY + offset
        var card = Rect(x: x, y: y, width: cardWidth, height: cardHeight)

        if card.intersects(tile) {
            // Prefer just outside the tile, still below-right of the cursor when that fits.
            let right = tile.maxX + offset
            let below = tile.maxY + offset
            let left = tile.minX - offset - cardWidth
            let above = tile.minY - offset - cardHeight
            let candidates: [(Double, Double)] = [
                (right, cursorY + offset),
                (cursorX + offset, below),
                (right, below),
                (left, cursorY + offset),
                (cursorX + offset, above),
                (left, below),
                (right, above),
                (left, above)
            ]
            if let pick = candidates.first(where: { cx, cy in
                let probe = Rect(x: cx, y: cy, width: cardWidth, height: cardHeight)
                return !probe.intersects(tile)
                    && cx >= padding
                    && cy >= padding
                    && cx + cardWidth <= boundsWidth - padding
                    && cy + cardHeight <= boundsHeight - padding
            }) {
                x = pick.0
                y = pick.1
                card = Rect(x: x, y: y, width: cardWidth, height: cardHeight)
            } else if let pick = candidates.first(where: { cx, cy in
                !Rect(x: cx, y: cy, width: cardWidth, height: cardHeight).intersects(tile)
            }) {
                x = pick.0
                y = pick.1
                card = Rect(x: x, y: y, width: cardWidth, height: cardHeight)
            }
        }

        let maxX = max(padding, boundsWidth - padding - cardWidth)
        let maxY = max(padding, boundsHeight - padding - cardHeight)
        x = min(max(padding, x), maxX)
        y = min(max(padding, y), maxY)

        // Clamping can slide the card back over the tile; nudge out again if there is room.
        card = Rect(x: x, y: y, width: cardWidth, height: cardHeight)
        if card.intersects(tile) {
            if tile.maxX + offset + cardWidth <= boundsWidth - padding {
                x = tile.maxX + offset
            } else if tile.minX - offset - cardWidth >= padding {
                x = tile.minX - offset - cardWidth
            }
            if tile.maxY + offset + cardHeight <= boundsHeight - padding {
                y = tile.maxY + offset
            } else if tile.minY - offset - cardHeight >= padding {
                y = tile.minY - offset - cardHeight
            }
            x = min(max(padding, x), maxX)
            y = min(max(padding, y), maxY)
        }
        return (x, y)
    }
}
