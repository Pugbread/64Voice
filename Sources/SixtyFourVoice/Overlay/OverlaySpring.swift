import CoreGraphics
import Foundation

/// Spring parameters in the same terms as SwiftUI's `.spring(response:dampingFraction:)`, so motion we
/// integrate ourselves (the window position) can be matched exactly to motion SwiftUI animates (the pill width).
struct OverlaySpring: Equatable, Sendable {
    var response: Double
    var damping: Double

    /// The flight out of the cursor: a small overshoot, like a thrown object settling.
    static let entrance = OverlaySpring(response: 0.5, damping: 0.74)
    /// Trailing the cursor: critically damped, so it never oscillates when the cursor stops.
    static let follow = OverlaySpring(response: 0.26, damping: 1.0)
    /// Moving to a better spot found by a re-analysis.
    static let relocate = OverlaySpring(response: 0.46, damping: 0.88)
    /// Getting off text that appeared under the notch: quicker, still without overshoot.
    static let escape = OverlaySpring(response: 0.32, damping: 0.92)
    /// Pill width changes from transcript growth (SwiftUI and window shift share it).
    static let layout = OverlaySpring(response: 0.42, damping: 0.86)
    /// Phase morphs: waveform → dots → check (SwiftUI and window shift share it).
    static let phase = OverlaySpring(response: 0.38, damping: 0.82)
    /// The short drift toward the cursor during the exit.
    static let exitDrift = OverlaySpring(response: 0.32, damping: 1.0)
    /// Reduce Motion: no travel, just stay glued to the target.
    static let reduced = OverlaySpring(response: 0.12, damping: 1.0)
}

/// A damped harmonic oscillator stepped with its closed-form solution. Exact and unconditionally stable
/// for any frame time, so a 120 Hz display, a 60 Hz display and a hitch all produce the same curve.
struct OverlaySpring1D: Sendable {
    var value: Double
    var velocity: Double = 0

    init(_ value: Double) { self.value = value }

    mutating func step(toward target: Double, dt: Double, params: OverlaySpring) {
        guard dt > 0 else { return }
        let x0 = value - target
        let v0 = velocity
        let omega = 2 * Double.pi / max(params.response, 0.001)
        let zeta = max(params.damping, 0)
        let x: Double
        let v: Double
        if abs(zeta - 1) < 1e-3 {
            let e = exp(-omega * dt)
            let b = v0 + omega * x0
            x = (x0 + b * dt) * e
            v = (v0 - omega * b * dt) * e
        } else if zeta < 1 {
            let a = zeta * omega
            let wd = omega * (1 - zeta * zeta).squareRoot()
            let e = exp(-a * dt)
            let c = cos(wd * dt)
            let s = sin(wd * dt)
            let b = (v0 + a * x0) / wd
            x = e * (x0 * c + b * s)
            v = e * (v0 * c - ((a * v0 + omega * omega * x0) / wd) * s)
        } else {
            let root = (zeta * zeta - 1).squareRoot()
            let r1 = -omega * (zeta - root)
            let r2 = -omega * (zeta + root)
            let c2 = (v0 - r1 * x0) / (r2 - r1)
            let c1 = x0 - c2
            let e1 = exp(r1 * dt)
            let e2 = exp(r2 * dt)
            x = c1 * e1 + c2 * e2
            v = c1 * r1 * e1 + c2 * r2 * e2
        }
        value = target + x
        velocity = v
    }

    func isSettled(at target: Double, tolerance: Double = 0.05) -> Bool {
        abs(value - target) < tolerance && abs(velocity) < tolerance * 10
    }
}

struct OverlaySpring2D: Sendable {
    var x: OverlaySpring1D
    var y: OverlaySpring1D

    init(_ point: CGPoint) {
        x = OverlaySpring1D(Double(point.x))
        y = OverlaySpring1D(Double(point.y))
    }

    var position: CGPoint { CGPoint(x: x.value, y: y.value) }
    var speed: Double { (x.velocity * x.velocity + y.velocity * y.velocity).squareRoot() }

    mutating func step(toward target: CGPoint, dt: Double, params: OverlaySpring) {
        x.step(toward: Double(target.x), dt: dt, params: params)
        y.step(toward: Double(target.y), dt: dt, params: params)
    }

    mutating func teleport(to point: CGPoint) {
        x = OverlaySpring1D(Double(point.x))
        y = OverlaySpring1D(Double(point.y))
    }

    func isSettled(at target: CGPoint, tolerance: Double = 0.05) -> Bool {
        x.isSettled(at: Double(target.x), tolerance: tolerance) && y.isSettled(at: Double(target.y), tolerance: tolerance)
    }
}
