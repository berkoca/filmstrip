import Foundation
import QuartzCore
import FilmstripCore

/// Drives window slides at display rate. Each tick hands the current frames to `apply`.
final class FrameAnimator {

    var duration: CFTimeInterval = 0.18
    var apply: (([WindowID: CGRect]) -> Void)?
    var onFinish: (() -> Void)?

    private var tweens: [FrameTween] = []
    private var startTime: CFTimeInterval = 0
    private var timer: Timer?

    var isRunning: Bool { timer != nil }

    func run(_ tweens: [FrameTween]) {
        self.tweens = tweens
        guard !tweens.isEmpty else { stop(); onFinish?(); return }
        startTime = CACurrentMediaTime()
        if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tweens = []
    }

    private func tick() {
        let elapsed = CACurrentMediaTime() - startTime
        let progress = duration > 0 ? min(1, elapsed / duration) : 1
        let eased = Easing.easeOutCubic(progress)
        var frames: [WindowID: CGRect] = [:]
        for tween in tweens { frames[tween.id] = tween.frame(at: eased) }
        apply?(frames)
        if progress >= 1 {
            stop()
            onFinish?()
        }
    }
}
