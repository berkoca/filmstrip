import AppKit
import FilmstripCore
import FilmstripPlatform

/// A thin, invisible strip laid over the top or bottom edge of a tiled window. It takes the
/// clicks there, so the window cannot be resized from above or below, and it shows the normal
/// arrow cursor, so the up-down resize cursor never appears. macOS has no way to change
/// another app's window, so this is done from the outside.
private final class EdgeGuardPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // Just above ordinary app windows, below menus, the Dock and the minimap.
        level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        // A transparent window normally lets clicks through; asking for them explicitly keeps them.
        ignoresMouseEvents = false
        contentView = EdgeGuardView()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class EdgeGuardView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }
    // Swallow the click and the drag: nothing reaches the window's edge.
    override func mouseDown(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}

/// Keeps one guard on the top edge and one on the bottom edge of every visible tiled window.
final class EdgeGuards {

    /// How far the guard reaches outside and inside the window edge, in points. macOS starts a
    /// resize a few points either side of the edge, and a little past the corners.
    private let outside: CGFloat = 5
    private let inside: CGFloat = 4

    private var panels: [WindowID: (top: EdgeGuardPanel, bottom: EdgeGuardPanel)] = [:]

    /// `frames` are the visible windows' frames in Accessibility coordinates (origin top left).
    func update(_ frames: [WindowID: CGRect]) {
        for id in panels.keys where frames[id] == nil {
            remove(id)
        }
        for (id, frame) in frames {
            let pair = panels[id] ?? (EdgeGuardPanel(), EdgeGuardPanel())
            panels[id] = pair
            let width = frame.width + outside * 2
            let height = outside + inside
            let top = CGRect(x: frame.minX - outside, y: frame.minY - outside, width: width, height: height)
            let bottom = CGRect(x: frame.minX - outside, y: frame.maxY - inside, width: width, height: height)
            place(pair.top, top)
            place(pair.bottom, bottom)
        }
    }

    func removeAll() {
        for id in Array(panels.keys) { remove(id) }
    }

    private func place(_ panel: EdgeGuardPanel, _ axRect: CGRect) {
        let rect = Displays.toAppKit(axRect)
        if panel.frame != rect { panel.setFrame(rect, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func remove(_ id: WindowID) {
        guard let pair = panels.removeValue(forKey: id) else { return }
        pair.top.orderOut(nil)
        pair.bottom.orderOut(nil)
    }
}
