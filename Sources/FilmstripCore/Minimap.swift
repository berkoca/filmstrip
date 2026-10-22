import Foundation

/// One column as drawn on the minimap.
public struct MinimapTile: Equatable, Sendable {
    public var column: Int
    public var windows: [WindowID]
    /// Left edge and width in minimap points.
    public var x: Double
    public var width: Double
    public var isFocused: Bool
}

/// Everything the minimap needs to draw: tiles, the viewport frame and the overall width.
public struct MinimapLayout: Equatable, Sendable {
    public var tiles: [MinimapTile]
    public var viewportX: Double
    public var viewportWidth: Double
    /// Width of the drawing: tiles plus viewport, whichever reaches further.
    public var contentWidth: Double
    /// Minimap points per strip point (before the minimum tile width is applied).
    public var scale: Double

    public static let empty = MinimapLayout(tiles: [], viewportX: 0, viewportWidth: 0, contentWidth: 0, scale: 0)

    /// Index of the tile under minimap x, if any.
    public func tileIndex(at x: Double) -> Int? {
        tiles.firstIndex { x >= $0.x && x <= $0.x + $0.width }
    }

    /// Index a dragged tile would land at if dropped at minimap x.
    public func dropIndex(at x: Double) -> Int {
        for (i, tile) in tiles.enumerated() where x < tile.x + tile.width / 2 {
            return i
        }
        return max(0, tiles.count - 1)
    }
}

public enum Minimap {

    /// Builds the minimap for a strip.
    /// - Parameters:
    ///   - maxWidth: the most room the minimap may take; tiles shrink to fit.
    ///   - maxScale: upper limit on minimap points per strip point, so a short strip stays small.
    ///   - minTileWidth: narrow columns are drawn at least this wide so they can still be clicked.
    ///   - widthExponent: below 1, wide columns are drawn relatively narrower than on screen
    ///     (with 0.65 a full-width column is about 1.6 × a half-width one instead of 2 ×),
    ///     so one wide window does not take over the minimap.
    public static func layout(
        _ state: StripState,
        _ g: LayoutGeometry,
        _ config: LayoutConfig,
        maxWidth: Double,
        maxScale: Double = 0.12,
        tileGap: Double = 4,
        minTileWidth: Double = 22,
        widthExponent: Double = 0.65
    ) -> MinimapLayout {
        let spans = Layout.columnSpans(state, g, config)
        let viewport = Layout.usableWidth(g, config)
        guard !spans.isEmpty, maxWidth > 0 else { return .empty }

        // Each column's drawn width before scaling, compressed for wide columns.
        let drawn = spans.map { span in pow(min(span.width / viewport, 1.5), widthExponent) * viewport }
        let drawnTotal = drawn.reduce(0, +)
        let gaps = tileGap * Double(max(0, spans.count - 1))
        let roomForTiles = max(1, maxWidth - gaps)
        let scale = min(maxScale, roomForTiles / max(drawnTotal, viewport))

        // Tiles left to right; a tile is never narrower than minTileWidth.
        var tiles: [MinimapTile] = []
        var x = 0.0
        for (i, _) in spans.enumerated() {
            let w = max(minTileWidth, drawn[i] * scale)
            tiles.append(MinimapTile(
                column: i,
                windows: state.columns[i].windows,
                x: x,
                width: w,
                isFocused: state.focusedColumn == i
            ))
            x += w + tileGap
        }

        // Map the viewport through the same (piecewise) scale as the tiles.
        let map = { (stripX: Double) -> Double in mapToMinimap(stripX, spans: spans, tiles: tiles, scale: scale) }
        var vx = map(state.scrollOffset)
        var vEnd = map(state.scrollOffset + viewport)

        // Shift everything right when the viewport starts before the first tile.
        let shift = max(0, -vx)
        if shift > 0 {
            for i in tiles.indices { tiles[i].x += shift }
            vx += shift
            vEnd += shift
        }
        let tilesEnd = (tiles.last.map { $0.x + $0.width }) ?? 0
        let content = max(tilesEnd, vEnd)

        return MinimapLayout(tiles: tiles, viewportX: vx, viewportWidth: max(1, vEnd - vx), contentWidth: content, scale: scale)
    }

    /// Converts a strip x coordinate into a minimap x coordinate, following the tiles so the
    /// viewport frame lines up with them even when narrow tiles were widened.
    static func mapToMinimap(_ stripX: Double, spans: [(x: Double, width: Double)], tiles: [MinimapTile], scale: Double) -> Double {
        guard let first = spans.first, let firstTile = tiles.first else { return stripX * scale }
        if stripX <= first.x {
            return firstTile.x + (stripX - first.x) * scale
        }
        for i in spans.indices {
            let span = spans[i]
            let tile = tiles[i]
            if stripX <= span.x + span.width {
                let t = (stripX - span.x) / span.width
                return tile.x + t * tile.width
            }
            if i + 1 < spans.count {
                let next = spans[i + 1]
                if stripX < next.x {
                    // Inside the gap between two columns.
                    let gapStart = span.x + span.width
                    let t = (stripX - gapStart) / max(1, next.x - gapStart)
                    let tileGapStart = tile.x + tile.width
                    return tileGapStart + t * (tiles[i + 1].x - tileGapStart)
                }
            }
        }
        let last = spans[spans.count - 1]
        let lastTile = tiles[tiles.count - 1]
        return lastTile.x + lastTile.width + (stripX - (last.x + last.width)) * scale
    }
}
