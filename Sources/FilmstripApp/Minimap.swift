import AppKit
import FilmstripCore

enum MinimapMode: String, CaseIterable {
    /// Always on screen; windows leave room for it.
    case always
    /// Appears while you move around the strip or hold ⌃⌥, then fades out.
    case navigating
    case off

    var title: String {
        switch self {
        case .always: return "Always"
        case .navigating: return "While navigating"
        case .off: return "Off"
        }
    }
}

enum MinimapSize: String, CaseIterable {
    case small, medium, large

    var height: CGFloat {
        switch self {
        case .small: return 32
        case .medium: return 44
        case .large: return 60
        }
    }

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
}

/// A floating panel that never takes focus and is never tiled.
final class MinimapPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: MinimapSize.medium.height),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws the strip in miniature and turns clicks, drags and scrolls into commands.
final class MinimapView: NSView {

    static let padding: CGFloat = 8

    var layout: MinimapLayout = .empty { didSet { needsDisplay = true } }
    var icons: [WindowID: NSImage] = [:] { didSet { needsDisplay = true } }

    var onSelectColumn: ((Int) -> Void)?
    var onMoveColumn: ((Int, Int) -> Void)?
    var onScroll: ((Double) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private var mouseDownPoint: NSPoint?
    private var pressedColumn: Int?
    private var grabOffset: CGFloat = 0
    private var dragX: CGFloat?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 7
        let tileHeight = bounds.height - inset * 2
        let accent = NSColor.controlAccentColor

        for tile in layout.tiles {
            var x = Self.padding + CGFloat(tile.x)
            if let dragX, tile.column == pressedColumn { x = dragX - grabOffset }
            let rect = NSRect(x: x, y: inset, width: CGFloat(tile.width), height: tileHeight)
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)

            if tile.isFocused {
                accent.withAlphaComponent(0.35).setFill()
                path.fill()
                accent.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            } else {
                NSColor.labelColor.withAlphaComponent(0.10).setFill()
                path.fill()
                NSColor.labelColor.withAlphaComponent(0.18).setStroke()
                path.lineWidth = 1
                path.stroke()
            }

            // Stacked windows: one band per window, an icon in each.
            let count = max(1, tile.windows.count)
            let band = rect.height / CGFloat(count)
            for (i, id) in tile.windows.enumerated() {
                let bandRect = NSRect(x: rect.minX, y: rect.minY + CGFloat(i) * band, width: rect.width, height: band)
                if i > 0 {
                    NSColor.labelColor.withAlphaComponent(0.2).setStroke()
                    let line = NSBezierPath()
                    line.move(to: NSPoint(x: bandRect.minX + 3, y: bandRect.minY))
                    line.line(to: NSPoint(x: bandRect.maxX - 3, y: bandRect.minY))
                    line.lineWidth = 0.5
                    line.stroke()
                }
                guard let icon = icons[id] else { continue }
                let side = min(bounds.height * 0.5, band - 4, rect.width - 6)
                guard side >= 8 else { continue }
                let iconRect = NSRect(x: bandRect.midX - side / 2, y: bandRect.midY - side / 2, width: side, height: side)
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: tile.isFocused ? 1 : 0.85, respectFlipped: true, hints: nil)
            }
        }

        // The part of the strip that is on screen.
        if !layout.tiles.isEmpty {
            let viewport = NSRect(x: Self.padding + CGFloat(layout.viewportX) - 2, y: 3,
                                  width: CGFloat(layout.viewportWidth) + 4, height: bounds.height - 6)
            let frame = NSBezierPath(roundedRect: viewport, xRadius: 7, yRadius: 7)
            NSColor.labelColor.withAlphaComponent(0.75).setStroke()
            frame.lineWidth = 1.5
            frame.stroke()
        }
    }

    // MARK: Mouse

    private func minimapX(_ event: NSEvent) -> CGFloat {
        convert(event.locationInWindow, from: nil).x
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        pressedColumn = layout.tileIndex(at: Double(point.x - Self.padding))
        if let column = pressedColumn {
            grabOffset = point.x - (Self.padding + CGFloat(layout.tiles[column].x))
        }
        dragX = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressedColumn != nil, let start = mouseDownPoint else { return }
        let x = minimapX(event)
        if dragX != nil || abs(x - start.x) > 4 {
            dragX = x
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            pressedColumn = nil
            dragX = nil
            needsDisplay = true
        }
        let x = minimapX(event)
        if let from = pressedColumn, dragX != nil {
            let to = layout.dropIndex(at: Double(x - Self.padding))
            if to != from { onMoveColumn?(from, to) }
        } else if let column = pressedColumn {
            onSelectColumn?(column)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let dx = Double(event.scrollingDeltaX)
        let dy = Double(event.scrollingDeltaY)
        var delta = -(abs(dx) > abs(dy) ? dx : dy)
        if !event.hasPreciseScrollingDeltas { delta *= 10 }
        if delta != 0 { onScroll?(delta * 3) }
    }
}

/// Owns the minimap panel: where it sits, when it shows.
final class MinimapController {

    static let margin: CGFloat = 6

    let panel = MinimapPanel()
    let view = MinimapView()
    private let background = NSVisualEffectView()

    var mode: MinimapMode = .always { didSet { refreshVisibility() } }
    var size: MinimapSize = .medium
    /// When false, windows run underneath the minimap down to the Dock.
    var reservesSpace = true

    var height: CGFloat { size.height }

    /// Bigger minimap, bigger tiles: minimap points per strip point grow with the height.
    var maxScale: Double { 0.12 * Double(height / MinimapSize.medium.height) }

    private var isActive = true
    private var hasContent = false
    private var flashing = false
    private var modifiersHeld = false
    private var hovering = false
    private var hideTimer: Timer?

    init() {
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        panel.contentView = background
        view.frame = background.bounds
        view.autoresizingMask = [.width, .height]
        background.addSubview(view)
        view.onHoverChanged = { [weak self] hovering in
            self?.hovering = hovering
            if !hovering { self?.scheduleHide() }
            self?.refreshVisibility()
        }
    }

    /// Room at the bottom of the screen that windows should leave free.
    var reservedHeight: CGFloat {
        mode == .always && reservesSpace ? height + Self.margin * 2 : 0
    }

    /// Widest the minimap may get on a screen.
    static func maxContentWidth(on screen: NSScreen) -> Double {
        Double(screen.visibleFrame.width * 0.9 - MinimapView.padding * 2)
    }

    func update(layout: MinimapLayout, icons: [WindowID: NSImage], screen: NSScreen, active: Bool) {
        view.layout = layout
        view.icons = icons
        isActive = active
        hasContent = !layout.tiles.isEmpty

        let visible = screen.visibleFrame
        let width = max(60, min(CGFloat(layout.contentWidth) + MinimapView.padding * 2, visible.width * 0.9))
        let frame = NSRect(x: visible.midX - width / 2, y: visible.minY + Self.margin, width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        refreshVisibility()
    }

    /// Shows the minimap for a moment (in "while navigating" mode).
    func flash() {
        guard mode == .navigating else { return }
        flashing = true
        refreshVisibility()
        scheduleHide()
    }

    func setModifiersHeld(_ held: Bool) {
        modifiersHeld = held
        if !held { scheduleHide() }
        refreshVisibility()
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.flashing = false
            self?.refreshVisibility()
        }
    }

    private func refreshVisibility() {
        let show: Bool
        switch mode {
        case .always: show = true
        case .navigating: show = flashing || modifiersHeld || hovering
        case .off: show = false
        }
        if show && isActive && hasContent {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }
}
