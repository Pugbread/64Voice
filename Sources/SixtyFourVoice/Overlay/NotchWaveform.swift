import AppKit
import QuartzCore
import SwiftUI

// Per-frame visuals are plain Core Animation layers updated from the controller's display link. Nothing here
// invalidates SwiftUI, so SwiftUI/RenderBox never re-renders while the notch is just listening.

/// Waveform state: mic level smoothing, per-bar wobble, and the waveform ↔ three-dot morph. Main thread only.
final class NotchWaveformState {
    static let barCount = 9
    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 2.5
    static let minHeight: CGFloat = 3
    static let maxHeight: CGFloat = 22
    static let dotDiameter: CGFloat = 5.5
    static let dotPitch: CGFloat = 9
    static var size: CGSize {
        CGSize(width: CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing, height: maxHeight)
    }

    /// Latest raw mic level, 0...1.
    var level: Float = 0
    /// 0 = waveform, 1 = three-dot pulse.
    var morphTarget: CGFloat = 0
    var reduceMotion = false
    private(set) var morph: CGFloat = 0

    private var bars = [CGFloat](repeating: 0, count: barCount)
    private var lastTime: Double?
    private var views: [OverlayWeakRef<NotchWaveformLayerView>] = []
    private var frames = [CGRect](repeating: .zero, count: barCount)
    private var alphas = [Float](repeating: 1, count: barCount)

    // Bell-shaped envelope and per-bar wobble so the bars never move in lockstep.
    private let envelope: [CGFloat] = [0.42, 0.6, 0.78, 0.93, 1.0, 0.9, 0.76, 0.58, 0.4]
    private let freqA: [Double] = [7.3, 9.1, 6.2, 8.4, 10.3, 7.7, 9.6, 6.8, 8.9]
    private let freqB: [Double] = [3.1, 4.4, 2.7, 3.9, 2.3, 4.8, 3.3, 2.9, 4.1]
    private let phase: [Double] = [0.0, 1.7, 3.1, 0.9, 2.4, 4.0, 5.2, 1.2, 3.6]

    func attach(_ view: NotchWaveformLayerView) {
        views.removeAll { $0.value == nil || $0.value === view }
        views.append(OverlayWeakRef(view))
        if let lastTime { render(time: lastTime, advance: false) }
    }

    func detach(_ view: NotchWaveformLayerView) {
        views.removeAll { $0.value == nil || $0.value === view }
    }

    func reset() {
        level = 0
        bars = [CGFloat](repeating: 0, count: Self.barCount)
        lastTime = nil
    }

    func snapMorph() { morph = morphTarget }

    /// Advances the simulation to `time` and pushes bar geometry to the attached layers.
    func render(time: Double, advance: Bool = true) {
        let dt = advance ? min(max(time - (lastTime ?? time), 0), 1.0 / 20) : 0
        lastTime = time
        guard views.contains(where: { $0.value != nil }) else { return }

        // Morph eases toward its target (critically damped, ~110 ms).
        morph += (morphTarget - morph) * CGFloat(1 - exp(-dt / 0.11))
        if abs(morphTarget - morph) < 0.002 { morph = morphTarget }

        // The recorder already maps RMS dB (-50…-15) to 0…1, which is perceptual; use it nearly as is.
        let loudness = CGFloat(max(0, min(1, level * 1.05)))

        let n = Self.barCount
        let size = Self.size
        let midY = size.height / 2
        for i in 0..<n {
            let wobble = 0.62 + 0.38 * CGFloat(0.5 + 0.25 * sin(time * freqA[i] + phase[i])
                + 0.25 * sin(time * freqB[i] + phase[i] * 1.3))
            let target = loudness * envelope[i] * (reduceMotion ? 0.85 : wobble)
            let tau = target > bars[i] ? 0.05 : 0.16 // fast attack, slower release
            bars[i] += (target - bars[i]) * CGFloat(1 - exp(-dt / tau))

            // Silence: a calm ripple of dots so it still reads as "listening".
            let idle = reduceMotion ? 0 : 1.1 * CGFloat(0.5 + 0.5 * sin(time * 3.2 - Double(i) * 0.55))
            let barHeight = Self.minHeight + idle * max(0, 1 - bars[i] * 4) + (Self.maxHeight - Self.minHeight) * bars[i]
            let barX = CGFloat(i) * (Self.barWidth + Self.barSpacing) + Self.barWidth / 2

            // Three-dot pulse: the bars collapse into three groups.
            let dot = i * 3 / n
            let dotX = size.width / 2 + CGFloat(dot - 1) * Self.dotPitch
            let pulse = reduceMotion ? 0.6 : CGFloat(0.5 + 0.5 * sin(time * 2 * .pi / 1.05 - Double(dot) * 1.15))
            let dotSize = Self.dotDiameter * (0.78 + 0.22 * pulse)

            let m = morph
            let x = barX + (dotX - barX) * m
            let w = Self.barWidth + (dotSize - Self.barWidth) * m
            let h = barHeight + (dotSize - barHeight) * m
            frames[i] = CGRect(x: x - w / 2, y: midY - h / 2, width: w, height: h)
            alphas[i] = Float(0.95 * (1 - m) + (0.38 + 0.6 * pulse) * m)
        }
        for box in views { box.value?.apply(frames: frames, alphas: alphas) }
    }
}

final class OverlayWeakRef<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// Nine rounded bars as CALayers. Geometry is pushed by `NotchWaveformState.render`.
final class NotchWaveformLayerView: NSView {
    private var bars: [CALayer] = []
    weak var state: NotchWaveformState?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = false
        let none: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull(),
                                        "opacity": NSNull(), "frame": NSNull()]
        for _ in 0..<NotchWaveformState.barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.actions = none
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    // Layer-only view: no backing store, so SwiftUI relayouts never trigger a CPU redraw + render-server sync.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    func apply(frames: [CGRect], alphas: [Float]) {
        // Center the design-size waveform in whatever frame SwiftUI gave us.
        let ox = (bounds.width - NotchWaveformState.size.width) / 2
        let oy = (bounds.height - NotchWaveformState.size.height) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            bar.frame = frames[i].offsetBy(dx: ox, dy: oy)
            bar.cornerRadius = min(frames[i].width, frames[i].height) / 2
            bar.opacity = alphas[i]
        }
        CATransaction.commit()
    }
}

struct NotchWaveformBars: NSViewRepresentable {
    let state: NotchWaveformState

    func makeNSView(context: Context) -> NotchWaveformLayerView {
        let view = NotchWaveformLayerView(frame: NSRect(origin: .zero, size: NotchWaveformState.size))
        view.state = state
        state.attach(view)
        return view
    }

    func updateNSView(_ nsView: NotchWaveformLayerView, context: Context) {}

    static func dismantleNSView(_ nsView: NotchWaveformLayerView, coordinator: ()) {
        nsView.state?.detach(nsView)
    }
}

/// Tiny red recording dot with a soft expanding halo. The halo is a render-server animation: zero app CPU.
final class NotchRecordingDotLayerView: NSView {
    private let halo = CALayer()
    private let dot = CALayer()
    var animatesHalo = true {
        didSet { updateHaloAnimation() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = false
        let red = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1).cgColor
        for l in [halo, dot] {
            l.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
            l.cornerRadius = 4
            l.backgroundColor = red
            l.actions = ["position": NSNull(), "bounds": NSNull()]
            layer?.addSublayer(l)
        }
        halo.opacity = 0
        dot.shadowColor = red
        dot.shadowOpacity = 0.6
        dot.shadowRadius = 3
        dot.shadowOffset = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    override func layout() {
        super.layout()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        halo.position = center
        dot.position = center
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateHaloAnimation()
    }

    private func updateHaloAnimation() {
        halo.removeAllAnimations()
        guard window != nil, animatesHalo else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 2.15
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.45
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.8
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
        group.isRemovedOnCompletion = false
        halo.add(group, forKey: "halo")
    }
}

struct NotchRecordingDot: NSViewRepresentable {
    let reduceMotion: Bool

    func makeNSView(context: Context) -> NotchRecordingDotLayerView {
        let view = NotchRecordingDotLayerView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        view.animatesHalo = !reduceMotion
        return view
    }

    func updateNSView(_ nsView: NotchRecordingDotLayerView, context: Context) {
        if nsView.animatesHalo == reduceMotion { nsView.animatesHalo = !reduceMotion }
    }
}

/// Hosts the SwiftUI notch and applies the presence transform (scale, opacity, blur, shake) as layer properties,
/// so entrance/exit motion never re-renders SwiftUI content.
final class NotchPresenceView: NSView {
    private var applied: (scale: CGFloat, opacity: Float, blur: CGFloat, dx: CGFloat) = (-1, -1, -1, 0)
    private let blurFilterName = "presenceBlur"

    init(content: NSView, size: CGSize) {
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layerUsesCoreImageFilters = true
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    func apply(scale: CGFloat, opacity: Float, blur: CGFloat, offsetX: CGFloat) {
        guard let layer else { return }
        let scale = max(scale, 0.01)
        let blur = blur < 0.05 ? 0 : (blur * 10).rounded() / 10
        guard abs(scale - applied.scale) > 0.0005 || opacity != applied.opacity || blur != applied.blur
                || abs(offsetX - applied.dx) > 0.01 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if abs(scale - applied.scale) > 0.0005 || abs(offsetX - applied.dx) > 0.01 {
            // Scale about the center of the view, whatever anchor point AppKit chose for the layer.
            let anchor = CGPoint(x: layer.anchorPoint.x * bounds.width, y: layer.anchorPoint.y * bounds.height)
            let c = CGPoint(x: bounds.midX - anchor.x, y: bounds.midY - anchor.y)
            var t = CATransform3DMakeTranslation(c.x + offsetX, c.y, 0)
            t = CATransform3DScale(t, scale, scale, 1)
            t = CATransform3DTranslate(t, -c.x, -c.y, 0)
            layer.transform = t
        }
        if opacity != applied.opacity { layer.opacity = opacity }
        if blur != applied.blur {
            if blur == 0 {
                layer.filters = nil
            } else if layer.filters?.isEmpty ?? true, let filter = CIFilter(name: "CIGaussianBlur") {
                filter.name = blurFilterName
                filter.setValue(blur, forKey: kCIInputRadiusKey)
                layer.filters = [filter]
            } else {
                layer.setValue(blur, forKeyPath: "filters.\(blurFilterName).\(kCIInputRadiusKey)")
            }
        }
        CATransaction.commit()
        applied = (scale, opacity, blur, offsetX)
    }
}
