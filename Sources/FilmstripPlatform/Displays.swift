import AppKit
import CoreGraphics

// Private CoreGraphics (SkyLight) calls. They have been stable for many macOS releases
// and are kept in this one file so a breaking change stays contained.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ connection: Int32) -> UInt64

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: Int32, _ mask: Int32, _ windowIDs: CFArray) -> CFArray

public enum Displays {

    /// Height of the primary display (the one with the menu bar), the reference for flipping
    /// between AppKit coordinates (origin bottom left) and Accessibility coordinates (origin top left).
    public static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// AppKit rect → Accessibility rect.
    public static func toAX(_ rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Accessibility rect → AppKit rect.
    public static func toAppKit(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The display Filmstrip manages in this version: the one with the menu bar.
    public static var managedScreen: NSScreen? {
        NSScreen.screens.first
    }

    /// Identifier of the Space currently shown, or 0 when it cannot be read.
    public static func activeSpaceID() -> UInt64 {
        CGSGetActiveSpace(CGSMainConnectionID())
    }

    /// The Spaces a window belongs to. Empty when macOS does not say.
    public static func spaceIDs(of windowID: UInt32) -> [UInt64] {
        let ids = [NSNumber(value: windowID)] as CFArray
        let result = CGSCopySpacesForWindows(CGSMainConnectionID(), 0x7, ids) as? [NSNumber] ?? []
        return result.map(\.uint64Value)
    }

    /// Whether a window is on the Space being shown. Works for windows parked off screen too,
    /// which the on-screen window list may leave out.
    public static func isOnActiveSpace(_ windowID: UInt32, onScreen: Set<UInt32>) -> Bool {
        let spaces = spaceIDs(of: windowID)
        if spaces.isEmpty { return onScreen.contains(windowID) }
        return spaces.contains(activeSpaceID())
    }

    /// Whether a window belongs to the managed display. A window parked at its edge (only a
    /// sliver on screen, centre off every display) still counts.
    public static func belongsToManagedScreen(_ frame: CGRect) -> Bool {
        guard let managed = managedScreen else { return false }
        let managedFrame = toAX(managed.frame)
        guard managedFrame.insetBy(dx: -2, dy: 0).intersects(frame) else { return false }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if managedFrame.contains(center) { return true }
        let elsewhere = NSScreen.screens.dropFirst().contains { toAX($0.frame).contains(center) }
        return !elsewhere
    }

    /// IDs of all windows macOS reports as on screen on the current Space.
    public static func onScreenWindowIDs() -> Set<UInt32> {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var ids = Set<UInt32>()
        for entry in info {
            if let number = entry[kCGWindowNumber as String] as? NSNumber {
                ids.insert(number.uint32Value)
            }
        }
        return ids
    }
}
