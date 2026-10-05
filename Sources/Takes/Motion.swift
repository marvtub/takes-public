import AppKit
import SwiftUI

// Endless animations (spinners, the thinking dots, the REC pulse) run as Core Animation layer
// animations, in the window server, not in SwiftUI. A SwiftUI repeatForever animation renders the
// whole window again on every frame: one chat spinner cost ~19% of a CPU core while Takes sat idle
// (sample, 2026-10-01), and the REC pulse did the same during a recording. These cost the main
// thread nothing while they run. They never take clicks: the button around them gets them.

/// A thin arc that turns.
struct LayerSpinner: NSViewRepresentable {
    var color: Color
    var alpha: CGFloat = 1
    var lineWidth: CGFloat = 2
    var inset: CGFloat = 2
    /// The part of the circle drawn, 0...1.
    var length: CGFloat = 0.28

    func makeNSView(context: Context) -> SpinnerView { SpinnerView() }

    func updateNSView(_ v: SpinnerView, context: Context) {
        v.color = NSColor(color)
        v.alpha = alpha
        v.lineWidth = lineWidth
        v.inset = inset
        v.length = length
        v.needsLayout = true
    }

    final class SpinnerView: NSView {
        var color: NSColor = .gray
        var alpha: CGFloat = 1
        var lineWidth: CGFloat = 2
        var inset: CGFloat = 2
        var length: CGFloat = 0.28
        private let arc = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            arc.fillColor = nil
            arc.lineCap = .round
            layer?.addSublayer(arc)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arc.frame = bounds
            let d = inset + lineWidth / 2
            arc.path = CGPath(ellipseIn: bounds.insetBy(dx: d, dy: d), transform: nil)
            arc.lineWidth = lineWidth
            arc.strokeEnd = length
            arc.strokeColor = Motion.cg(color, alpha, in: self)
            CATransaction.commit()
            spin()
        }

        override func viewDidMoveToWindow() { spin() }
        override func viewDidChangeEffectiveAppearance() { needsLayout = true }

        /// Removed when the view leaves its window; added again when it comes back.
        private func spin() {
            guard window != nil, arc.animation(forKey: "spin") == nil else { return }
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0
            a.toValue = -2 * Double.pi  // clockwise: layer y points up
            a.duration = 0.9
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            arc.add(a, forKey: "spin")
        }
    }
}

/// A dot that fades between full and `low` opacity. `delay` staggers dots in a row.
struct LayerPulse: NSViewRepresentable {
    var color: Color
    var low: Float = 0.3
    var duration: Double = 0.6
    var delay: Double = 0

    func makeNSView(context: Context) -> PulseView { PulseView() }

    func updateNSView(_ v: PulseView, context: Context) {
        v.color = NSColor(color)
        v.low = low
        v.duration = duration
        v.delay = delay
        v.needsLayout = true
    }

    final class PulseView: NSView {
        var color: NSColor = .gray
        var low: Float = 0.3
        var duration: Double = 0.6
        var delay: Double = 0
        private let dot = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(dot)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.frame = bounds
            dot.path = CGPath(ellipseIn: bounds, transform: nil)
            dot.fillColor = Motion.cg(color, 1, in: self)
            CATransaction.commit()
            pulse()
        }

        override func viewDidMoveToWindow() { pulse() }
        override func viewDidChangeEffectiveAppearance() { needsLayout = true }

        private func pulse() {
            guard window != nil, dot.animation(forKey: "pulse") == nil else { return }
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = low
            a.toValue = 1
            a.duration = duration
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.beginTime = CACurrentMediaTime() + delay
            a.fillMode = .backwards
            a.isRemovedOnCompletion = false
            dot.add(a, forKey: "pulse")
        }
    }
}

enum Motion {
    /// A theme color (light and dark) as the CGColor for this view's appearance now.
    static func cg(_ color: NSColor, _ alpha: CGFloat, in view: NSView) -> CGColor {
        var out = color.withAlphaComponent(color.alphaComponent * alpha).cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            out = color.withAlphaComponent(color.alphaComponent * alpha).cgColor
        }
        return out
    }
}

/// The mascot, alive (2026-10-02). It breathes and blinks when idle, looks around while it thinks,
/// bounces and talks while it writes, and squints at its work while tools run. The body
/// (Brand/mascot-body.png: the mascot with its face painted out) and the face are separate layers,
/// so the face can move. Layer animations, like the spinner: they cost the main thread nothing.
struct LiveMascot: View {
    enum Mood: Equatable { case idle, thinking, writing, working }
    var mood: Mood = .idle
    var size: CGFloat = 32

    var body: some View {
        MascotLayers(mood: mood).frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct MascotLayers: NSViewRepresentable {
    var mood: LiveMascot.Mood
    func makeNSView(context: Context) -> MascotView { MascotView() }
    func updateNSView(_ v: MascotView, context: Context) { v.mood = mood }
}

final class MascotView: NSView {
    nonisolated(unsafe) static var bodyImage: CGImage? = Bundle.main.resourceURL
        .flatMap { NSImage(contentsOf: $0.appending(path: "Brand/mascot-body.png")) }?
        .cgImage(forProposedRect: nil, context: nil, hints: nil)
    /// The face's navy, sampled from the mascot.
    static let ink = CGColor(red: 0x18 / 255, green: 0x29 / 255, blue: 0x4E / 255, alpha: 1)

    var mood: LiveMascot.Mood = .idle { didSet { if mood != oldValue { animate() } } }

    private let blob = CALayer(), body = CALayer(), face = CALayer()
    private let eyes = [CAShapeLayer(), CAShapeLayer()]
    private let smile = CAShapeLayer(), mouth = CAShapeLayer()
    private var side: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(blob)
        blob.addSublayer(body)
        blob.addSublayer(face)
        body.contents = Self.bodyImage
        body.contentsGravity = .resizeAspect
        for e in eyes {
            e.fillColor = Self.ink
            let shine = CAShapeLayer()
            shine.fillColor = CGColor(gray: 1, alpha: 0.32)
            e.addSublayer(shine)
            face.addSublayer(e)
        }
        smile.fillColor = nil
        smile.strokeColor = Self.ink
        smile.lineCap = .round
        mouth.fillColor = Self.ink
        mouth.opacity = 0
        face.addSublayer(smile)
        face.addSublayer(mouth)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // Shapes in the mascot's own units: 0...1 from the top left of the square image.
    override func layout() {
        super.layout()
        let s = min(bounds.width, bounds.height)
        guard s > 0, s != side else { return }
        side = s
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: (1 - y) * s) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blob.bounds = CGRect(x: 0, y: 0, width: s, height: s)
        blob.anchorPoint = CGPoint(x: 0.5, y: 0.03)  // its bottom: it squashes and rocks on the ground
        blob.position = CGPoint(x: bounds.midX, y: bounds.midY - s / 2 + 0.03 * s)
        body.frame = blob.bounds
        face.frame = blob.bounds
        let eye = CGSize(width: 0.116 * s, height: 0.174 * s)
        for (e, x) in zip(eyes, [0.314, 0.682] as [CGFloat]) {
            e.bounds = CGRect(origin: .zero, size: eye)
            e.position = p(x, 0.635)
            e.path = CGPath(ellipseIn: e.bounds, transform: nil)
            let shine = e.sublayers?.first as? CAShapeLayer
            shine?.path = CGPath(ellipseIn: CGRect(x: eye.width * 0.48, y: eye.height * 0.6,
                                                   width: eye.width * 0.3, height: eye.height * 0.24), transform: nil)
        }
        smile.frame = face.bounds
        let path = CGMutablePath()
        path.move(to: p(0.428, 0.703))
        path.addQuadCurve(to: p(0.568, 0.703), control: p(0.498, 0.762))
        smile.path = path
        smile.lineWidth = 0.036 * s
        mouth.bounds = CGRect(x: 0, y: 0, width: 0.1 * s, height: 0.08 * s)
        mouth.position = p(0.498, 0.722)
        mouth.path = CGPath(roundedRect: mouth.bounds, cornerWidth: 0.05 * s, cornerHeight: 0.04 * s, transform: nil)
        CATransaction.commit()
        animate()
    }

    override func viewDidMoveToWindow() { animate() }

    private func animate() {
        guard side > 0 else { return }
        let s = side
        for l in [blob, face, smile, mouth] + eyes { l.removeAllAnimations() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        smile.opacity = mood == .writing ? 0 : 1
        mouth.opacity = mood == .writing ? 1 : 0
        // Thinking and working: the mouth goes small, a "hmm".
        smile.transform = mood == .thinking || mood == .working
            ? CATransform3DMakeScale(0.55, 1, 1) : CATransform3DIdentity
        face.setValue(mood == .working ? -0.02 * s : 0, forKeyPath: "transform.translation.y")
        CATransaction.commit()
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let squint: CGFloat = mood == .working ? 0.78 : 1
        for (i, e) in eyes.enumerated() {
            let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
            a.values = [squint, squint, 0.08, squint, squint]
            a.keyTimes = [0, 0.92, 0.95, 0.98, 1]
            a.duration = mood == .idle ? 4.2 : 3.1
            a.repeatCount = .infinity
            a.beginTime = CACurrentMediaTime() + 0.6 + Double(i) * 0.015
            a.fillMode = .backwards
            e.add(a, forKey: "blink")
        }

        switch mood {
        case .idle:
            loop(blob, "transform.scale.x", from: 1, to: 1.02, 1.4)
            loop(blob, "transform.scale.y", from: 1, to: 0.975, 1.4)
        case .thinking:
            let look = CAKeyframeAnimation(keyPath: "transform.translation.x")
            look.values = [0, -0.04 * s, -0.04 * s, 0.04 * s, 0.04 * s, 0]
            look.keyTimes = [0, 0.12, 0.42, 0.55, 0.88, 1]
            look.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 5)
            look.duration = 3.4
            look.repeatCount = .infinity
            face.add(look, forKey: "look")
            loop(face, "transform.translation.y", from: 0.015 * s, to: 0.03 * s, 1.7)
            loop(blob, "transform.rotation.z", from: -0.045, to: 0.045, 1.7)
        case .writing:
            let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
            hop.values = [0, 0.07 * s, 0]
            hop.keyTimes = [0, 0.45, 1]
            hop.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
            let sy = CAKeyframeAnimation(keyPath: "transform.scale.y")
            sy.values = [0.93, 1.04, 0.93]
            let sx = CAKeyframeAnimation(keyPath: "transform.scale.x")
            sx.values = [1.05, 0.98, 1.05]
            let g = CAAnimationGroup()
            g.animations = [hop, sy, sx]
            g.duration = 0.62
            g.repeatCount = .infinity
            blob.add(g, forKey: "hop")
            let talk = CAKeyframeAnimation(keyPath: "transform.scale.y")
            talk.values = [0.35, 1, 0.5, 0.9, 0.35]
            talk.duration = 0.5
            talk.repeatCount = .infinity
            mouth.add(talk, forKey: "talk")
        case .working:
            loop(face, "transform.translation.x", from: -0.025 * s, to: 0.025 * s, 0.8)
            loop(blob, "transform.rotation.z", from: -0.025, to: 0.025, 0.4)
        }
    }

    private func loop(_ l: CALayer, _ key: String, from: CGFloat, to: CGFloat, _ duration: Double) {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        l.add(a, forKey: key)
    }
}

extension ClaudeChat {
    /// What the mascot does: what the chat is doing now. Views read the stored `mood`.
    var currentMood: LiveMascot.Mood {
        if running && compacting { return .thinking }
        return LiveMascot.mood(running: running, last: messages.last)
    }
}

extension LiveMascot {
    /// Working on a tool, writing a reply, or thinking: from the newest message of a running chat.
    static func mood(running: Bool, last: ChatMessage?) -> Mood {
        guard running else { return .idle }
        switch last {
        case let m? where m.role == .tool && !m.done: return .working
        case let m? where m.role == .claude && !m.done: return .writing
        default: return .thinking
        }
    }
}
