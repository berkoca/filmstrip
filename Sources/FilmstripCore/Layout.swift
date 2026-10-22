import Foundation
import CoreGraphics

/// When the strip scrolls to keep the focused column centred.
public enum CenterMode: String, CaseIterable, Sendable {
    /// Scroll just far enough to bring the focused column fully into view.
    case never
    /// Centre the focused column only when it would not otherwise be fully visible.
    case onOverflow
    /// Always centre the focused column.
    case always
}

public struct LayoutConfig: Equatable, Sendable {
    /// Space between columns and between stacked windows, in points.
    public var gap: Double = 8
    /// Space between the windows and the edges of the usable area, in points.
    public var outerGap: Double = 8
    /// Widths that "cycle width" steps through, as fractions of the usable width.
    public var presetWidths: [Double] = [1.0 / 3.0, 0.5, 2.0 / 3.0]
    /// Width given to new windows.
    public var defaultWidth: Double = 0.5
    /// How much "wider" / "narrower" changes the width.
    public var resizeStep: Double = 0.1
    public var centerMode: CenterMode = .never
    /// macOS will not let a window sit fully off screen; parked windows keep this many points visible.
    public var sliver: Double = 1

    public init() {}
}

/// Whether a window is on screen or parked at a screen edge.
public enum Visibility: Equatable, Sendable {
    case visible
    case hiddenLeft
    case hiddenRight
}

/// Where one window should go, in screen coordinates with the origin at the top left
/// of the primary display (the Accessibility coordinate space).
public struct Placement: Equatable, Sendable {
    public var id: WindowID
    public var frame: CGRect
    public var visibility: Visibility

    public init(id: WindowID, frame: CGRect, visibility: Visibility) {
        self.id = id
        self.frame = frame
        self.visibility = visibility
    }
}

/// The geometry a layout is computed for.
public struct LayoutGeometry: Equatable, Sendable {
    /// The whole display, used to decide when a window is off screen.
    public var screen: CGRect
    /// The part of the display windows may use (minus the menu bar, the Dock and the minimap).
    public var area: CGRect

    public init(screen: CGRect, area: CGRect) {
        self.screen = screen
        self.area = area
    }
}

/// Pure functions that turn a `StripState` into window frames.
public enum Layout {

    /// Width available to columns: the usable area minus the outer gaps.
    public static func usableWidth(_ g: LayoutGeometry, _ config: LayoutConfig) -> Double {
        max(1, Double(g.area.width) - 2 * config.outerGap)
    }

    /// Pixel width of a column. Two half-width columns plus one gap fill the usable width exactly.
    public static func columnWidth(_ column: Column, _ g: LayoutGeometry, _ config: LayoutConfig) -> Double {
        let w = usableWidth(g, config)
        return max(1, (column.effectiveFraction * (w + config.gap) - config.gap).rounded())
    }

    /// Left edge and width of every column, in strip coordinates (the first column starts at 0).
    public static func columnSpans(_ state: StripState, _ g: LayoutGeometry, _ config: LayoutConfig) -> [(x: Double, width: Double)] {
        var x = 0.0
        var spans: [(x: Double, width: Double)] = []
        spans.reserveCapacity(state.columns.count)
        for column in state.columns {
            let w = columnWidth(column, g, config)
            spans.append((x, w))
            x += w + config.gap
        }
        return spans
    }

    /// Total width of the strip, from the left edge of the first column to the right edge of the last.
    public static func totalWidth(_ state: StripState, _ g: LayoutGeometry, _ config: LayoutConfig) -> Double {
        guard let last = columnSpans(state, g, config).last else { return 0 }
        return last.x + last.width
    }

    /// Scroll offset that puts the centre of column `index` at the centre of the viewport.
    public static func centeringOffset(column index: Int, _ state: StripState, _ g: LayoutGeometry, _ config: LayoutConfig) -> Double {
        let spans = columnSpans(state, g, config)
        guard spans.indices.contains(index) else { return 0 }
        let span = spans[index]
        return span.x + span.width / 2 - usableWidth(g, config) / 2
    }

    /// The range free scrolling may move in: far enough to centre the first or the last column.
    public static func scrollBounds(_ state: StripState, _ g: LayoutGeometry, _ config: LayoutConfig) -> ClosedRange<Double> {
        guard !state.columns.isEmpty else { return 0...0 }
        let w = usableWidth(g, config)
        let total = totalWidth(state, g, config)
        let lower = min(0, centeringOffset(column: 0, state, g, config))
        let upper = max(total - w, centeringOffset(column: state.columns.count - 1, state, g, config), lower)
        return lower...upper
    }

    public static func clampOffset(_ offset: Double, _ state: StripState, _ g: LayoutGeometry, _ config: LayoutConfig) -> Double {
        let bounds = scrollBounds(state, g, config)
        return min(max(offset, bounds.lowerBound), bounds.upperBound)
    }

    /// The scroll offset that brings column `index` into view, starting from the current offset,
    /// following the configured centre mode.
    public static func offsetRevealing(column index: Int, _ state: StripState, _ g: LayoutGeometry, _ config: LayoutConfig) -> Double {
        let spans = columnSpans(state, g, config)
        guard spans.indices.contains(index) else { return 0 }
        let w = usableWidth(g, config)
        let total = totalWidth(state, g, config)
        let span = spans[index]
        let current = state.scrollOffset
        let fullyVisible = span.x >= current - 0.5 && span.x + span.width <= current + w + 0.5

        switch config.centerMode {
        case .always:
            return centeringOffset(column: index, state, g, config)
        case .onOverflow:
            if total <= w { return 0 }
            return fullyVisible ? current : centeringOffset(column: index, state, g, config)
        case .never:
            if total <= w { return 0 }
            if span.width >= w { return span.x }
            if span.x < current { return span.x }
            if span.x + span.width > current + w { return span.x + span.width - w }
            return current
        }
    }

    /// The column whose centre is closest to the centre of the viewport.
    public static func columnNearestCenter(_ state: StripState, _ g: LayoutGeometry, _ config: LayoutConfig) -> Int? {
        let spans = columnSpans(state, g, config)
        guard !spans.isEmpty else { return nil }
        let center = state.scrollOffset + usableWidth(g, config) / 2
        var best = 0
        var bestDistance = Double.infinity
        for (i, span) in spans.enumerated() {
            let d = abs(span.x + span.width / 2 - center)
            if d < bestDistance { bestDistance = d; best = i }
        }
        return best
    }

    /// Target frame and visibility for every window on the strip.
    /// - Parameter limits: sizes apps are known to refuse. A window that cannot grow to fill
    ///   its slot is centred in it; one that cannot shrink keeps its minimum size.
    public static func placements(_ state: StripState, _ g: LayoutGeometry, _ config: LayoutConfig, limits: [WindowID: SizeLimits] = [:]) -> [Placement] {
        let spans = columnSpans(state, g, config)
        let left = Double(g.area.minX) + config.outerGap
        let top = Double(g.area.minY) + config.outerGap
        let height = max(1, Double(g.area.height) - 2 * config.outerGap)
        let screenMinX = Double(g.screen.minX)
        let screenMaxX = Double(g.screen.maxX)

        var result: [Placement] = []
        for (c, column) in state.columns.enumerated() {
            let span = spans[c]
            let x = (left + span.x - state.scrollOffset).rounded()
            let count = column.windows.count
            let available = height - config.gap * Double(count - 1)
            let fractions: [Double]
            if let custom = column.rowFractions, custom.count == count {
                fractions = custom
            } else {
                fractions = Array(repeating: 1.0 / Double(count), count: count)
            }

            let visibility: Visibility
            if x + span.width <= screenMinX {
                visibility = .hiddenLeft
            } else if x >= screenMaxX {
                visibility = .hiddenRight
            } else {
                visibility = .visible
            }

            var y = top
            for (r, id) in column.windows.enumerated() {
                let rowHeight = (fractions[r] * available).rounded(.down)
                var frame = CGRect(x: x, y: y.rounded(), width: span.width, height: rowHeight)
                y += rowHeight + config.gap
                if let limit = limits[id] {
                    frame = limit.fit(frame)
                }
                switch visibility {
                case .visible:
                    break
                case .hiddenLeft:
                    frame.origin.x = screenMinX - Double(frame.width) + config.sliver
                case .hiddenRight:
                    frame.origin.x = screenMaxX - config.sliver
                }
                result.append(Placement(id: id, frame: frame, visibility: visibility))
            }
        }
        return result
    }

    /// The width fraction closest to a window's current pixel width (used when adopting existing windows).
    public static func fraction(forPixelWidth width: Double, _ g: LayoutGeometry, _ config: LayoutConfig) -> Double {
        let w = usableWidth(g, config)
        let f = (width + config.gap) / (w + config.gap)
        return min(max(f, 0.15), 1.0)
    }
}
