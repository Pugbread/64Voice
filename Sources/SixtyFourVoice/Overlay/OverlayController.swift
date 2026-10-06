import AppKit
import Combine
import QuartzCore
import SwiftUI

/// The recording notch that is born at the mouse cursor and flies into the emptiest nearby space.
///
/// Architecture: a small transparent panel (max notch size + shadow margin) moved every display frame by our own
/// closed-form springs, driven by the panel view's `CADisplayLink` (so it runs at the refresh rate of whichever
/// display the notch is on: 120 Hz on ProMotion). Everything that changes per frame (window position, presence
/// scale/opacity/blur, shake, waveform bars) is applied as Core Animation layer properties from that one tick, so
/// SwiftUI only re-renders on discrete changes (phase morphs, transcript words). Placement analysis runs off the main
/// thread (`ScreenAnalyzer`). Hidden = panel ordered out + display link invalidated: zero work.
@MainActor
final class OverlayController {
    static let shared = OverlayController()

    // MARK: Hooks for the demo / verification driver (not used by the app)

    /// Cursor source. Replaceable so a test driver can simulate movement without moving the real cursor.
    static var cursorProvider: () -> NSPoint = { NSEvent.mouseLocation }
    /// Forces Reduce Motion on/off (nil = follow the system setting).
    static var reduceMotionOverride: Bool?
    /// Called every display frame with the frame's target time, the notch center (AppKit coordinates) and the
    /// display link's current frame duration.
    var onFrame: ((CFTimeInterval, NSPoint, CFTimeInterval) -> Void)?
    /// Called with every smart-placement result that was applied or kept.
    var onPlacement: ((PlacementOutcome) -> Void)?
    /// Called with every under-notch watchdog result.
    var onWatchdog: ((UnderNotchCheck) -> Void)?
    /// Called when the notch is forced off its spot (text / busy content under it). The string says why.
    var onForcedMove: ((String) -> Void)?
    /// The notch's current reserved slot (where it is and will grow into), AppKit coordinates.
    var debugSlotRect: NSRect { currentSlot(anchor: AppSettings.shared.followCursor ? Self.cursorProvider() : frozenAnchor) }

    /// One-line state dump for debugging.
    var debugState: String {
        String(format: "presence=%@ launched=%@ hopping=%@ link=%@ exitIn=%.3f gen=%d visible=%@",
               "\(presence)", "\(launched)", "\(hopping)", "\(displayLink != nil)",
               exitEnds - CACurrentMediaTime(), generation, "\(panel.isVisible)")
    }

    // MARK: State

    private enum Presence { case hidden, entering, visible, exiting }

    private let model = NotchModel()
    private let panel: OverlayPanel
    private let presenceView: NotchPresenceView
    private let differ = NotchTranscriptDiffer()
    private let linkTarget = DisplayLinkTarget()
    private var displayLink: CADisplayLink?
    private var cancellables: Set<AnyCancellable> = []

    private var presence: Presence = .hidden
    /// Bumped whenever a scheduled step (the exit safety net) must be invalidated.
    private var generation = 0
    private var hideDeadline: CFTimeInterval?
    private var rawTranscript = ""
    private var reduceMotion = false

    // Position, in AppKit global points. Visual notch center = motion.position + (shift.value, 0).
    private var motion = OverlaySpring2D(.zero)
    private var motionParams = OverlaySpring.follow
    private var motionParamsUntil: CFTimeInterval = 0
    /// Horizontal shift that keeps the pill's edge nearest the cursor still while it widens.
    private var shift = OverlaySpring1D(0)
    private var shiftTarget: Double = 0
    private var shiftParams = OverlaySpring.layout
    /// +1: grows to the right (notch is right of the cursor), -1: grows left, 0: grows symmetrically.
    private var growthSide: CGFloat = 0
    /// Notch center relative to the anchor (the cursor when following, else where it was shown).
    private var offset = CGVector.zero
    private var frozenAnchor = NSPoint.zero
    private var exitTarget: NSPoint?
    private var lastTick: CFTimeInterval = 0
    private var lastOrigin = NSPoint(x: CGFloat.nan, y: CGFloat.nan)
    private var lastCursor = NSPoint.zero
    private var cursorSpeed: Double = 0
    /// Smoothed cursor velocity (pt/s, AppKit), for looking ahead of the follow motion.
    private var cursorVelocity = CGVector.zero

    // Presence (layer-level scale / opacity / blur / shake).
    private var scale = OverlaySpring1D(0.2)
    private var scaleTarget = 0.2
    private var scaleParams = OverlaySpring(response: 0.46, damping: 0.66)
    private var opacity = OverlayTween(0)
    private var blur = OverlayTween(8)
    private var shakeStart: CFTimeInterval = 0
    private var exitEnds: CFTimeInterval = 0
    private var hopEnds: CFTimeInterval = 0

    // Entrance.
    private var launched = false
    private var launchDeadline: CFTimeInterval = 0
    private var entranceEnds: CFTimeInterval = 0

    // Display.
    private var screen: NSScreen?
    private var displayID: CGDirectDisplayID = 0
    private var hopping = false

    // Smart placement.
    private var canCapture = false
    private var analysisSession = 0
    private var analysisInFlight = false
    private var forceAnalysis = false
    private var lastAnalysisStart: CFTimeInterval = 0
    private var lastAnalysisCursor = NSPoint.zero
    private var lastAnalysisWidth: CGFloat = 0

    // Under-notch safety: whatever ends up beneath the notch must never be text.
    private struct LatestMap {
        var map: PlacementBusyMap
        var boxes: [CGRect]
        var caret: CGRect?
        var displayID: CGDirectDisplayID
    }
    private var latest: LatestMap?
    private var watchInFlight = false
    private var lastWatchStart: CFTimeInterval = 0
    /// Start of the most recent capture of any kind (analysis or watchdog): combined rate stays ≤ 4 Hz.
    private var lastCaptureStart: CFTimeInterval = 0
    private var forcedAnalysisPending = false
    private var lastForcedTime: CFTimeInterval = 0
    private var lastForcedCursor = NSPoint.zero
    private var forcedCooldownUntil: CFTimeInterval = 0
    /// No text-free spot was found nearby: stay on the least-bad one until this time (unless the cursor moves).
    private var leastBadUntil: CFTimeInterval = 0
    private var lastPredictCursor = NSPoint.zero
    private var lastPredictTime: CFTimeInterval = 0

    private let minCaptureSpacing: CFTimeInterval = 0.25
    private let watchInterval: CFTimeInterval = 0.28
    private let forcedCooldown: CFTimeInterval = 1.5

    /// If the first analysis takes longer than this, fly toward the geometric fallback and retarget later.
    /// With Reduce Motion there is no flight to hide the wait behind, so wait longer and fade in at the final spot.
    private var entranceAnalysisBudget: CFTimeInterval { reduceMotion ? 0.25 : 0.06 }
    /// Reduce Motion relocation: fade out, jump, fade in (no travel).
    private var blinkJumpAt: CFTimeInterval = 0

    private init() {
        panel = OverlayPanel(size: NotchStyle.panelSize)
        let host = NSHostingView(rootView: NotchView(model: model))
        host.sizingOptions = []
        presenceView = NotchPresenceView(content: host, size: NotchStyle.panelSize)
        panel.contentView = presenceView
        linkTarget.owner = self
        applyPresence(now: CACurrentMediaTime())

        AppSettings.shared.$showLiveTranscript
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] show in self?.refreshTranscript(show: show) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Task { await ScreenAnalyzer.shared.invalidateContent() }
                guard let self, self.presence != .hidden else { return }
                if let s = NSScreen.overlayScreen(containing: Self.cursorProvider()) {
                    self.screen = s
                    self.displayID = s.overlayDisplayID
                }
            }
            .store(in: &cancellables)

        prewarmRendering()
        // Load ScreenCaptureKit content and Vision ahead of the first show (no-op without permission).
        Task.detached(priority: .utility) { await ScreenAnalyzer.shared.prewarm() }
    }

    // MARK: - Public API

    /// Appear at the mouse cursor. If already visible, just update the phase.
    func show(phase: OverlayPhase) {
        hideDeadline = nil
        switch presence {
        case .hidden:
            present(phase: phase)
        case .exiting:
            cancelExit()
            setPhase(phase)
        case .entering, .visible:
            setPhase(phase)
        }
    }

    func setPhase(_ phase: OverlayPhase) {
        guard phase != model.phase else { return }
        let isError: Bool
        if case .error = phase { isError = true } else { isError = false }
        applyLayout(OverlaySpring.phase) { model.phase = phase }
        model.wave.morphTarget = phase == .transcribing ? 1 : 0
        if isError, !reduceMotion, presence != .hidden {
            shakeStart = CACurrentMediaTime() + 0.06 // let the error badge start growing first
        }
    }

    /// 0...1 mic level, ~30–60 Hz. Cheap: the waveform samples it on the next display frame.
    func setLevel(_ level: Float) {
        model.wave.level = level.isFinite ? max(0, min(1, level)) : 0
    }

    /// Live partial transcript; "" clears.
    func setTranscript(_ text: String) {
        rawTranscript = text
        refreshTranscript(show: AppSettings.shared.showLiveTranscript)
    }

    /// Optionally wait (e.g. to show `.done`), then shrink/fade toward the cursor and order out.
    /// The delay is checked on the display link rather than a dispatch timer, so it stays frame-accurate even when
    /// the system coalesces a background accessory app's timers (observed firing ~0.5 s late in testing).
    func hide(after delay: TimeInterval = 0) {
        hideDeadline = nil
        guard presence == .entering || presence == .visible else { return }
        guard delay > 0 else {
            beginExit()
            return
        }
        hideDeadline = CACurrentMediaTime() + delay
    }

    // MARK: - Presentation

    private func present(phase: OverlayPhase) {
        let cursor = Self.cursorProvider()
        guard let screen = NSScreen.overlayScreen(containing: cursor) else { return }
        generation += 1
        reduceMotion = Self.reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.reduceMotion = reduceMotion
        model.wave.reduceMotion = reduceMotion
        canCapture = CGPreflightScreenCaptureAccess()

        rawTranscript = ""
        differ.reset()
        withoutAnimation {
            model.phase = phase
            model.words = []
            model.metrics = currentMetrics()
        }
        model.wave.reset()
        model.wave.morphTarget = phase == .transcribing ? 1 : 0
        model.wave.snapMorph()

        presence = .entering
        beginEntrance(at: cursor, on: screen)
        panel.orderFrontRegardless()
        startDisplayLink()
    }

    /// Puts the (invisible) blob at the cursor and decides where it will fly.
    private func beginEntrance(at cursor: NSPoint, on screen: NSScreen) {
        let now = CACurrentMediaTime()
        self.screen = screen
        displayID = screen.overlayDisplayID
        frozenAnchor = cursor
        motion.teleport(to: cursor)
        shift = OverlaySpring1D(0)
        shiftTarget = 0
        exitTarget = nil
        hopping = false
        launched = false
        lastCursor = cursor
        cursorSpeed = 0
        cursorVelocity = .zero
        shakeStart = 0
        blinkJumpAt = 0

        scale = OverlaySpring1D(reduceMotion ? 1 : 0.2)
        scaleTarget = scale.value
        opacity.set(0)
        blur.set(reduceMotion ? 0 : 8)
        applyPresence(now: now)
        moveWindow(center: cursor, force: true)

        applyFallbackPlacement(cursor: cursor, screen: screen)
        analysisSession += 1
        analysisInFlight = false
        forcedAnalysisPending = false
        watchInFlight = false
        latest = nil
        forcedCooldownUntil = 0
        leastBadUntil = 0
        lastPredictCursor = cursor
        if smartPlacementEnabled {
            requestAnalysis(cursor: cursor, current: nil)
            launchDeadline = now + entranceAnalysisBudget
        } else {
            launchDeadline = 0 // next frame
        }
    }

    /// Starts the flight and the grow-in, together, from a display-link tick.
    private func launch(now: CFTimeInterval) {
        launched = true
        entranceEnds = now + 0.7
        if reduceMotion {
            motion.teleport(to: restingCenter(cursor: Self.cursorProvider(), follow: AppSettings.shared.followCursor))
            motionParams = .reduced
            opacity.animate(to: 1, duration: 0.2, curve: .easeOut, now: now)
        } else {
            motionParams = .entrance
            motionParamsUntil = entranceEnds
            scaleTarget = 1
            scaleParams = OverlaySpring(response: 0.46, damping: 0.66)
            opacity.animate(to: 1, duration: 0.14, curve: .easeOut, now: now)
            blur.animate(to: 0, duration: 0.3, curve: .easeOut, now: now)
        }
    }

    private func beginExit() {
        guard presence == .entering || presence == .visible else { return }
        let now = CACurrentMediaTime()
        presence = .exiting
        hopping = false
        blinkJumpAt = 0
        generation += 1
        let token = generation
        analysisSession += 1
        analysisInFlight = false
        watchInFlight = false

        foldShift()
        let cursor = Self.cursorProvider()
        let center = motion.position
        let dx = cursor.x - center.x
        let dy = cursor.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let drift = reduceMotion || distance < 1 ? 0 : min(18, distance * 0.25)
        exitTarget = drift > 0 ? NSPoint(x: center.x + dx / distance * drift, y: center.y + dy / distance * drift) : center

        if reduceMotion || !launched {
            opacity.animate(to: 0, duration: 0.18, curve: .easeOut, now: now)
            exitEnds = now + 0.18
        } else {
            scaleTarget = 0.6
            scaleParams = OverlaySpring(response: 0.3, damping: 1)
            opacity.animate(to: 0, duration: 0.16, curve: .easeIn, now: now)
            blur.animate(to: 6, duration: 0.2, curve: .easeIn, now: now)
            exitEnds = now + 0.2
        }
        // Safety net in case display frames stop (display asleep): never leave a stuck window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, token == self.generation, self.presence == .exiting else { return }
                self.finishHide()
            }
        }
    }

    /// `show` arrived mid-exit: grow back in place. Same window, no ghost.
    private func cancelExit() {
        let now = CACurrentMediaTime()
        generation += 1
        exitTarget = nil
        if launched {
            presence = .visible
            motionParams = reduceMotion ? .reduced : .relocate
            motionParamsUntil = now + 0.5
            scaleTarget = 1
            scaleParams = OverlaySpring(response: 0.4, damping: 0.72)
            opacity.animate(to: 1, duration: 0.15, curve: .easeOut, now: now)
            blur.animate(to: 0, duration: 0.2, curve: .easeOut, now: now)
        } else {
            presence = .entering
            launchDeadline = 0
        }
        analysisSession += 1
        analysisInFlight = false
        watchInFlight = false
        forceAnalysis = true
    }

    private func finishHide() {
        presence = .hidden
        hideDeadline = nil
        panel.orderOut(nil)
        stopDisplayLink()
        exitTarget = nil
        hopping = false
        launched = false
        rawTranscript = ""
        differ.reset()
        withoutAnimation { model.words = [] }
        model.wave.reset()
        scale = OverlaySpring1D(0.2)
        scaleTarget = 0.2
        opacity.set(0)
        blur.set(8)
        shakeStart = 0
        applyPresence(now: CACurrentMediaTime())
    }

    /// The cursor crossed to another display: fade out here, then be reborn at the cursor there.
    private func beginHop(now: CFTimeInterval) {
        hopping = true
        analysisSession += 1
        analysisInFlight = false
        watchInFlight = false
        hopEnds = now + 0.13
        opacity.animate(to: 0, duration: 0.12, curve: .easeIn, now: now)
        if !reduceMotion {
            scaleTarget = 0.6
            scaleParams = OverlaySpring(response: 0.25, damping: 1)
            blur.animate(to: 4, duration: 0.12, curve: .easeIn, now: now)
        }
    }

    /// Order the panel once off-screen (fully transparent) so SwiftUI, RenderBox and Metal are warm before the
    /// first real show; otherwise the very first entrance hitches.
    private func prewarmRendering() {
        panel.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        presenceView.apply(scale: 1, opacity: 0.01, blur: 0, offsetX: 0)
        panel.orderFrontRegardless()
        // Render each phase once (text, badges, symbols), then restore the hidden state.
        let warmWords = differ.update("Warming up")
        let steps: [(OverlayPhase, [NotchTranscriptWord])] = [
            (.listening, warmWords), (.error("Warming up"), []), (.done, []), (.transcribing, warmWords), (.listening, []),
        ]
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(index)) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.presence == .hidden else { return }
                    self.withoutAnimation {
                        self.model.phase = step.0
                        self.model.words = step.1
                        self.model.metrics = self.currentMetrics()
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(steps.count) + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.presence == .hidden else { return }
                self.differ.reset()
                self.panel.orderOut(nil)
                self.applyPresence(now: CACurrentMediaTime())
            }
        }
    }

    // MARK: - Layout

    private func currentMetrics() -> NotchMetrics {
        NotchMetrics.make(phase: model.phase,
                          transcriptWidth: NotchTranscriptDiffer.lineWidth(model.words),
                          errorWidth: model.errorMessage.map(NotchTranscriptDiffer.measure) ?? 0)
    }

    /// Applies a model change with a spring, recomputes the metrics, and shifts the window so the edge nearest
    /// the cursor stays put (same spring as SwiftUI's width animation).
    private func applyLayout(_ params: OverlaySpring, _ change: () -> Void) {
        let oldWidth = model.metrics.width
        if presence == .hidden {
            withoutAnimation {
                change()
                model.metrics = currentMetrics()
            }
            return
        }
        withAnimation(NotchStyle.animation(params)) {
            change()
            model.metrics = currentMetrics()
        }
        let delta = model.metrics.width - oldWidth
        if abs(delta) > 0.25 {
            shiftParams = params
            shiftTarget += Double(growthSide * delta / 2)
        }
    }

    private func refreshTranscript(show: Bool) {
        let words = differ.update(show ? rawTranscript : "")
        guard words != model.words else { return }
        let oldIDs = Set(model.words.map(\.id))
        let inserted = words.filter { !oldIDs.contains($0.id) }
        model.insertShift = inserted.reduce(0) { $0 + $1.width + NotchStyle.spaceWidth }
        applyLayout(OverlaySpring.layout) { model.words = words }
    }

    private func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }

    // MARK: - Frame loop

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = presenceView.displayLink(target: linkTarget, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTick = 0
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        // Integrate to the time this frame will be on screen, not the (jittery) callback time: steps stay even.
        let now = max(link.targetTimestamp, CACurrentMediaTime())
        let dt = lastTick == 0 ? 1.0 / 120 : min(max(now - lastTick, 1.0 / 500), 1.0 / 20)
        lastTick = now
        guard presence != .hidden else { return }

        let cursor = Self.cursorProvider()
        let follow = AppSettings.shared.followCursor
        let step = hypot(cursor.x - lastCursor.x, cursor.y - lastCursor.y)
        cursorSpeed = cursorSpeed * 0.75 + Double(step) / dt * 0.25
        cursorVelocity = CGVector(dx: cursorVelocity.dx * 0.7 + (cursor.x - lastCursor.x) / dt * 0.3,
                                  dy: cursorVelocity.dy * 0.7 + (cursor.y - lastCursor.y) / dt * 0.3)
        lastCursor = cursor

        // Lifecycle transitions.
        if let deadline = hideDeadline, now >= deadline, presence == .entering || presence == .visible {
            hideDeadline = nil
            beginExit()
        }
        if presence == .exiting, now >= exitEnds {
            finishHide()
            return
        }
        if hopping, now >= hopEnds {
            let target = NSScreen.overlayScreen(containing: cursor) ?? screen
            if let target {
                presence = .entering
                beginEntrance(at: cursor, on: target)
            }
        }
        if presence == .entering, !launched, !hopping, now >= launchDeadline { launch(now: now) }
        if presence == .entering, launched, now >= entranceEnds { presence = .visible }
        if follow, !hopping, launched, presence == .entering || presence == .visible,
           let s = NSScreen.overlayScreen(containing: cursor), s.overlayDisplayID != displayID {
            beginHop(now: now)
        }
        if blinkJumpAt > 0, now >= blinkJumpAt, presence == .entering || presence == .visible {
            blinkJumpAt = 0
            let center = restingCenter(cursor: cursor, follow: follow)
            motion.teleport(to: NSPoint(x: center.x - shiftTarget, y: center.y))
            opacity.animate(to: 1, duration: 0.15, curve: .easeOut, now: now)
        }
        if motionParamsUntil > 0, now >= motionParamsUntil {
            motionParams = reduceMotion ? .reduced : .follow
            motionParamsUntil = 0
        }

        // Position.
        let target: NSPoint
        let params: OverlaySpring
        if presence == .exiting {
            target = exitTarget ?? motion.position
            params = .exitDrift
        } else if !launched || hopping {
            target = motion.position
            params = motionParams
        } else {
            let center = restingCenter(cursor: cursor, follow: follow)
            target = NSPoint(x: center.x - shiftTarget, y: center.y)
            params = motionParams
        }
        motion.step(toward: target, dt: dt, params: params)
        shift.step(toward: shiftTarget, dt: dt, params: shiftParams)
        let center = NSPoint(x: motion.position.x + shift.value, y: motion.position.y)
        moveWindow(center: center)

        // Presence and waveform.
        scale.step(toward: scaleTarget, dt: dt, params: scaleParams)
        applyPresence(now: now)
        let waveVisible = model.phase == .listening || model.phase == .transcribing
        if waveVisible { model.wave.render(time: now) }

        maybeRequestAnalysis(now: now, cursor: cursor, follow: follow)
        predictFollowTarget(now: now, cursor: cursor, follow: follow)
        maybeWatch(now: now, cursor: cursor, follow: follow)
        onFrame?(now, center, link.targetTimestamp - link.timestamp)
    }

    private func applyPresence(now: CFTimeInterval) {
        var dx: CGFloat = 0
        if shakeStart > 0, now >= shakeStart {
            let t = now - shakeStart
            if t > 0.5 {
                shakeStart = 0
            } else {
                // Damped horizontal shake: ~7 pt, 11 Hz, gone in half a second.
                dx = CGFloat(7 * exp(-t / 0.13) * sin(2 * .pi * 11 * t))
            }
        }
        presenceView.apply(scale: CGFloat(scale.value), opacity: Float(opacity.value(at: now)),
                           blur: CGFloat(blur.value(at: now)), offsetX: dx)
    }

    /// Where the notch should rest now: anchor + offset (+ growth shift), kept on screen and off the cursor.
    private func restingCenter(cursor: NSPoint, follow: Bool) -> NSPoint {
        let anchor = follow ? cursor : frozenAnchor
        let size = model.metrics.size
        var center = clamp(NSPoint(x: anchor.x + offset.dx + shiftTarget, y: anchor.y + offset.dy), size: size)
        if follow, covers(cursor: cursor, center: center, size: size) {
            // Pinned against a screen edge onto the cursor: mirror to the other side and ask for a fresh analysis.
            let alternatives = [CGVector(dx: -offset.dx, dy: offset.dy), CGVector(dx: offset.dx, dy: -offset.dy),
                                CGVector(dx: -offset.dx, dy: -offset.dy)]
            for alt in alternatives {
                let candidate = clamp(NSPoint(x: anchor.x + alt.dx, y: anchor.y + alt.dy), size: size)
                if !covers(cursor: cursor, center: candidate, size: size) {
                    foldShift()
                    offset = alt
                    growthSide = side(of: NSRect(x: candidate.x - size.width / 2, y: candidate.y - size.height / 2,
                                                 width: size.width, height: size.height), cursor: cursor)
                    motionParams = reduceMotion ? .reduced : .relocate
                    motionParamsUntil = CACurrentMediaTime() + 0.6
                    forceAnalysis = true
                    center = candidate
                    break
                }
            }
        }
        return center
    }

    private func clamp(_ center: NSPoint, size: CGSize) -> NSPoint {
        guard let frame = screen?.visibleFrame else { return center }
        let inset = PlacementTuning.standard.edgeInset
        let allowed = frame.insetBy(dx: inset, dy: inset)
        let hw = size.width / 2
        let hh = size.height / 2
        let x = allowed.width >= size.width ? min(max(center.x, allowed.minX + hw), allowed.maxX - hw) : allowed.midX
        let y = allowed.height >= size.height ? min(max(center.y, allowed.minY + hh), allowed.maxY - hh) : allowed.midY
        return NSPoint(x: x, y: y)
    }

    private func covers(cursor: NSPoint, center: NSPoint, size: CGSize) -> Bool {
        let g = PlacementTuning.standard.hotspotGuard // top-left relative; flip to AppKit
        let guardRect = NSRect(x: cursor.x + g.minX, y: cursor.y - g.maxY, width: g.width, height: g.height)
        let rect = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        return rect.intersects(guardRect)
    }

    private func side(of rect: NSRect, cursor: NSPoint) -> CGFloat {
        if rect.minX >= cursor.x - 2 { return 1 }
        if rect.maxX <= cursor.x + 2 { return -1 }
        return 0
    }

    /// Moves the growth shift into the main spring (position and velocity), so offsets can be reset without a jump.
    private func foldShift() {
        motion.x.value += shift.value
        motion.x.velocity += shift.velocity
        offset.dx += CGFloat(shiftTarget)
        shift = OverlaySpring1D(0)
        shiftTarget = 0
    }

    private func moveWindow(center: NSPoint, force: Bool = false) {
        let size = NotchStyle.panelSize
        let origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        if !force, abs(origin.x - lastOrigin.x) < 0.01, abs(origin.y - lastOrigin.y) < 0.01 { return }
        lastOrigin = origin
        panel.setFrameOrigin(origin)
    }

    // MARK: - Placement

    private var smartPlacementEnabled: Bool { canCapture && AppSettings.shared.smartPlacement }

    /// The space placement plans for. While listening with live transcript on, the pill will grow to full width
    /// within a few seconds, so reserve that room up front: the compact pill sits at the cursor end of the reserved
    /// slot and grows away from the cursor into it, instead of growing over text and then having to hop.
    private var reservedSize: CGSize {
        let growsWithTranscript = AppSettings.shared.showLiveTranscript
            && (model.phase == .listening || (model.phase == .transcribing && !model.words.isEmpty))
        let width = growsWithTranscript ? NotchStyle.maxWidth : model.metrics.width
        return CGSize(width: max(width, model.metrics.width), height: NotchStyle.height)
    }

    /// Puts the pill (current width) at the cursor-side end of a reserved slot and remembers the growth direction.
    private func adopt(slot rect: NSRect, anchor: NSPoint, cursor: NSPoint) {
        foldShift()
        growthSide = side(of: rect, cursor: cursor)
        let w = model.metrics.width
        let x: CGFloat
        switch growthSide {
        case 1: x = rect.minX + w / 2
        case -1: x = rect.maxX - w / 2
        default: x = rect.midX
        }
        offset = CGVector(dx: x - anchor.x, dy: rect.midY - anchor.y)
    }

    /// The reserved slot that the current pill position implies (inverse of `adopt`).
    private func currentSlot(anchor: NSPoint) -> NSRect {
        let size = model.metrics.size
        let reserved = reservedSize
        let c = clamp(NSPoint(x: anchor.x + offset.dx + shiftTarget, y: anchor.y + offset.dy), size: size)
        let minX: CGFloat
        switch growthSide {
        case 1: minX = c.x - size.width / 2
        case -1: minX = c.x + size.width / 2 - reserved.width
        default: minX = c.x - reserved.width / 2
        }
        return NSRect(x: minX, y: c.y - size.height / 2, width: reserved.width, height: size.height)
    }

    private func applyFallbackPlacement(cursor: NSPoint, screen: NSScreen) {
        let rectTL = PlacementEngine.geometricFallback(cursor: OverlayScreenSpace.topLeft(cursor), size: reservedSize,
                                                       visibleFrame: OverlayScreenSpace.topLeft(screen.visibleFrame))
        adopt(slot: OverlayScreenSpace.appKit(rectTL), anchor: cursor, cursor: cursor)
    }

    private func maybeRequestAnalysis(now: CFTimeInterval, cursor: NSPoint, follow: Bool) {
        guard smartPlacementEnabled, !analysisInFlight, !watchInFlight, launched, !hopping,
              presence == .entering || presence == .visible else { return }
        // The done check is a brief goodbye: never move it.
        guard model.phase != .done, now - lastCaptureStart >= minCaptureSpacing else { return }
        let sinceLast = now - lastAnalysisStart
        let reserved = reservedSize.width
        // Only growth can create new overlap (a shrinking pill stays put); re-plan right away when it happens.
        let grew = reserved - lastAnalysisWidth > 40
        if reserved < lastAnalysisWidth { lastAnalysisWidth = reserved }
        let movedFar = follow && hypot(cursor.x - lastAnalysisCursor.x, cursor.y - lastAnalysisCursor.y) > 60
        let settledEnough = cursorSpeed < 400 || sinceLast > 1.0
        guard grew || (sinceLast >= 0.4 && (forceAnalysis || (movedFar && settledEnough))) else { return } // ≤ 2.5 Hz
        forceAnalysis = false
        requestAnalysis(cursor: cursor, current: currentSlot(anchor: follow ? cursor : frozenAnchor))
    }

    /// `forced`: the current spot is invalid (text or busy content under it), so no hysteresis: take the best spot.
    private func requestAnalysis(cursor: NSPoint, current: NSRect?, forced: Bool = false) {
        guard let screen else { return }
        analysisInFlight = true
        forcedAnalysisPending = forced
        lastAnalysisStart = CACurrentMediaTime()
        lastCaptureStart = lastAnalysisStart
        lastAnalysisCursor = cursor
        let reserved = reservedSize
        lastAnalysisWidth = reserved.width

        let request = PlacementRequest(cursor: OverlayScreenSpace.topLeft(cursor),
                                       notchSize: reserved,
                                       displayFrame: OverlayScreenSpace.topLeft(screen.frame),
                                       visibleFrame: OverlayScreenSpace.topLeft(screen.visibleFrame),
                                       current: forced ? nil : current.map(OverlayScreenSpace.topLeft),
                                       ownRect: launched ? OverlayScreenSpace.topLeft(visualPillRect) : nil)
        let session = analysisSession
        let id = displayID
        let anchor = AppSettings.shared.followCursor ? cursor : frozenAnchor
        Task { [weak self] in
            let outcome = await ScreenAnalyzer.shared.analyze(request, displayID: id)
            self?.applyAnalysis(outcome, session: session, displayID: id, anchor: anchor, cursor: cursor)
        }
    }

    private func applyAnalysis(_ outcome: PlacementOutcome?, session: Int, displayID id: CGDirectDisplayID,
                               anchor: NSPoint, cursor: NSPoint) {
        guard session == analysisSession else { return }
        analysisInFlight = false
        let forced = forcedAnalysisPending
        forcedAnalysisPending = false
        guard let outcome, presence == .entering || presence == .visible, !hopping else { return }
        let analysis = outcome.analysis
        latest = LatestMap(map: analysis.map, boxes: analysis.textBoxes, caret: analysis.caret, displayID: id)
        onPlacement?(outcome)
        guard model.phase != .done, !analysis.keptCurrent else { return }

        if forced {
            let stillBad = PlacementEngine.coverage(of: analysis.rect, map: analysis.map, textBoxes: analysis.textBoxes).mustMove
            forcedMove(to: OverlayScreenSpace.appKit(analysis.rect), anchor: anchor, cursor: cursor, stillBad: stillBad,
                       reason: stillBad ? "forced analysis: no text-free spot, least-bad" : "forced analysis")
        } else {
            move(to: OverlayScreenSpace.appKit(analysis.rect), anchor: anchor, cursor: cursor)
        }
    }

    /// Relocates to a new reserved slot with the right motion for the current state.
    private func move(to slot: NSRect, anchor: NSPoint, cursor: NSPoint, urgent: Bool = false) {
        adopt(slot: slot, anchor: anchor, cursor: cursor)
        if launched, reduceMotion {
            let now = CACurrentMediaTime()
            opacity.animate(to: 0, duration: 0.1, curve: .easeIn, now: now)
            blinkJumpAt = now + 0.1
        } else if launched {
            motionParams = urgent ? .escape : (presence == .entering ? .entrance : .relocate)
            motionParamsUntil = CACurrentMediaTime() + 0.7
        } else {
            launchDeadline = 0 // fly straight there on the next frame
        }
    }

    /// A mandatory move off text/busy content. Starts the anti-ping-pong cooldown.
    private func forcedMove(to slot: NSRect, anchor: NSPoint, cursor: NSPoint, stillBad: Bool, reason: String) {
        let now = CACurrentMediaTime()
        lastForcedTime = now
        lastForcedCursor = cursor
        forcedCooldownUntil = now + forcedCooldown
        leastBadUntil = stillBad ? now + 4 : 0
        move(to: slot, anchor: anchor, cursor: cursor, urgent: true)
        onForcedMove?(reason)
    }

    /// Forced moves are mandatory, but not more often than every 1.5 s while the cursor stays put (no ping-pong
    /// between two bad spots). A cursor that has moved on since gets a fresh decision after 0.25 s.
    private func forcedMoveAllowed(now: CFTimeInterval, cursor: NSPoint) -> Bool {
        let movedOn = hypot(cursor.x - lastForcedCursor.x, cursor.y - lastForcedCursor.y)
        if now < leastBadUntil, movedOn < 40 { return false }
        if now >= forcedCooldownUntil { return true }
        return movedOn > 20 && now - lastForcedTime >= 0.25
    }

    private var visualPillRect: NSRect {
        let size = model.metrics.size
        return NSRect(x: motion.position.x + shift.value - size.width / 2, y: motion.position.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Under-notch watchdog, ~3 Hz while visible: capture just the notch's slot (our windows excluded, so it sees
    /// what is beneath) and force a re-placement if text or strongly busy content is there.
    private func maybeWatch(now: CFTimeInterval, cursor: NSPoint, follow: Bool) {
        guard smartPlacementEnabled, presence == .visible, launched, !hopping, blinkJumpAt == 0,
              model.phase != .done, !watchInFlight, !analysisInFlight,
              now - lastWatchStart >= watchInterval, now - lastCaptureStart >= minCaptureSpacing,
              let screen else { return }
        let slot = OverlayScreenSpace.topLeft(currentSlot(anchor: follow ? cursor : frozenAnchor))
        watchInFlight = true
        lastWatchStart = now
        lastCaptureStart = now
        let session = analysisSession
        let id = displayID
        let displayFrame = OverlayScreenSpace.topLeft(screen.frame)
        let own = OverlayScreenSpace.topLeft(visualPillRect)
        Task { [weak self] in
            let check = await ScreenAnalyzer.shared.inspect(rect: slot, displayFrame: displayFrame, displayID: id, ownRect: own)
            self?.applyWatch(check, session: session, cursor: cursor)
        }
    }

    private func applyWatch(_ check: UnderNotchCheck?, session: Int, cursor: NSPoint) {
        guard session == analysisSession else { return }
        watchInFlight = false
        guard let check, presence == .visible, !hopping, model.phase != .done else { return }
        onWatchdog?(check)
        guard check.coverage.mustMove, !analysisInFlight else { return }
        let now = CACurrentMediaTime()
        let cursorNow = Self.cursorProvider()
        // The notch has moved on with the cursor since the capture: the next check will judge the new spot.
        if AppSettings.shared.followCursor, hypot(cursorNow.x - cursor.x, cursorNow.y - cursor.y) > 30 { return }
        guard forcedMoveAllowed(now: now, cursor: cursorNow) else { return }
        // Mandatory: bypasses the capture spacing and hysteresis (the current spot is invalid, not merely worse).
        requestAnalysis(cursor: cursorNow, current: nil, forced: true)
    }

    /// While following, check where the notch is going (now, and ~0.12 s ahead along the cursor's velocity) against
    /// the latest analyzed map, before it gets there. Text there → re-pick from the same map at once (no capture),
    /// choosing a spot that stays clear for the look-ahead too. Unanalyzed there → analyze now (unknown ≠ empty).
    private func predictFollowTarget(now: CFTimeInterval, cursor: NSPoint, follow: Bool) {
        guard follow, smartPlacementEnabled, launched, !hopping, blinkJumpAt == 0,
              presence == .entering || presence == .visible, model.phase != .done, !analysisInFlight,
              let latest, latest.displayID == displayID, let screen else { return }
        guard hypot(cursor.x - lastPredictCursor.x, cursor.y - lastPredictCursor.y) > 3,
              now - lastPredictTime >= 0.04 else { return }
        lastPredictCursor = cursor
        lastPredictTime = now

        var ahead = CGVector(dx: cursorVelocity.dx * 0.12, dy: cursorVelocity.dy * 0.12)
        let aheadLength = hypot(ahead.dx, ahead.dy)
        if aheadLength > 80 { ahead = CGVector(dx: ahead.dx * 80 / aheadLength, dy: ahead.dy * 80 / aheadLength) }
        let lookahead = NSPoint(x: cursor.x + ahead.dx, y: cursor.y + ahead.dy)
        let slotNow = OverlayScreenSpace.topLeft(currentSlot(anchor: cursor))
        let slotAhead = OverlayScreenSpace.topLeft(currentSlot(anchor: lookahead))
        let covNow = PlacementEngine.coverage(of: slotNow, map: latest.map, textBoxes: latest.boxes)
        let covAhead = PlacementEngine.coverage(of: slotAhead, map: latest.map, textBoxes: latest.boxes)
        if !covNow.analyzed || !covAhead.analyzed {
            if !watchInFlight, now - lastCaptureStart >= minCaptureSpacing {
                requestAnalysis(cursor: cursor, current: currentSlot(anchor: cursor))
            }
            return
        }
        guard covNow.mustMove || covAhead.mustMove, forcedMoveAllowed(now: now, cursor: cursor) else { return }

        let request = PlacementRequest(cursor: OverlayScreenSpace.topLeft(cursor), notchSize: reservedSize,
                                       displayFrame: OverlayScreenSpace.topLeft(screen.frame),
                                       visibleFrame: OverlayScreenSpace.topLeft(screen.visibleFrame),
                                       current: nil, ownRect: OverlayScreenSpace.topLeft(visualPillRect))
        let analysis = PlacementEngine.choose(request: request, map: latest.map, textBoxes: latest.boxes, caret: latest.caret)
        let shiftTL = CGVector(dx: ahead.dx, dy: -ahead.dy)
        let pick = analysis.candidates
            .filter { !$0.rejected }
            .sorted { $0.cost < $1.cost }
            .first { candidate in
                let here = PlacementEngine.coverage(of: candidate.rect, map: latest.map, textBoxes: latest.boxes)
                let there = PlacementEngine.coverage(of: candidate.rect.offsetBy(dx: shiftTL.dx, dy: shiftTL.dy),
                                                     map: latest.map, textBoxes: latest.boxes)
                return here.analyzed && !here.mustMove && there.analyzed && !there.mustMove
            }
        if let pick {
            forcedMove(to: OverlayScreenSpace.appKit(pick.rect), anchor: cursor, cursor: cursor, stillBad: false,
                       reason: "follow prediction")
            forceAnalysis = true // confirm with a fresh capture soon
        } else if !watchInFlight {
            requestAnalysis(cursor: cursor, current: nil, forced: true)
        }
    }
}

/// Time-based interpolation for presence opacity / blur.
struct OverlayTween {
    enum Curve { case easeOut, easeIn }

    private var from: Double
    private var to: Double
    private var start: CFTimeInterval = 0
    private var duration: Double = 0
    private var curve: Curve = .easeOut

    init(_ value: Double) {
        from = value
        to = value
    }

    func value(at time: CFTimeInterval) -> Double {
        guard duration > 0 else { return to }
        let u = min(max((time - start) / duration, 0), 1)
        let e: Double
        switch curve {
        case .easeOut: e = 1 - pow(1 - u, 3)
        case .easeIn: e = u * u
        }
        return from + (to - from) * e
    }

    func isDone(at time: CFTimeInterval) -> Bool { duration == 0 || time >= start + duration }

    mutating func animate(to value: Double, duration: Double, curve: Curve, now: CFTimeInterval) {
        from = self.value(at: now)
        to = value
        start = now
        self.duration = duration
        self.curve = curve
    }

    mutating func set(_ value: Double) {
        from = value
        to = value
        duration = 0
    }
}

/// CADisplayLink retains its target; this trampoline keeps the controller out of that cycle.
@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var owner: OverlayController?

    @objc func tick(_ link: CADisplayLink) {
        owner?.tick(link)
    }
}
