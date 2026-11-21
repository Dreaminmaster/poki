import SwiftUI
import UIKit

/// The launch screen, kept over the app's first frame and let go: the bear sinks out along the bottom
/// edge, the word fades as it lifts, and the picture of the home page's light fades into the light
/// itself, which stands under it at rest in the same place. It is the launch storyboard's own view, so
/// the first frame is the launch screen to the pixel, on every screen size.
///
/// With Reduce Motion everything fades together and nothing moves.
struct LaunchCurtain: UIViewRepresentable {
    var firstFrame: (CFTimeInterval) -> Void
    var done: () -> Void

    /// The storyboard's pictures, by their tags in LaunchScreen.storyboard.
    enum Part: Int { case backdrop = 1, word, bear }

    func makeUIView(context: Context) -> Stage {
        let stage = Stage(firstFrame: firstFrame, done: done)
        if let scene = UIStoryboard(name: "LaunchScreen", bundle: .main).instantiateInitialViewController()?.view {
            scene.frame = stage.bounds
            scene.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            stage.addSubview(scene)
        }
        return stage
    }

    func updateUIView(_ stage: Stage, context: Context) {}

    final class Stage: UIView {
        private var firstFrame: ((CFTimeInterval) -> Void)?
        private let done: () -> Void
        private var started = false
        private var transitionFinished = false
        private var attachedAt: CFTimeInterval = 0
        private var displayLink: CADisplayLink?

        init(firstFrame: @escaping (CFTimeInterval) -> Void, done: @escaping () -> Void) {
            self.firstFrame = firstFrame
            self.done = done
            super.init(frame: UIScreen.main.bounds)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        private func part(_ part: Part) -> UIView? { viewWithTag(part.rawValue) }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            displayLink?.invalidate()
            displayLink = nil
            guard window != nil else { return }
            if firstFrame != nil {
                attachedAt = CACurrentMediaTime()
                let link = CADisplayLink(target: self, selector: #selector(frameDisplayed))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            guard !started else { return }
            started = true
            // The first frame goes up as the launch screen was; the curtain starts on the next one.
            DispatchQueue.main.async { self.open() }
        }

        @objc private func frameDisplayed(_ link: CADisplayLink) {
            // The timestamp is for the previous refresh. Wait for one after the curtain was attached.
            guard link.timestamp >= attachedAt else { return }
            link.invalidate()
            displayLink = nil
            let report = firstFrame
            firstFrame = nil
            report?(link.timestamp)
            if transitionFinished { done() }
        }

        private func open() {
            layoutIfNeeded()
            let finish: (UIViewAnimatingPosition) -> Void = { [weak self] _ in
                guard let self else { return }
                self.transitionFinished = true
                if self.firstFrame == nil { self.done() }
            }
            if UIAccessibility.isReduceMotionEnabled {
                let fade = UIViewPropertyAnimator(duration: LaunchMotion.fade, curve: .easeInOut) { self.alpha = 0 }
                fade.addCompletion(finish)
                fade.startAnimation(afterDelay: LaunchMotion.hold)
                return
            }
            let bear = part(.bear), word = part(.word), backdrop = part(.backdrop)
            let sink = UIViewPropertyAnimator(duration: LaunchMotion.sink, curve: .easeIn) {
                bear?.transform = CGAffineTransform(translationX: 0, y: (bear?.bounds.height ?? 0) + 8)
            }
            let lift = UIViewPropertyAnimator(duration: LaunchMotion.lift, curve: .easeOut) {
                word?.transform = CGAffineTransform(translationX: 0, y: -LaunchMotion.wordRise)
                word?.alpha = 0
            }
            let reveal = UIViewPropertyAnimator(duration: LaunchMotion.reveal, curve: .easeInOut) {
                backdrop?.alpha = 0
                self.backgroundColor = .clear
                self.subviews.first?.backgroundColor = .clear
            }
            reveal.addCompletion(finish)
            sink.startAnimation(afterDelay: LaunchMotion.hold)
            lift.startAnimation(afterDelay: LaunchMotion.hold)
            reveal.startAnimation(afterDelay: LaunchMotion.hold + LaunchMotion.revealDelay)
        }
    }
}

/// The curtain's timing, in seconds, and how far the word lifts, in points.
enum LaunchMotion {
    /// The launch screen held still before anything moves.
    static let hold = 0.12
    static let sink = 0.55
    static let lift = 0.25
    static let wordRise: CGFloat = 12
    /// The light's picture starts to fade once the word is gone and the bear is under way, so the word
    /// is never seen over the home page's picture of Poki, nor the bear sinking through a page that is
    /// already changing.
    static let revealDelay = 0.25
    static let reveal = 0.4
    /// With Reduce Motion, the whole launch screen fades out.
    static let fade = 0.3
}
