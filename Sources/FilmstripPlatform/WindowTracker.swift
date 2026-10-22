import AppKit
import ApplicationServices
import FilmstripCore

/// A window Filmstrip has seen, with what is needed to move and focus it.
public struct TrackedWindow {
    public let id: WindowID
    public let pid: pid_t
    public let element: AXUIElement

    public var frame: CGRect? { AX.frame(element) }
    public var title: String { AX.string(element, kAXTitleAttribute) ?? "" }
}

/// C callback for every Accessibility observer. It must not capture anything, so the tracker
/// travels through `refcon`.
private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    tracker.handle(notification: notification as String, element: element)
}

/// Watches running apps and their windows through Accessibility and NSWorkspace,
/// and reports what changes. All callbacks arrive on the main thread.
public final class WindowTracker {

    public var onWindowCreated: ((TrackedWindow) -> Void)?
    public var onWindowDestroyed: ((WindowID) -> Void)?
    public var onWindowFocused: ((WindowID) -> Void)?
    public var onWindowMinimized: ((WindowID) -> Void)?
    public var onWindowRestored: ((TrackedWindow) -> Void)?
    /// A window changed size or position. Filmstrip's own moves are reported too; callers filter them.
    public var onWindowResized: ((WindowID) -> Void)?
    public var onWindowMoved: ((WindowID) -> Void)?
    public var onAppHidden: ((pid_t) -> Void)?
    public var onAppShown: ((pid_t) -> Void)?
    public var onAppTerminated: ((pid_t, [WindowID]) -> Void)?
    public var onSpaceChanged: (() -> Void)?

    public private(set) var known: [WindowID: TrackedWindow] = [:]

    private var observers: [pid_t: AXObserver] = [:]
    private var appElements: [pid_t: AXUIElement] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    public init() {}

    deinit { stop() }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    // MARK: Lifecycle

    public func start() {
        AX.setGlobalTimeout(1.0)
        for app in NSWorkspace.shared.runningApplications {
            track(app)
        }
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ handler: @escaping (NSRunningApplication?) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                handler(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            }
            workspaceTokens.append(token)
        }
        observe(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            guard let app else { return }
            // The app's first window may already exist by the time Filmstrip is listening;
            // `announce` reports it, since no "window created" news will come for it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.track(app, announce: true) }
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            let ids = self.untrack(app.processIdentifier)
            self.onAppTerminated?(app.processIdentifier, ids)
        }
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            if self.observers[app.processIdentifier] == nil { self.track(app, announce: true) }
            if let id = self.focusedWindowID(of: app.processIdentifier) { self.onWindowFocused?(id) }
        }
        observe(NSWorkspace.didHideApplicationNotification) { [weak self] app in
            if let app { self?.onAppHidden?(app.processIdentifier) }
        }
        observe(NSWorkspace.didUnhideApplicationNotification) { [weak self] app in
            if let app { self?.onAppShown?(app.processIdentifier) }
        }
        let spaceToken = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onSpaceChanged?()
        }
        workspaceTokens.append(spaceToken)
    }

    public func stop() {
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens.removeAll()
        for pid in Array(observers.keys) { _ = untrack(pid) }
    }

    // MARK: Apps

    private func track(_ app: NSRunningApplication, attempt: Int = 0, announce: Bool = false) {
        let pid = app.processIdentifier
        guard pid != ownPID, pid > 0, observers[pid] == nil, !app.isTerminated else { return }
        guard app.activationPolicy == .regular else {
            // Some apps switch to a regular (Dock) app only after they finish launching.
            if announce && attempt < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.track(app, attempt: attempt + 1, announce: announce)
                }
            }
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created else { return }

        var registered = false
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            let error = AXObserverAddNotification(observer, appElement, name as CFString, refcon)
            if error == .success || error == .notificationAlreadyRegistered { registered = true }
        }
        guard registered else {
            // Freshly launched apps often are not ready for Accessibility yet.
            if attempt < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.track(app, attempt: attempt + 1, announce: announce)
                }
            }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
        appElements[pid] = appElement
        if announce {
            for element in AX.elements(appElement, kAXWindowsAttribute) {
                considerNewWindow(element, attempt: 0)
            }
        }
    }

    /// Stops watching an app. Returns the IDs of its windows that were known.
    private func untrack(_ pid: pid_t) -> [WindowID] {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        appElements.removeValue(forKey: pid)
        let ids = known.values.filter { $0.pid == pid }.map(\.id)
        for id in ids { known.removeValue(forKey: id) }
        return ids
    }

    // MARK: Windows

    /// Whether a window should live on the strip: a normal, resizable, visible document window.
    /// Dialogs, sheets, panels, fixed-size windows and full-screen windows float.
    public func isManageable(_ element: AXUIElement) -> Bool {
        guard AX.string(element, kAXRoleAttribute) == kAXWindowRole else { return false }
        guard AX.string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole else { return false }
        if AX.bool(element, kAXMinimizedAttribute) == true { return false }
        if AX.bool(element, "AXFullScreen") == true { return false }
        guard AX.isSettable(element, kAXPositionAttribute), AX.isSettable(element, kAXSizeAttribute) else { return false }
        guard let size = AX.size(element), size.width >= 80, size.height >= 60 else { return false }
        return true
    }

    /// Starts watching a window for close / minimise / restore and remembers it.
    @discardableResult
    public func register(_ element: AXUIElement) -> TrackedWindow? {
        guard let id = AX.windowID(element), let pid = AX.pid(element) else { return nil }
        if let existing = known[id] { return existing }
        if let observer = observers[pid] {
            for name in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                         kAXWindowResizedNotification, kAXWindowMovedNotification] {
                AXObserverAddNotification(observer, element, name as CFString, refcon)
            }
        }
        let window = TrackedWindow(id: id, pid: pid, element: element)
        known[id] = window
        return window
    }

    public func forget(_ id: WindowID) {
        known.removeValue(forKey: id)
    }

    /// Manageable windows Accessibility reports for visible apps, in no particular order.
    /// Accessibility mostly lists windows of the current Space only; callers that need to be
    /// sure combine this with `Displays.onScreenWindowIDs()`.
    public func scanWindows() -> [TrackedWindow] {
        for app in NSWorkspace.shared.runningApplications where observers[app.processIdentifier] == nil {
            track(app)
        }
        var result: [TrackedWindow] = []
        for (pid, appElement) in appElements {
            if NSRunningApplication(processIdentifier: pid)?.isHidden == true { continue }
            for element in AX.elements(appElement, kAXWindowsAttribute) where isManageable(element) {
                if let window = register(element) { result.append(window) }
            }
        }
        return result
    }

    /// Manageable windows of one app (used when it is unhidden).
    public func windows(of pid: pid_t) -> [TrackedWindow] {
        guard let appElement = appElements[pid] else { return [] }
        return AX.elements(appElement, kAXWindowsAttribute).compactMap { element in
            isManageable(element) ? register(element) : nil
        }
    }

    public func focusedWindowID(of pid: pid_t) -> WindowID? {
        let appElement = appElements[pid] ?? AXUIElementCreateApplication(pid)
        guard let window = AX.element(appElement, kAXFocusedWindowAttribute) else { return nil }
        return AX.windowID(window)
    }

    /// The focused window of an app as a tracked window, if it is one Filmstrip should manage.
    /// Registers it when Filmstrip has not seen it before.
    public func focusedManageableWindow(of pid: pid_t) -> TrackedWindow? {
        let appElement = appElements[pid] ?? AXUIElementCreateApplication(pid)
        guard let element = AX.element(appElement, kAXFocusedWindowAttribute), isManageable(element) else { return nil }
        return register(element)
    }

    public func focusedWindowID() -> WindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return focusedWindowID(of: app.processIdentifier)
    }

    /// Brings a window to the front and gives it keyboard focus.
    public func focus(_ window: TrackedWindow) {
        AX.setBool(window.element, kAXMainAttribute, true)
        AX.raise(window.element)
        if let app = NSRunningApplication(processIdentifier: window.pid), !app.isActive {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    // MARK: Notifications

    fileprivate func handle(notification: String, element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            // A new window is often not fully set up yet; look at it a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.considerNewWindow(element, attempt: 0)
            }
        case kAXUIElementDestroyedNotification:
            if let id = known.first(where: { CFEqual($0.value.element, element) })?.key {
                known.removeValue(forKey: id)
                onWindowDestroyed?(id)
            }
        case kAXFocusedWindowChangedNotification:
            if let id = AX.windowID(element) { onWindowFocused?(id) }
        case kAXWindowMiniaturizedNotification:
            if let id = AX.windowID(element) { onWindowMinimized?(id) }
        case kAXWindowDeminiaturizedNotification:
            if let id = AX.windowID(element), let window = known[id] { onWindowRestored?(window) }
        case kAXWindowResizedNotification:
            if let id = AX.windowID(element), known[id] != nil { onWindowResized?(id) }
        case kAXWindowMovedNotification:
            if let id = AX.windowID(element), known[id] != nil { onWindowMoved?(id) }
        default:
            break
        }
    }

    private func considerNewWindow(_ element: AXUIElement, attempt: Int) {
        guard let id = AX.windowID(element), known[id] == nil else { return }
        if isManageable(element) {
            if let window = register(element) { onWindowCreated?(window) }
        } else if attempt < 10 {
            // Windows are often not finished yet (no size, no subrole) the moment they appear.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.considerNewWindow(element, attempt: attempt + 1)
            }
        }
    }
}
