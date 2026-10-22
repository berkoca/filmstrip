import AppKit
import os
import FilmstripCore
import FilmstripPlatform

private let log = Logger(subsystem: "io.github.berkoca.filmstrip", category: "manager")

/// Ties everything together: tracker events and shortcuts change the strip model,
/// the model is laid out, and the result is applied to real windows and the minimap.
/// Everything here runs on the main thread.
final class WindowManager {

    // MARK: Settings

    var config = LayoutConfig()
    var minimapMode: MinimapMode = .always {
        didSet {
            minimap.mode = minimapMode
            saveSettings()
            usableAreaChanged()
        }
    }
    var minimapSize: MinimapSize = .medium {
        didSet {
            minimap.size = minimapSize
            saveSettings()
            usableAreaChanged()
        }
    }
    var invertScroll = false {
        didSet { input.invertScroll = invertScroll; saveSettings() }
    }
    /// When the minimap is always shown: false = windows stop above it, true = windows reach
    /// down to the Dock and the minimap floats on top of them.
    var windowsUnderMinimap = false {
        didSet {
            minimap.reservesSpace = !windowsUnderMinimap
            saveSettings()
            usableAreaChanged()
        }
    }

    private(set) var isEnabled = true
    private(set) var isStarted = false
    private(set) var inputAvailable = false

    // MARK: Parts

    let tracker = WindowTracker()
    let input = InputMonitor()
    let animator = FrameAnimator()
    let minimap = MinimapController()
    let edgeGuards = EdgeGuards()

    // MARK: State

    /// One strip per Space.
    private var strips: [UInt64: StripState] = [:]
    private var spaceID: UInt64 = 0
    private var floating = Set<WindowID>()
    /// The frame Filmstrip last gave each window.
    private var applied: [WindowID: CGRect] = [:]
    private var visibility: [WindowID: Visibility] = [:]
    private var iconCache: [pid_t: NSImage] = [:]
    /// Sizes apps refused to go below or above, learned by reading windows back.
    private var sizeLimits: [WindowID: SizeLimits] = [:]
    private var sizeCheckTimer: Timer?

    /// Moves and resizes reported within this time after Filmstrip itself changed a window
    /// are echoes of Filmstrip's own change, not something the user did.
    private var ownChangeUntil: [WindowID: TimeInterval] = [:]
    /// Fires once the user stops dragging or resizing a window by hand.
    private var manualChangeTimer: Timer?

    private var scrollIdleTimer: Timer?
    private var scrollApplyPending = false
    /// Focus reports that arrive right after Filmstrip itself focused a window are echoes; ignore them.
    private var ignoreFocusUntil: TimeInterval = 0

    private var state: StripState {
        get { strips[spaceID] ?? StripState() }
        set { strips[spaceID] = newValue }
    }

    var windowCount: Int { state.windowIDs.count }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Geometry

    private var geometry: LayoutGeometry? {
        guard let screen = Displays.managedScreen else { return nil }
        var usable = screen.visibleFrame
        let reserve = minimap.reservedHeight
        usable.origin.y += reserve
        usable.size.height -= reserve
        return LayoutGeometry(screen: Displays.toAX(screen.frame), area: Displays.toAX(usable))
    }

    private func isOnManagedScreen(_ frame: CGRect?) -> Bool {
        guard let frame else { return false }
        return Displays.belongsToManagedScreen(frame)
    }

    // MARK: Start

    func start() {
        guard !isStarted else { return }
        isStarted = true
        loadSettings()

        tracker.onWindowCreated = { [weak self] window in self?.windowAppeared(window, focus: true) }
        tracker.onWindowRestored = { [weak self] window in self?.windowAppeared(window, focus: true) }
        tracker.onWindowDestroyed = { [weak self] id in self?.windowGone(id) }
        tracker.onWindowMinimized = { [weak self] id in self?.windowGone(id) }
        tracker.onWindowFocused = { [weak self] id in self?.windowFocused(id) }
        tracker.onWindowResized = { [weak self] id in self?.windowChangedByHand(id, resized: true) }
        tracker.onWindowMoved = { [weak self] id in self?.windowChangedByHand(id, resized: false) }
        tracker.onAppHidden = { [weak self] pid in self?.appHidden(pid) }
        tracker.onAppShown = { [weak self] pid in self?.appShown(pid) }
        tracker.onAppTerminated = { [weak self] _, ids in ids.forEach { self?.windowGone($0) } }
        tracker.onSpaceChanged = { [weak self] in self?.spaceChanged() }
        tracker.start()

        input.onAction = { [weak self] action in self?.perform(action) }
        input.onScroll = { [weak self] delta in self?.scroll(by: delta) }
        input.onModifiersHeld = { [weak self] held in self?.minimap.setModifiersHeld(held) }
        input.invertScroll = invertScroll
        inputAvailable = input.start()
        if !inputAvailable { log.error("Could not create the event tap; shortcuts will not work.") }

        animator.apply = { [weak self] frames in self?.apply(frames) }
        animator.onFinish = { [weak self] in self?.scheduleSizeCheck() }

        minimap.mode = minimapMode
        minimap.size = minimapSize
        minimap.reservesSpace = !windowsUnderMinimap
        minimap.view.onSelectColumn = { [weak self] column in self?.selectColumn(column) }
        minimap.view.onMoveColumn = { [weak self] from, to in self?.moveColumn(from: from, to: to) }
        minimap.view.onScroll = { [weak self] delta in self?.scroll(by: delta) }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.usableAreaChanged(animated: false)
        }

        spaceID = Displays.activeSpaceID()
        reconcile(focusFrontmost: true)
        log.info("Started with \(self.windowCount) windows")
    }

    // MARK: Enable / pause

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            isEnabled = true
            input.isPaused = false
            strips.removeAll()
            applied.removeAll()
            visibility.removeAll()
            reconcile(focusFrontmost: true)
        } else {
            restoreAllWindows()
            isEnabled = false
            input.isPaused = true
            edgeGuards.removeAll()
            updateMinimap()
        }
    }

    /// Puts every window Filmstrip parked off screen back where the user can reach it.
    /// Called when pausing and when quitting, so nothing is left stranded at a screen edge.
    func restoreAllWindows() {
        animator.stop()
        edgeGuards.removeAll()
        guard let g = geometry else { return }
        let area = g.area
        var cascade: CGFloat = 0
        // Every window Filmstrip ever placed, whether or not it is still on a strip.
        var ids = Set(applied.keys)
        for strip in strips.values { ids.formUnion(strip.windowIDs) }
        for id in ids.sorted() {
            guard let window = tracker.known[id], let frame = window.frame ?? applied[id] else { continue }
            if frame.minX >= g.screen.minX && frame.maxX <= g.screen.maxX { continue }
            let width = min(frame.width, area.width - 64)
            let height = min(frame.height, area.height - 64)
            let rect = CGRect(x: area.midX - width / 2 + cascade, y: area.minY + 32 + cascade, width: width, height: height)
            WindowMover.setFrame(window, rect, resize: true)
            cascade = (cascade + 24).truncatingRemainder(dividingBy: 240)
        }
        applied.removeAll()
        visibility.removeAll()
    }

    // MARK: Window events

    private func windowAppeared(_ window: TrackedWindow, focus: Bool) {
        guard isEnabled, !floating.contains(window.id), let g = geometry else { return }
        guard !state.contains(window.id) else { return }
        let frame = window.frame
        guard isOnManagedScreen(frame) else { return }
        if let frame { applied[window.id] = frame } // slide from where it opened

        var s = state
        s.insert(window.id, widthFraction: config.defaultWidth)
        reveal(&s, g)
        state = s
        relayout(animated: true)
        if focus { focusCurrent() }
        minimap.flash()
    }

    private func windowGone(_ id: WindowID) {
        sizeLimits.removeValue(forKey: id)
        applied.removeValue(forKey: id)
        visibility.removeValue(forKey: id)
        ownChangeUntil.removeValue(forKey: id)
        floating.remove(id)
        var changedCurrent = false
        for key in Array(strips.keys) {
            guard var strip = strips[key], strip.contains(id) else { continue }
            let wasFocused = strip.focusedWindow == id
            strip.remove(id)
            strips[key] = strip
            if key == spaceID {
                changedCurrent = true
                if wasFocused { DispatchQueue.main.async { [weak self] in self?.focusCurrent() } }
            }
        }
        guard changedCurrent, isEnabled, let g = geometry else { return }
        var s = state
        reveal(&s, g)
        state = s
        relayout(animated: true)
    }

    private func windowFocused(_ id: WindowID) {
        guard isEnabled, now >= ignoreFocusUntil, let g = geometry else { return }
        if state.contains(id) {
            guard state.focusedWindow != id else { return }
            var s = state
            s.focus(id)
            reveal(&s, g)
            state = s
            relayout(animated: true)
            minimap.flash()
        } else if !floating.contains(id) {
            // A window Filmstrip did not pick up yet: one an app opened before Filmstrip was listening,
            // or one that left full screen.
            if let window = tracker.known[id] {
                if tracker.isManageable(window.element) { windowAppeared(window, focus: false) }
            } else if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                      let window = tracker.focusedManageableWindow(of: pid), window.id == id {
                windowAppeared(window, focus: false)
            }
        }
    }

    private func appHidden(_ pid: pid_t) {
        let ids = state.windowIDs.filter { tracker.known[$0]?.pid == pid }
        ids.forEach(windowGone)
    }

    private func appShown(_ pid: pid_t) {
        for window in tracker.windows(of: pid) { windowAppeared(window, focus: false) }
    }

    private func spaceChanged() {
        animator.stop()
        spaceID = Displays.activeSpaceID()
        reconcile(focusFrontmost: true)
    }

    /// Brings the current Space's strip in line with the windows that are really there.
    private func reconcile(focusFrontmost: Bool) {
        guard isEnabled, let g = geometry else { return }
        let windows = tracker.scanWindows()
        let present = Set(windows.map(\.id))
        let onScreen = Displays.onScreenWindowIDs()

        var s = state
        for id in s.windowIDs where !present.contains(id) { s.remove(id) }

        // Only windows on this Space count as new; Accessibility can also list others.
        // Windows parked at a screen edge are included, so nothing is left stranded there.
        let newcomers = windows
            .filter { !s.contains($0.id) && !floating.contains($0.id) && Displays.isOnActiveSpace($0.id, onScreen: onScreen) }
            .compactMap { window -> (TrackedWindow, CGRect)? in
                guard let frame = window.frame, isOnManagedScreen(frame) else { return nil }
                return (window, frame)
            }
            .sorted { $0.1.minX < $1.1.minX }
        for (window, frame) in newcomers {
            s.append(window.id, widthFraction: Layout.fraction(forPixelWidth: Double(frame.width), g, config))
            applied[window.id] = frame
            // A window that moved here from another Space leaves that Space's strip.
            for key in strips.keys where key != spaceID { strips[key]?.remove(window.id) }
        }

        if focusFrontmost, let id = tracker.focusedWindowID(), s.contains(id) { s.focus(id) }
        reveal(&s, g)
        state = s
        relayout(animated: true)
    }

    // MARK: Windows changed by hand

    /// The user (or the app) moved or resized a window. A resize is followed live: while an
    /// edge is being dragged the window is read 60 times a second, and the neighbours on that
    /// side slide along (drag the left edge and the windows on the left move; drag the right
    /// edge and the ones on the right move). The minimap follows too. When the mouse is let
    /// go, the window snaps back into the strip: full height, in line.
    private func windowChangedByHand(_ id: WindowID, resized: Bool) {
        guard isEnabled, state.contains(id), !animator.isRunning else { return }
        guard now >= (ownChangeUntil[id] ?? 0) else { return } // an echo of Filmstrip's own move

        if resized {
            followResize(of: id)
            if NSEvent.pressedMouseButtons != 0 { startLiveResize(of: id) }
        } else if let actual = tracker.known[id]?.frame {
            applied[id] = actual
        }

        manualChangeTimer?.invalidate()
        manualChangeTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.manualChangeEnded()
        }
    }

    /// Takes over a window's new width and position while the user resizes it.
    private func followResize(of id: WindowID) {
        guard let g = geometry, let window = tracker.known[id], let actual = window.frame,
              let last = applied[id], let column = state.location(of: id)?.column else { return }
        let widthChanged = abs(actual.width - last.width) > 1
        let leftEdgeMoved = abs(actual.minX - last.minX) > 1
        guard widthChanged || leftEdgeMoved else { return }

        var s = state
        if widthChanged {
            s.columns[column].widthFraction = min(1, Layout.fraction(forPixelWidth: Double(actual.width), g, config))
            s.columns[column].isFullWidth = false
        }
        // Keep the window exactly where the user has it by scrolling the strip under it: its
        // left edge stays put when the right edge is dragged (the windows on the right move),
        // and follows the mouse when the left edge is dragged (the windows on the left move).
        let spans = Layout.columnSpans(s, g, config)
        if spans.indices.contains(column) {
            s.scrollOffset = Double(g.area.minX) + config.outerGap + spans[column].x - Double(actual.minX)
        }
        state = s
        applied[id] = actual

        let placements = Layout.placements(s, g, config, limits: sizeLimits)
        var frames: [WindowID: CGRect] = [:]
        for p in placements where p.id != id { frames[p.id] = p.frame }
        apply(frames)
        for p in placements { visibility[p.id] = p.visibility }
        updateMinimap()
    }

    private var liveResizeTimer: Timer?
    private var liveResizeWindow: WindowID?

    /// Many apps report a resize only when the mouse is let go. Reading the window while the
    /// button is held makes the neighbours and the minimap follow every app the same way.
    private func startLiveResize(of id: WindowID) {
        liveResizeWindow = id
        guard liveResizeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self, let id = self.liveResizeWindow, NSEvent.pressedMouseButtons != 0, self.isEnabled else {
                timer.invalidate()
                self?.liveResizeTimer = nil
                self?.liveResizeWindow = nil
                return
            }
            self.followResize(of: id)
        }
        RunLoop.main.add(timer, forMode: .common)
        liveResizeTimer = timer
    }

    private func manualChangeEnded() {
        // Still holding the mouse button: the drag is not over yet.
        if NSEvent.pressedMouseButtons != 0 {
            manualChangeTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                self?.manualChangeEnded()
            }
            return
        }
        liveResizeTimer?.invalidate()
        liveResizeTimer = nil
        liveResizeWindow = nil
        guard isEnabled, let g = geometry else { return }
        var s = state
        reveal(&s, g)
        state = s
        relayout(animated: true)
    }

    // MARK: Commands

    private func perform(_ action: Action) {
        switch action {
        case .toggleEnabled:
            setEnabled(!isEnabled)
            return
        case .toggleMinimap:
            minimapMode = minimapMode == .off ? .always : .off
            return
        case .toggleFloat:
            toggleFloat()
            return
        default:
            break
        }
        guard isEnabled, let g = geometry, !state.isEmpty else { return }
        var s = state
        switch action {
        case .focusLeft: s.focusLeft()
        case .focusRight: s.focusRight()
        case .focusUp: s.focusInColumn(by: -1)
        case .focusDown: s.focusInColumn(by: 1)
        case .moveUp: s.moveInColumn(by: -1)
        case .moveDown: s.moveInColumn(by: 1)
        case .focusFirst: s.focusFirst()
        case .focusLast: s.focusLast()
        case .focusIndex(let n): s.focusColumn(n - 1)
        case .moveLeft: s.moveFocusedColumn(by: -1)
        case .moveRight: s.moveFocusedColumn(by: 1)
        case .stackIntoLeft: s.stackFocused(into: -1)
        case .stackIntoRight: s.stackFocused(into: 1)
        case .unstackRight: s.unstackFocused(toRight: true)
        case .unstackLeft: s.unstackFocused(toRight: false)
        case .cycleWidth: s.cycleWidth(presets: config.presetWidths)
        case .fullWidth: s.toggleFullWidth()
        case .wider: s.resizeFocused(by: config.resizeStep)
        case .narrower: s.resizeFocused(by: -config.resizeStep)
        case .center:
            if let f = s.focusedColumn { s.scrollOffset = Layout.centeringOffset(column: f, s, g, config) }
            state = s
            relayout(animated: true)
            minimap.flash()
            return
        case .toggleEnabled, .toggleMinimap, .toggleFloat:
            return
        }
        reveal(&s, g)
        state = s
        relayout(animated: true)
        focusCurrent()
        minimap.flash()
    }

    private func selectColumn(_ column: Int) {
        guard isEnabled, let g = geometry else { return }
        var s = state
        s.focusColumn(column)
        reveal(&s, g)
        state = s
        relayout(animated: true)
        focusCurrent()
    }

    private func moveColumn(from: Int, to: Int) {
        guard isEnabled, let g = geometry else { return }
        var s = state
        s.moveColumn(from: from, to: to)
        reveal(&s, g)
        state = s
        relayout(animated: true)
    }

    private func toggleFloat() {
        guard isEnabled, let g = geometry, let id = tracker.focusedWindowID() else { return }
        if floating.contains(id) {
            floating.remove(id)
            if let window = tracker.known[id] { windowAppeared(window, focus: true) }
            return
        }
        guard state.contains(id) else { return }
        var s = state
        s.remove(id)
        reveal(&s, g)
        state = s
        floating.insert(id)
        applied.removeValue(forKey: id)
        visibility.removeValue(forKey: id)
        if let window = tracker.known[id] {
            let area = g.area
            let rect = CGRect(x: area.midX - area.width * 0.3, y: area.midY - area.height * 0.3,
                              width: area.width * 0.6, height: area.height * 0.6)
            WindowMover.setFrame(window, rect, resize: true)
            AX.raise(window.element)
        }
        relayout(animated: true)
    }

    // MARK: Scrolling

    private func scroll(by delta: Double) {
        guard isEnabled, let g = geometry, !state.isEmpty else { return }
        animator.stop()
        var s = state
        s.scrollOffset = Layout.clampOffset(s.scrollOffset + delta, s, g, config)
        state = s
        scheduleScrollApply()
        minimap.flash()

        scrollIdleTimer?.invalidate()
        scrollIdleTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.scrollEnded()
        }
    }

    /// Scroll events arrive faster than windows can move; apply only the latest offset.
    private func scheduleScrollApply() {
        guard !scrollApplyPending else { return }
        scrollApplyPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollApplyPending = false
            guard let g = self.geometry else { return }
            let placements = Layout.placements(self.state, g, self.config, limits: self.sizeLimits)
            self.apply(Dictionary(placements.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first }))
            for p in placements { self.visibility[p.id] = p.visibility }
            self.updateMinimap()
        }
    }

    /// When scrolling stops, the column nearest the centre gets focus and comes fully into view.
    private func scrollEnded() {
        guard isEnabled, let g = geometry else { return }
        var s = state
        guard let nearest = Layout.columnNearestCenter(s, g, config) else { return }
        s.focusColumn(nearest)
        reveal(&s, g)
        state = s
        relayout(animated: true)
        focusCurrent()
    }

    // MARK: Layout

    private func reveal(_ s: inout StripState, _ g: LayoutGeometry) {
        guard let f = s.focusedColumn else {
            s.scrollOffset = 0
            return
        }
        s.scrollOffset = Layout.offsetRevealing(column: f, s, g, config)
    }

    func relayout(animated: Bool) {
        guard isEnabled, let g = geometry else {
            updateMinimap()
            return
        }
        var s = state
        Fitting.fitStrip(&s, limits: sizeLimits, g, config)
        s.scrollOffset = Layout.clampOffset(s.scrollOffset, s, g, config)
        state = s
        let placements = Layout.placements(s, g, config, limits: sizeLimits)

        if animated {
            var current: [WindowID: CGRect] = [:]
            for p in placements { current[p.id] = applied[p.id] ?? tracker.known[p.id]?.frame }
            let (tweens, jumps) = makeTweens(from: current, to: placements, wasVisible: { [visibility] id in visibility[id] == .visible })
            apply(Dictionary(jumps.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first }))
            animator.run(tweens)
        } else {
            animator.stop()
            apply(Dictionary(placements.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first }))
            scheduleSizeCheck()
        }
        for p in placements { visibility[p.id] = p.visibility }
        refreshEdgeGuards()
        updateMinimap()
    }

    // MARK: Making sure windows really took their frames

    /// Apps answer a move or resize a moment later; check the real frames once things settle.
    private func scheduleSizeCheck() {
        sizeCheckTimer?.invalidate()
        sizeCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            self?.settle(round: 0, timesBigger: [:])
        }
    }

    /// Compares every visible window's real frame with the one Filmstrip gave it, and gives a
    /// window that did not take its frame (macOS cut it short, the app was busy, it was
    /// parked off screen when the size was sent) its frame again, for a few rounds.
    ///
    /// Only a window that is still bigger than asked after being told again and again has a
    /// real minimum size (WhatsApp, Spotify). That is remembered, and the strip makes room
    /// for it so windows do not overlap. A window that comes out smaller is never taken to
    /// have a maximum, so windows keep reaching full height.
    private func settle(round: Int, timesBigger: [WindowID: Int]) {
        guard isEnabled, !animator.isRunning else { return }
        guard NSEvent.pressedMouseButtons == 0 else { // not while the user drags something
            scheduleSizeCheck()
            return
        }
        let maxRounds = 4
        var retry: [(TrackedWindow, CGRect)] = []
        var stillBigger: [WindowID: Int] = [:]
        var learned = false

        for (id, target) in applied where visibility[id] == .visible {
            guard let window = tracker.known[id], let actual = window.frame else { continue }
            let wider = actual.width > target.width + 2
            let taller = actual.height > target.height + 2
            if wider || taller {
                let count = (timesBigger[id] ?? 0) + 1
                if count >= 3 {
                    var limit = sizeLimits[id] ?? SizeLimits()
                    if wider { limit.minWidth = max(limit.minWidth, Double(actual.width)) }
                    if taller { limit.minHeight = max(limit.minHeight, Double(actual.height)) }
                    sizeLimits[id] = limit
                    learned = true
                } else {
                    stillBigger[id] = count
                    retry.append((window, target))
                }
                continue
            }
            let off = abs(actual.minX - target.minX) > 2 || abs(actual.minY - target.minY) > 2
            let short = actual.width < target.width - 2 || actual.height < target.height - 2
            if off || short { retry.append((window, target)) }
        }

        if learned {
            relayout(animated: true)
            return
        }
        guard !retry.isEmpty, round < maxRounds else { return }
        let echoUntil = now + 0.3
        for (window, target) in retry {
            ownChangeUntil[window.id] = echoUntil
            WindowMover.withEnhancedUIDisabled(pid: window.pid) {
                _ = WindowMover.setFrame(window, target, resize: true)
            }
        }
        sizeCheckTimer?.invalidate()
        sizeCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.settle(round: round + 1, timesBigger: stillBigger)
        }
    }

    /// Moves windows to the given frames, skipping the ones already there.
    private func apply(_ frames: [WindowID: CGRect]) {
        var gone: [WindowID] = []
        var byApp: [pid_t: [(TrackedWindow, CGRect)]] = [:]
        for (id, frame) in frames {
            guard let window = tracker.known[id] else { gone.append(id); continue }
            if let last = applied[id], abs(last.minX - frame.minX) < 0.5, abs(last.minY - frame.minY) < 0.5, last.size == frame.size {
                continue
            }
            byApp[window.pid, default: []].append((window, frame))
        }
        let echoUntil = now + 0.3
        for (pid, items) in byApp {
            WindowMover.withEnhancedUIDisabled(pid: pid) {
                for (window, frame) in items {
                    let resize = applied[window.id]?.size != frame.size
                    ownChangeUntil[window.id] = echoUntil
                    if WindowMover.setFrame(window, frame, resize: resize) {
                        applied[window.id] = frame
                    } else {
                        gone.append(window.id)
                    }
                }
            }
        }
        if !gone.isEmpty {
            DispatchQueue.main.async { [weak self] in gone.forEach { self?.windowGone($0) } }
        }
        refreshEdgeGuards()
    }

    /// Puts the edge guards over the windows that are on screen now, so their top and bottom
    /// edges cannot be dragged and windows always keep full height.
    private func refreshEdgeGuards() {
        guard isEnabled else {
            edgeGuards.removeAll()
            return
        }
        var frames: [WindowID: CGRect] = [:]
        for id in state.windowIDs where visibility[id] == .visible {
            if let frame = applied[id] { frames[id] = frame }
        }
        edgeGuards.update(frames)
    }

    private func focusCurrent() {
        guard let id = state.focusedWindow, let window = tracker.known[id] else { return }
        ignoreFocusUntil = now + 0.35
        tracker.focus(window)
    }

    // MARK: Minimap

    private func updateMinimap() {
        guard let screen = Displays.managedScreen, let g = geometry else { return }
        let layout = Minimap.layout(state, g, config, maxWidth: MinimapController.maxContentWidth(on: screen), maxScale: minimap.maxScale)
        var icons: [WindowID: NSImage] = [:]
        for id in state.windowIDs {
            guard let pid = tracker.known[id]?.pid else { continue }
            if iconCache[pid] == nil {
                iconCache[pid] = NSRunningApplication(processIdentifier: pid)?.icon
            }
            icons[id] = iconCache[pid]
        }
        minimap.update(layout: layout, icons: icons, screen: screen, active: isEnabled)
    }

    // MARK: Settings

    private enum Key {
        static let gap = "gap"
        static let outerGap = "outerGap"
        static let centerMode = "centerMode"
        static let minimapMode = "minimapMode"
        static let minimapSize = "minimapSize"
        static let invertScroll = "invertScroll"
        static let windowsUnderMinimap = "windowsUnderMinimap"
    }

    private var isLoadingSettings = false

    private func loadSettings() {
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Key.gap) != nil { config.gap = defaults.double(forKey: Key.gap) }
        if defaults.object(forKey: Key.outerGap) != nil { config.outerGap = defaults.double(forKey: Key.outerGap) }
        if let raw = defaults.string(forKey: Key.centerMode), let mode = CenterMode(rawValue: raw) { config.centerMode = mode }
        if let raw = defaults.string(forKey: Key.minimapMode), let mode = MinimapMode(rawValue: raw) { minimapMode = mode }
        if let raw = defaults.string(forKey: Key.minimapSize), let size = MinimapSize(rawValue: raw) { minimapSize = size }
        invertScroll = defaults.bool(forKey: Key.invertScroll)
        windowsUnderMinimap = defaults.bool(forKey: Key.windowsUnderMinimap)
    }

    func saveSettings() {
        // Setting one value while loading must not overwrite the others still to be loaded.
        guard !isLoadingSettings else { return }
        let defaults = UserDefaults.standard
        defaults.set(config.gap, forKey: Key.gap)
        defaults.set(config.outerGap, forKey: Key.outerGap)
        defaults.set(config.centerMode.rawValue, forKey: Key.centerMode)
        defaults.set(minimapMode.rawValue, forKey: Key.minimapMode)
        defaults.set(minimapSize.rawValue, forKey: Key.minimapSize)
        defaults.set(invertScroll, forKey: Key.invertScroll)
        defaults.set(windowsUnderMinimap, forKey: Key.windowsUnderMinimap)
    }

    func setGap(_ gap: Double) {
        config.gap = gap
        config.outerGap = gap
        saveSettings()
        usableAreaChanged()
    }

    func setCenterMode(_ mode: CenterMode) {
        config.centerMode = mode
        saveSettings()
        guard let g = geometry else { return }
        var s = state
        reveal(&s, g)
        state = s
        relayout(animated: true)
    }

    /// The room windows get changed. Sizes learned for the old room may no longer hold
    /// (and one learned by mistake should not stick), so they are learned again.
    private func usableAreaChanged(animated: Bool = true) {
        sizeLimits.removeAll()
        relayout(animated: animated)
    }

    /// Keeps the strip's order, picks up windows Filmstrip missed and puts every window back
    /// in its place (also ones the user dragged around by hand).
    func rescan() {
        guard isEnabled else { return }
        sizeLimits.removeAll()
        applied.removeAll()
        visibility.removeAll()
        reconcile(focusFrontmost: true)
    }
}
