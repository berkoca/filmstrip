import Foundation

/// Identifies a window. On macOS this is the CGWindowID.
public typealias WindowID = UInt32

/// One column on the strip. A column normally holds one window; several windows
/// in one column are stacked top to bottom.
public struct Column: Equatable, Sendable {
    public var windows: [WindowID]
    /// Index into `windows` of the window that last had focus in this column.
    public var activeIndex: Int
    /// Width as a fraction of the usable screen width (0...1).
    public var widthFraction: Double
    /// When true the column takes the full usable width, whatever `widthFraction` says.
    public var isFullWidth: Bool
    /// Share of the column height for each stacked window. Nil (or a count that does not
    /// match `windows`) means equal heights.
    public var rowFractions: [Double]?

    public init(windows: [WindowID], widthFraction: Double, activeIndex: Int = 0, isFullWidth: Bool = false, rowFractions: [Double]? = nil) {
        self.windows = windows
        self.widthFraction = widthFraction
        self.activeIndex = activeIndex
        self.isFullWidth = isFullWidth
        self.rowFractions = rowFractions
    }

    public var activeWindow: WindowID? {
        guard !windows.isEmpty else { return nil }
        return windows[min(max(activeIndex, 0), windows.count - 1)]
    }

    /// The fraction that actually decides the column's width.
    public var effectiveFraction: Double { isFullWidth ? 1.0 : widthFraction }
}

/// The strip of one display on one Space: ordered columns, which one has focus,
/// and how far the viewport has scrolled.
public struct StripState: Equatable, Sendable {
    public var columns: [Column]
    public var focusedColumn: Int?
    /// Left edge of the viewport, in strip coordinates (points). The first column
    /// starts at strip x = 0.
    public var scrollOffset: Double

    public init(columns: [Column] = [], focusedColumn: Int? = nil, scrollOffset: Double = 0) {
        self.columns = columns
        self.focusedColumn = focusedColumn
        self.scrollOffset = scrollOffset
    }

    // MARK: Queries

    public var isEmpty: Bool { columns.isEmpty }

    public var windowIDs: [WindowID] { columns.flatMap(\.windows) }

    public func contains(_ id: WindowID) -> Bool { location(of: id) != nil }

    public func location(of id: WindowID) -> (column: Int, row: Int)? {
        for (c, column) in columns.enumerated() {
            if let r = column.windows.firstIndex(of: id) { return (c, r) }
        }
        return nil
    }

    public var focusedWindow: WindowID? {
        guard let c = focusedColumn, columns.indices.contains(c) else { return nil }
        return columns[c].activeWindow
    }

    // MARK: Adding and removing windows

    /// Inserts a window as a new column right after the focused column and focuses it.
    public mutating func insert(_ id: WindowID, widthFraction: Double) {
        guard !contains(id) else { return }
        let column = Column(windows: [id], widthFraction: widthFraction)
        let index = (focusedColumn.map { $0 + 1 }) ?? columns.count
        columns.insert(column, at: min(index, columns.count))
        focusedColumn = min(index, columns.count - 1)
    }

    /// Appends a window as the last column without changing focus (used for the initial scan).
    public mutating func append(_ id: WindowID, widthFraction: Double) {
        guard !contains(id) else { return }
        columns.append(Column(windows: [id], widthFraction: widthFraction))
        if focusedColumn == nil { focusedColumn = 0 }
    }

    /// Removes a window. Empty columns disappear and focus moves to a neighbour.
    @discardableResult
    public mutating func remove(_ id: WindowID) -> Bool {
        guard let (c, r) = location(of: id) else { return false }
        columns[c].windows.remove(at: r)
        if columns[c].windows.isEmpty {
            columns.remove(at: c)
            if columns.isEmpty {
                focusedColumn = nil
            } else if let f = focusedColumn {
                if c < f {
                    focusedColumn = f - 1
                } else if c == f {
                    focusedColumn = max(0, c - 1)
                }
            }
        } else {
            var active = columns[c].activeIndex
            if r < active { active -= 1 }
            columns[c].activeIndex = min(max(active, 0), columns[c].windows.count - 1)
        }
        return true
    }

    // MARK: Focus

    /// Focuses the given window if it is on the strip.
    @discardableResult
    public mutating func focus(_ id: WindowID) -> Bool {
        guard let (c, r) = location(of: id) else { return false }
        focusedColumn = c
        columns[c].activeIndex = r
        return true
    }

    public mutating func focusColumn(_ index: Int) {
        guard !columns.isEmpty else { return }
        focusedColumn = min(max(index, 0), columns.count - 1)
    }

    public mutating func focusLeft() { if let f = focusedColumn { focusColumn(f - 1) } }
    public mutating func focusRight() { if let f = focusedColumn { focusColumn(f + 1) } }
    public mutating func focusFirst() { focusColumn(0) }
    public mutating func focusLast() { focusColumn(columns.count - 1) }

    /// Moves focus up or down inside a stacked column.
    public mutating func focusInColumn(by delta: Int) {
        guard let f = focusedColumn, columns.indices.contains(f) else { return }
        let count = columns[f].windows.count
        columns[f].activeIndex = min(max(columns[f].activeIndex + delta, 0), count - 1)
    }

    /// Swaps the focused window with the one above (negative) or below it in its stack.
    public mutating func moveInColumn(by delta: Int) {
        guard let f = focusedColumn, columns.indices.contains(f) else { return }
        let from = columns[f].activeIndex
        let to = from + delta
        guard columns[f].windows.indices.contains(from), columns[f].windows.indices.contains(to) else { return }
        columns[f].windows.swapAt(from, to)
        columns[f].activeIndex = to
    }

    // MARK: Reordering

    /// Moves the focused column left (negative) or right (positive). Focus follows it.
    public mutating func moveFocusedColumn(by delta: Int) {
        guard let f = focusedColumn else { return }
        moveColumn(from: f, to: f + delta)
    }

    /// Moves a column to a new index. Focus stays on the column that had it.
    public mutating func moveColumn(from: Int, to: Int) {
        guard columns.indices.contains(from) else { return }
        let target = min(max(to, 0), columns.count - 1)
        guard target != from else { return }
        let focusedID = focusedWindow
        let column = columns.remove(at: from)
        columns.insert(column, at: target)
        if let id = focusedID, let (c, _) = location(of: id) { focusedColumn = c }
    }

    // MARK: Width

    /// Steps the focused column to the next preset width, wrapping around.
    public mutating func cycleWidth(presets: [Double]) {
        guard let f = focusedColumn, !presets.isEmpty else { return }
        let sorted = presets.sorted()
        let current = columns[f].effectiveFraction
        let next = sorted.first(where: { $0 > current + 0.01 }) ?? sorted[0]
        columns[f].widthFraction = next
        columns[f].isFullWidth = false
    }

    public mutating func toggleFullWidth() {
        guard let f = focusedColumn else { return }
        columns[f].isFullWidth.toggle()
    }

    /// Makes the focused column wider (positive delta) or narrower, as a fraction of the screen.
    public mutating func resizeFocused(by delta: Double, minFraction: Double = 0.1) {
        guard let f = focusedColumn else { return }
        let base = columns[f].effectiveFraction
        columns[f].widthFraction = min(max(base + delta, minFraction), 1.0)
        columns[f].isFullWidth = false
    }

    // MARK: Stacks

    /// Moves the focused window into the column on its left (delta -1) or right (+1).
    public mutating func stackFocused(into delta: Int) {
        guard let f = focusedColumn, let id = focusedWindow else { return }
        let target = f + delta
        guard columns.indices.contains(target) else { return }
        let wasAlone = columns[f].windows.count == 1
        columns[f].windows.removeAll { $0 == id }
        columns[target].windows.append(id)
        columns[target].activeIndex = columns[target].windows.count - 1
        var targetIndex = target
        if wasAlone {
            columns.remove(at: f)
            if f < target { targetIndex -= 1 }
        } else {
            columns[f].activeIndex = min(columns[f].activeIndex, columns[f].windows.count - 1)
        }
        focusedColumn = targetIndex
    }

    /// Pulls the focused window out of its stack into a new column to the right (or left).
    public mutating func unstackFocused(toRight: Bool = true) {
        guard let f = focusedColumn, let id = focusedWindow, columns[f].windows.count > 1 else { return }
        let width = columns[f].widthFraction
        columns[f].windows.removeAll { $0 == id }
        columns[f].activeIndex = min(columns[f].activeIndex, columns[f].windows.count - 1)
        let index = toRight ? f + 1 : f
        columns.insert(Column(windows: [id], widthFraction: width), at: index)
        focusedColumn = index
    }
}
