import Foundation
import CoreGraphics

public enum Easing {
    /// Fast start, gentle stop. `t` runs from 0 to 1.
    public static func easeOutCubic(_ t: Double) -> Double {
        let c = min(max(t, 0), 1)
        let inv = 1 - c
        return 1 - inv * inv * inv
    }
}

/// One window moving from one frame to another.
public struct FrameTween: Equatable, Sendable {
    public var id: WindowID
    public var from: CGRect
    public var to: CGRect

    public init(id: WindowID, from: CGRect, to: CGRect) {
        self.id = id
        self.from = from
        self.to = to
    }

    /// The frame at progress `t` (0...1, already eased). Only the horizontal position
    /// animates, the way the strip scrolls. The top edge and the size jump to the target at
    /// once: resizing every frame makes apps lay themselves out again and stutter, and a
    /// window resized while it still sits low on the screen gets cut short by macOS.
    public func frame(at t: Double) -> CGRect {
        let x = Double(from.minX) + (Double(to.minX) - Double(from.minX)) * t
        return CGRect(x: x.rounded(), y: to.minY, width: to.width, height: to.height)
    }
}

/// Decides which windows animate. A window that stays parked off screen just jumps;
/// everything that is visible at the start or at the end slides.
public func makeTweens(from current: [WindowID: CGRect], to targets: [Placement], wasVisible: (WindowID) -> Bool) -> (tweens: [FrameTween], jumps: [Placement]) {
    var tweens: [FrameTween] = []
    var jumps: [Placement] = []
    for p in targets {
        guard let start = current[p.id] else {
            jumps.append(p)
            continue
        }
        if p.visibility == .visible || wasVisible(p.id) {
            if start != p.frame { tweens.append(FrameTween(id: p.id, from: start, to: p.frame)) }
        } else {
            jumps.append(p)
        }
    }
    return (tweens, jumps)
}
