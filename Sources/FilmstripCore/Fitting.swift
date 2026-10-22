import Foundation
import CoreGraphics

/// Sizes an app will not go below (or above). Learned by watching what size a window
/// really takes after Filmstrip asks for another one.
public struct SizeLimits: Equatable, Sendable {
    public var minWidth: Double
    public var minHeight: Double
    public var maxWidth: Double?
    public var maxHeight: Double?

    public init(minWidth: Double = 0, minHeight: Double = 0, maxWidth: Double? = nil, maxHeight: Double? = nil) {
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }

    /// The frame a window will really take in `slot`: clamped to the limits, and centred in
    /// the slot when it ends up smaller. A window that is bigger keeps the slot's top left corner.
    public func fit(_ slot: CGRect) -> CGRect {
        var width = Double(slot.width)
        var height = Double(slot.height)
        if let maxWidth { width = min(width, maxWidth) }
        if let maxHeight { height = min(height, maxHeight) }
        width = max(width, minWidth)
        height = max(height, minHeight)
        let dx = max(0, (Double(slot.width) - width) / 2)
        let dy = max(0, (Double(slot.height) - height) / 2)
        return CGRect(x: (Double(slot.minX) + dx).rounded(), y: (Double(slot.minY) + dy).rounded(), width: width, height: height)
    }
}

/// Adjusts column widths and row heights so every window gets at least its minimum size.
public enum Fitting {

    /// Heights for stacked windows: equal where possible, at least each window's minimum.
    /// Returns nil when the minimums add up to more than is available.
    public static func rowHeights(minimums: [Double], available: Double) -> [Double]? {
        let n = minimums.count
        guard n > 0 else { return [] }
        guard minimums.reduce(0, +) <= available + 0.5 else { return nil }
        var fixed = [Bool](repeating: false, count: n)
        var heights = [Double](repeating: available / Double(n), count: n)
        while true {
            let freeCount = fixed.filter { !$0 }.count
            guard freeCount > 0 else { break }
            let used = (0..<n).filter { fixed[$0] }.reduce(0.0) { $0 + heights[$1] }
            let share = (available - used) / Double(freeCount)
            var changed = false
            for i in 0..<n where !fixed[i] && minimums[i] > share {
                fixed[i] = true
                heights[i] = minimums[i]
                changed = true
            }
            if !changed {
                for i in 0..<n where !fixed[i] { heights[i] = share }
                break
            }
        }
        return heights
    }

    /// Fits the rows of one column. Returns false when its windows cannot all fit.
    @discardableResult
    public static func fitRows(_ column: inout Column, limits: [WindowID: SizeLimits], height: Double, gap: Double) -> Bool {
        let n = column.windows.count
        guard n > 1 else {
            column.rowFractions = nil
            return true // a single window takes the whole height; nothing to trade
        }
        let available = height - gap * Double(n - 1)
        let minimums = column.windows.map { limits[$0]?.minHeight ?? 0 }
        guard let heights = rowHeights(minimums: minimums, available: available) else { return false }
        let equal = available / Double(n)
        column.rowFractions = heights.allSatisfy({ abs($0 - equal) < 0.5 }) ? nil : heights.map { $0 / available }
        return true
    }

    /// Widens columns to their windows' minimum width and gives stacked
    /// windows at least their minimum height where that is possible.
    public static func fitStrip(_ state: inout StripState, limits: [WindowID: SizeLimits], _ g: LayoutGeometry, _ config: LayoutConfig) {
        let usable = Layout.usableWidth(g, config)
        let height = max(1, Double(g.area.height) - 2 * config.outerGap)
        for i in state.columns.indices {
            let needed = state.columns[i].windows.map { limits[$0]?.minWidth ?? 0 }.max() ?? 0
            if needed > 0 {
                let fraction = min(1, (needed + config.gap) / (usable + config.gap))
                if state.columns[i].effectiveFraction < fraction - 0.001 {
                    state.columns[i].widthFraction = fraction
                    state.columns[i].isFullWidth = false
                }
            }
            fitRows(&state.columns[i], limits: limits, height: height, gap: config.gap)
        }
    }
}
