import AppKit
import CoreGraphics

/// Everything a shortcut can ask the window manager to do.
public enum Action: Equatable {
    case focusLeft, focusRight, focusUp, focusDown, focusFirst, focusLast
    case focusIndex(Int)
    case moveLeft, moveRight, moveUp, moveDown
    case stackIntoLeft, stackIntoRight, unstackRight, unstackLeft
    case cycleWidth, fullWidth, center, wider, narrower
    case toggleFloat, toggleEnabled, toggleMinimap
}

/// Physical key codes (they name the key position on a US layout; other layouts keep the positions).
enum KeyCode {
    static let left: Int64 = 123, right: Int64 = 124, down: Int64 = 125, up: Int64 = 126
    static let h: Int64 = 4, j: Int64 = 38, k: Int64 = 40, l: Int64 = 37
    static let r: Int64 = 15, f: Int64 = 3, c: Int64 = 8, t: Int64 = 17, q: Int64 = 12, m: Int64 = 46
    static let equal: Int64 = 24, minus: Int64 = 27
    static let leftBracket: Int64 = 33, rightBracket: Int64 = 30
    static let digits: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
}

/// The default bindings. Every one of them is held together with Control-Option (⌃⌥).
public enum Bindings {
    public static func action(keyCode: Int64, shift: Bool, command: Bool) -> Action? {
        if command {
            switch keyCode {
            case KeyCode.left, KeyCode.h: return .focusFirst
            case KeyCode.right, KeyCode.l: return .focusLast
            default: return nil
            }
        }
        if let n = KeyCode.digits[keyCode], !shift { return .focusIndex(n) }
        switch (keyCode, shift) {
        case (KeyCode.left, false), (KeyCode.h, false): return .focusLeft
        case (KeyCode.right, false), (KeyCode.l, false): return .focusRight
        case (KeyCode.up, false), (KeyCode.k, false): return .focusUp
        case (KeyCode.down, false), (KeyCode.j, false): return .focusDown
        case (KeyCode.left, true), (KeyCode.h, true): return .moveLeft
        case (KeyCode.right, true), (KeyCode.l, true): return .moveRight
        case (KeyCode.up, true), (KeyCode.k, true): return .moveUp
        case (KeyCode.down, true), (KeyCode.j, true): return .moveDown
        case (KeyCode.rightBracket, false): return .stackIntoLeft
        case (KeyCode.leftBracket, false): return .stackIntoRight
        case (KeyCode.rightBracket, true): return .unstackRight
        case (KeyCode.leftBracket, true): return .unstackLeft
        case (KeyCode.r, false): return .cycleWidth
        case (KeyCode.f, false): return .fullWidth
        case (KeyCode.c, false): return .center
        case (KeyCode.equal, false): return .wider
        case (KeyCode.minus, false): return .narrower
        case (KeyCode.t, false): return .toggleFloat
        case (KeyCode.q, false): return .toggleEnabled
        case (KeyCode.m, false): return .toggleMinimap
        default: return nil
        }
    }

    /// Human-readable list for the Shortcuts window.
    public static let reference: [(keys: String, action: String)] = [
        ("⌃⌥ ← →  or  H L", "Focus left / right"),
        ("⌃⌥ ↑ ↓  or  K J", "Focus up / down in a stack"),
        ("⌃⌥⇧ ← →", "Move window left / right"),
        ("⌃⌥⇧ ↑ ↓", "Move window up / down in a stack"),
        ("⌃⌥⌘ ← →", "First / last window"),
        ("⌃⌥ 1 … 9", "Jump to window 1–9"),
        ("⌃⌥ + scroll", "Scroll the strip"),
        ("⌃⌥ R", "Cycle width"),
        ("⌃⌥ F", "Full width"),
        ("⌃⌥ C", "Centre the window"),
        ("⌃⌥ = / -", "Wider / narrower"),
        ("⌃⌥ ] / [", "Stack into left / right column"),
        ("⌃⌥⇧ ] / [", "Pop out to the right / left"),
        ("⌃⌥ T", "Float / unfloat"),
        ("⌃⌥ M", "Show / hide the minimap"),
        ("⌃⌥ Q", "Pause / resume Filmstrip"),
    ]
}

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<InputMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}

/// One event tap for shortcuts, ⌃⌥ + scroll, and noticing when ⌃⌥ is held.
/// Needs the Accessibility permission. Callbacks run on the main thread.
public final class InputMonitor {

    public var onAction: ((Action) -> Void)?
    /// Scroll distance in points; positive moves the viewport to the right.
    public var onScroll: ((Double) -> Void)?
    public var onModifiersHeld: ((Bool) -> Void)?
    /// When true, shortcuts and scrolling are ignored (except pause / resume).
    public var isPaused = false
    public var invertScroll = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var modifiersHeld = false

    public init() {}

    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.keyDown, .scrollWheel, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    public func stop() {
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a slow tap off; turn it straight back on.
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            let held = Self.isHyper(event.flags)
            if held != modifiersHeld {
                modifiersHeld = held
                DispatchQueue.main.async { [weak self] in self?.onModifiersHeld?(held) }
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            guard Self.isHyper(event.flags) else { return Unmanaged.passUnretained(event) }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            guard let action = Bindings.action(keyCode: keyCode, shift: flags.contains(.maskShift), command: flags.contains(.maskCommand)) else {
                return Unmanaged.passUnretained(event)
            }
            if isPaused && action != .toggleEnabled { return Unmanaged.passUnretained(event) }
            DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
            return nil // swallow the key so the app underneath does not see it

        case .scrollWheel:
            guard !isPaused, Self.isHyper(event.flags) else { return Unmanaged.passUnretained(event) }
            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let dy = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            let dx = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            var delta = -(abs(dx) > abs(dy) ? dx : dy)
            if !continuous { delta *= 4 } // a mouse wheel notch is only a few points
            if invertScroll { delta = -delta }
            if delta != 0 {
                DispatchQueue.main.async { [weak self] in self?.onScroll?(delta) }
            }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Control and Option held (Shift and Command may be added by a binding).
    static func isHyper(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskControl) && flags.contains(.maskAlternate)
    }
}
