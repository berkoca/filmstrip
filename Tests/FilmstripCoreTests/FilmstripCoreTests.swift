import XCTest
import CoreGraphics
@testable import FilmstripCore

final class ModelTests: XCTestCase {

    func testInsertGoesRightOfFocusAndTakesFocus() {
        var s = StripState()
        s.insert(1, widthFraction: 0.5)
        s.insert(2, widthFraction: 0.5)
        s.focusColumn(0)
        s.insert(3, widthFraction: 0.5)
        XCTAssertEqual(s.windowIDs, [1, 3, 2])
        XCTAssertEqual(s.focusedWindow, 3)
    }

    func testRemoveFocusedMovesFocusLeft() {
        var s = StripState()
        [1, 2, 3].forEach { s.append($0, widthFraction: 0.5) }
        s.focusColumn(1)
        s.remove(2)
        XCTAssertEqual(s.windowIDs, [1, 3])
        XCTAssertEqual(s.focusedWindow, 1)
    }

    func testRemoveLeftOfFocusKeepsSameWindowFocused() {
        var s = StripState()
        [1, 2, 3].forEach { s.append($0, widthFraction: 0.5) }
        s.focusColumn(2)
        s.remove(1)
        XCTAssertEqual(s.focusedWindow, 3)
    }

    func testRemoveLastWindowClearsFocus() {
        var s = StripState()
        s.append(1, widthFraction: 0.5)
        s.remove(1)
        XCTAssertTrue(s.isEmpty)
        XCTAssertNil(s.focusedColumn)
    }

    func testFocusClampsAtEdges() {
        var s = StripState()
        [1, 2].forEach { s.append($0, widthFraction: 0.5) }
        s.focusLeft()
        XCTAssertEqual(s.focusedColumn, 0)
        s.focusRight(); s.focusRight()
        XCTAssertEqual(s.focusedColumn, 1)
    }

    func testMoveColumnKeepsFocusOnMovedWindow() {
        var s = StripState()
        [1, 2, 3].forEach { s.append($0, widthFraction: 0.5) }
        s.focusColumn(0)
        s.moveFocusedColumn(by: 1)
        XCTAssertEqual(s.windowIDs, [2, 1, 3])
        XCTAssertEqual(s.focusedWindow, 1)
        s.moveFocusedColumn(by: 5)
        XCTAssertEqual(s.windowIDs, [2, 3, 1])
    }

    func testCycleWidthWraps() {
        var s = StripState()
        s.append(1, widthFraction: 0.5)
        let presets = [1.0 / 3.0, 0.5, 2.0 / 3.0]
        s.cycleWidth(presets: presets)
        XCTAssertEqual(s.columns[0].widthFraction, 2.0 / 3.0, accuracy: 0.001)
        s.cycleWidth(presets: presets)
        XCTAssertEqual(s.columns[0].widthFraction, 1.0 / 3.0, accuracy: 0.001)
    }

    func testStackAndUnstack() {
        var s = StripState()
        [1, 2, 3].forEach { s.append($0, widthFraction: 0.5) }
        s.focusColumn(1)
        s.stackFocused(into: -1)
        XCTAssertEqual(s.columns.count, 2)
        XCTAssertEqual(s.columns[0].windows, [1, 2])
        XCTAssertEqual(s.focusedWindow, 2)
        s.unstackFocused()
        XCTAssertEqual(s.columns.map(\.windows), [[1], [2], [3]])
        XCTAssertEqual(s.focusedWindow, 2)
    }

    func testRemoveFromStackKeepsActiveIndexValid() {
        var s = StripState(columns: [Column(windows: [1, 2, 3], widthFraction: 0.5, activeIndex: 2)], focusedColumn: 0)
        s.remove(1)
        XCTAssertEqual(s.focusedWindow, 3)
        s.remove(3)
        XCTAssertEqual(s.focusedWindow, 2)
    }
}

final class LayoutTests: XCTestCase {

    // A 1000 x 600 display, no menu bar: usable width = 1000 - 2 * 8 = 984.
    let g = LayoutGeometry(screen: CGRect(x: 0, y: 0, width: 1000, height: 600),
                           area: CGRect(x: 0, y: 0, width: 1000, height: 600))
    let config = LayoutConfig()

    func testTwoHalvesFillTheScreen() {
        let s = StripState(columns: [Column(windows: [1], widthFraction: 0.5), Column(windows: [2], widthFraction: 0.5)], focusedColumn: 0)
        let p = Layout.placements(s, g, config)
        XCTAssertEqual(p[0].frame.minX, 8)
        XCTAssertEqual(p[1].frame.maxX, 992, accuracy: 1)
        XCTAssertEqual(p[1].frame.minX - p[0].frame.maxX, 8, accuracy: 1)
        XCTAssertTrue(p.allSatisfy { $0.visibility == .visible })
    }

    func testOffscreenColumnsAreParkedWithASliver() {
        let s = StripState(columns: (1...4).map { Column(windows: [WindowID($0)], widthFraction: 0.5) }, focusedColumn: 0)
        let p = Layout.placements(s, g, config)
        XCTAssertEqual(p[2].visibility, .hiddenRight)
        XCTAssertEqual(p[2].frame.minX, 999)
        XCTAssertEqual(p[3].visibility, .hiddenRight)
    }

    func testRevealScrollsJustEnoughInNeverMode() {
        var s = StripState(columns: (1...4).map { Column(windows: [WindowID($0)], widthFraction: 0.5) }, focusedColumn: 0)
        s.focusColumn(2)
        let offset = Layout.offsetRevealing(column: 2, s, g, config)
        s.scrollOffset = offset
        let p = Layout.placements(s, g, config)
        XCTAssertEqual(p[2].visibility, .visible)
        XCTAssertEqual(p[2].frame.maxX, 992, accuracy: 1)
        XCTAssertEqual(p[0].visibility, .hiddenLeft)
    }

    func testStripThatFitsStaysLeftAligned() {
        var s = StripState(columns: [Column(windows: [1], widthFraction: 0.5)], focusedColumn: 0, scrollOffset: 300)
        s.scrollOffset = Layout.offsetRevealing(column: 0, s, g, config)
        XCTAssertEqual(s.scrollOffset, 0)
    }

    func testAlwaysCenterCentersColumn() {
        var c = config
        c.centerMode = .always
        let s = StripState(columns: (1...3).map { Column(windows: [WindowID($0)], widthFraction: 0.5) }, focusedColumn: 1)
        let offset = Layout.offsetRevealing(column: 1, s, g, c)
        var t = s
        t.scrollOffset = offset
        let p = Layout.placements(t, g, c)
        XCTAssertEqual(p[1].frame.midX, 500, accuracy: 1)
    }

    func testStackedWindowsSplitHeight() {
        let s = StripState(columns: [Column(windows: [1, 2], widthFraction: 0.5)], focusedColumn: 0)
        let p = Layout.placements(s, g, config)
        XCTAssertEqual(p[0].frame.minY, 8)
        XCTAssertEqual(p[1].frame.maxY, 592, accuracy: 1)
        XCTAssertEqual(p[0].frame.width, p[1].frame.width)
    }

    func testNearestColumnToCenter() {
        var s = StripState(columns: (1...4).map { Column(windows: [WindowID($0)], widthFraction: 0.5) }, focusedColumn: 0)
        s.scrollOffset = 700
        XCTAssertEqual(Layout.columnNearestCenter(s, g, config), 2)
    }

    func testScrollBoundsAllowCenteringEnds() {
        let s = StripState(columns: (1...4).map { Column(windows: [WindowID($0)], widthFraction: 0.5) }, focusedColumn: 0)
        let bounds = Layout.scrollBounds(s, g, config)
        XCTAssertLessThan(bounds.lowerBound, 0)
        XCTAssertGreaterThan(bounds.upperBound, Layout.totalWidth(s, g, config) - Layout.usableWidth(g, config))
    }
}

final class MinimapTests: XCTestCase {

    let g = LayoutGeometry(screen: CGRect(x: 0, y: 0, width: 1000, height: 600),
                           area: CGRect(x: 0, y: 0, width: 1000, height: 600))

    func testTilesAreOrderedAndFocusedMarked() {
        let s = StripState(columns: (1...5).map { Column(windows: [WindowID($0)], widthFraction: 0.5) }, focusedColumn: 2)
        let m = Minimap.layout(s, g, LayoutConfig(), maxWidth: 400)
        XCTAssertEqual(m.tiles.count, 5)
        XCTAssertTrue(zip(m.tiles, m.tiles.dropFirst()).allSatisfy { $0.x + $0.width < $1.x })
        XCTAssertEqual(m.tiles.filter(\.isFocused).map(\.column), [2])
        XCTAssertLessThanOrEqual(m.contentWidth, 400 + 1)
    }

    func testViewportCoversVisibleTiles() {
        let s = StripState(columns: (1...4).map { Column(windows: [WindowID($0)], widthFraction: 0.5) }, focusedColumn: 0)
        let m = Minimap.layout(s, g, LayoutConfig(), maxWidth: 400)
        XCTAssertEqual(m.viewportX, m.tiles[0].x, accuracy: 0.5)
        XCTAssertEqual(m.viewportX + m.viewportWidth, m.tiles[1].x + m.tiles[1].width, accuracy: 0.5)
    }

    func testFullWidthTileIsCompressed() {
        let s = StripState(columns: [Column(windows: [1], widthFraction: 0.5), Column(windows: [2], widthFraction: 0.5, isFullWidth: true)], focusedColumn: 0)
        let m = Minimap.layout(s, g, LayoutConfig(), maxWidth: 400)
        let ratio = m.tiles[1].width / m.tiles[0].width
        XCTAssertGreaterThan(ratio, 1.3)
        XCTAssertLessThan(ratio, 1.8)
    }

    func testHitTestingAndDropIndex() {
        let s = StripState(columns: (1...3).map { Column(windows: [WindowID($0)], widthFraction: 0.5) }, focusedColumn: 0)
        let m = Minimap.layout(s, g, LayoutConfig(), maxWidth: 400)
        XCTAssertEqual(m.tileIndex(at: m.tiles[1].x + 1), 1)
        XCTAssertEqual(m.dropIndex(at: m.tiles[2].x + m.tiles[2].width - 1), 2)
        XCTAssertEqual(m.dropIndex(at: 0), 0)
    }
}

final class AnimationTests: XCTestCase {

    func testEasingEndpoints() {
        XCTAssertEqual(Easing.easeOutCubic(0), 0)
        XCTAssertEqual(Easing.easeOutCubic(1), 1)
        XCTAssertGreaterThan(Easing.easeOutCubic(0.5), 0.5)
    }

    func testParkedWindowsJumpVisibleOnesSlide() {
        let current: [WindowID: CGRect] = [1: CGRect(x: 0, y: 0, width: 100, height: 100), 2: CGRect(x: 999, y: 0, width: 100, height: 100)]
        let targets = [
            Placement(id: 1, frame: CGRect(x: 50, y: 0, width: 100, height: 100), visibility: .visible),
            Placement(id: 2, frame: CGRect(x: 999, y: 10, width: 100, height: 100), visibility: .hiddenRight),
        ]
        let (tweens, jumps) = makeTweens(from: current, to: targets, wasVisible: { $0 == 1 })
        XCTAssertEqual(tweens.map(\.id), [1])
        XCTAssertEqual(jumps.map(\.id), [2])
        XCTAssertEqual(tweens[0].frame(at: 0.5).minX, 25)
        XCTAssertEqual(tweens[0].frame(at: 0).size, CGSize(width: 100, height: 100))
    }

    func testTweenPutsTopEdgeAndSizeInPlaceAtOnce() {
        let tween = FrameTween(id: 1, from: CGRect(x: 0, y: 400, width: 200, height: 200),
                               to: CGRect(x: 100, y: 30, width: 300, height: 800))
        let start = tween.frame(at: 0)
        XCTAssertEqual(start.minX, 0)
        XCTAssertEqual(start.minY, 30)
        XCTAssertEqual(start.size, CGSize(width: 300, height: 800))
    }
}

final class StackMoveTests: XCTestCase {
    func testMoveInColumnSwapsAndKeepsFocus() {
        var s = StripState(columns: [Column(windows: [1, 2, 3], widthFraction: 0.5, activeIndex: 0)], focusedColumn: 0)
        s.moveInColumn(by: 1)
        XCTAssertEqual(s.columns[0].windows, [2, 1, 3])
        XCTAssertEqual(s.focusedWindow, 1)
        s.moveInColumn(by: -5)
        XCTAssertEqual(s.columns[0].windows, [2, 1, 3])
    }
}

final class FittingTests: XCTestCase {

    // Usable area 984 x 584 (1000 x 600 display, 8 pt outer gaps).
    let g = LayoutGeometry(screen: CGRect(x: 0, y: 0, width: 1000, height: 600),
                           area: CGRect(x: 0, y: 0, width: 1000, height: 600))
    let config = LayoutConfig()

    func testRowHeightsRespectMinimums() {
        let heights = Fitting.rowHeights(minimums: [400, 0], available: 576)!
        XCTAssertEqual(heights[0], 400)
        XCTAssertEqual(heights[1], 176)
        XCTAssertNil(Fitting.rowHeights(minimums: [400, 300], available: 576))
    }

    func testColumnWidensToMinimumWidth() {
        var s = StripState(columns: [Column(windows: [1], widthFraction: 0.3), Column(windows: [2], widthFraction: 0.5)], focusedColumn: 0)
        Fitting.fitStrip(&s, limits: [1: SizeLimits(minWidth: 600)], g, config)
        let p = Layout.placements(s, g, config)
        XCTAssertGreaterThanOrEqual(p[0].frame.width, 600)
        XCTAssertEqual(s.columns[1].widthFraction, 0.5)
    }

    func testStackGivesTallWindowItsMinimum() {
        var s = StripState(columns: [Column(windows: [1, 2], widthFraction: 0.5)], focusedColumn: 0)
        let limits: [WindowID: SizeLimits] = [2: SizeLimits(minHeight: 400)]
        Fitting.fitStrip(&s, limits: limits, g, config)
        let p = Layout.placements(s, g, config, limits: limits)
        XCTAssertGreaterThanOrEqual(p[1].frame.height, 400)
        XCTAssertLessThanOrEqual(p[1].frame.maxY, 592)
        XCTAssertGreaterThanOrEqual(p[1].frame.minY, p[0].frame.maxY)
    }

    func testWindowThatCannotGrowIsCentred() {
        let frame = SizeLimits(maxWidth: 300, maxHeight: 200).fit(CGRect(x: 0, y: 0, width: 500, height: 400))
        XCTAssertEqual(frame, CGRect(x: 100, y: 100, width: 300, height: 200))
    }

}
