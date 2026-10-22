import AppKit
import ApplicationServices

public enum WindowMover {

    private static let enhancedUI = "AXEnhancedUserInterface"

    /// Moves a window and, when `resize` is set, resizes it.
    /// Returns false when the window no longer exists.
    @discardableResult
    public static func setFrame(_ window: TrackedWindow, _ frame: CGRect, resize: Bool) -> Bool {
        // Move first: macOS cuts a window short when it is made taller while it still sits
        // low on the screen. Then size, then position again, because some apps nudge their
        // window while they resize.
        let error = AX.setPosition(window.element, frame.origin)
        guard error != .invalidUIElement else { return false }
        if resize {
            AX.setSize(window.element, frame.size)
            AX.setPosition(window.element, frame.origin)
        }
        return true
    }

    /// Runs `body` with the app's "enhanced user interface" switched off. While it is on
    /// (Chrome and Electron apps turn it on when an assistive app is around), every move
    /// is animated by the app itself and frames lag behind.
    public static func withEnhancedUIDisabled<T>(pid: pid_t, _ body: () -> T) -> T {
        let app = AXUIElementCreateApplication(pid)
        let wasOn = AX.bool(app, enhancedUI) == true
        if wasOn { AX.setBool(app, enhancedUI, false) }
        defer { if wasOn { AX.setBool(app, enhancedUI, true) } }
        return body()
    }
}
