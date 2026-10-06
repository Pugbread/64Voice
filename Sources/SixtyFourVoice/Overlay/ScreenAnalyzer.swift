import ApplicationServices
import CoreGraphics
import Foundation
import os
import QuartzCore
import ScreenCaptureKit
import Vision

// Capture + analysis plumbing around the pure `PlacementEngine`. Nothing here runs on the main thread.

// MARK: - Text detection

enum PlacementTextDetector {
    /// Text boxes in the captured `region` (global top-left points), or nil if Vision failed.
    /// Vision's fast rectangle detector.
    static func detect(in image: CGImage, region: CGRect) -> [CGRect]? {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        return (request.results ?? []).map { observation in
            let box = observation.boundingBox // normalized, bottom-left origin
            return CGRect(x: region.minX + box.minX * region.width,
                          y: region.minY + (1 - box.maxY) * region.height,
                          width: box.width * region.width,
                          height: box.height * region.height)
        }
    }

    /// Vision loads its model lazily; do it once off the critical path.
    static func warmUp() {
        let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        guard let image = ctx?.makeImage() else { return }
        _ = detect(in: image, region: CGRect(x: 0, y: 0, width: 64, height: 32))
    }
}

// MARK: - Pipeline (shared by the live analyzer and offline tests)

enum PlacementPipeline {
    /// Text detection + busyness map + scoring on an already-captured image of `region`.
    /// `ownRectVisible`: our notch may appear in the image (the capture couldn't exclude it), so mask it out.
    static func run(image: CGImage, region: CGRect, request: PlacementRequest, caret: CGRect?,
                    ownRectVisible: Bool = false, tuning: PlacementTuning = .standard) -> PlacementAnalysis {
        let t0 = CACurrentMediaTime()
        let detected = PlacementTextDetector.detect(in: image, region: region)
        var boxes = detected ?? []
        let own = ownRectVisible ? request.ownRect?.insetBy(dx: -6, dy: -6) : nil
        if let own {
            boxes.removeAll { box in
                let i = box.intersection(own)
                return !i.isNull && i.width * i.height > 0.4 * box.width * box.height
            }
        }
        let t1 = CACurrentMediaTime()
        var map = PlacementEngine.makeBusyMap(image: image, region: region, tuning: tuning)
        map.markText(boxes, dilation: tuning.textDilation)
        if let own { map.neutralize(own) }
        map.buildIntegrals(peakThreshold: tuning.peakThreshold)
        let t2 = CACurrentMediaTime()
        var analysis = PlacementEngine.choose(request: request, map: map, textBoxes: boxes, caret: caret, tuning: tuning)
        analysis.textDetected = detected != nil
        let t3 = CACurrentMediaTime()
        analysis.timings.text = (t1 - t0) * 1000
        analysis.timings.map = (t2 - t1) * 1000
        analysis.timings.score = (t3 - t2) * 1000
        return analysis
    }
}

// MARK: - Caret (Accessibility)

enum PlacementCaretLocator {
    private static let queue = DispatchQueue(label: "sfv.overlay.caret", qos: .userInitiated)
    private static let busy = OSAllocatedUnfairLock(initialState: false)

    /// Bounds of the focused text caret / selection (global top-left points), or nil. Never blocks longer than
    /// `timeout`; a hung app just means no caret this time.
    static func caretRect(timeout: TimeInterval) async -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        // A previous query is still stuck inside a hung app: don't pile up more.
        guard busy.withLock({ wasBusy in
            if wasBusy { return false }
            wasBusy = true
            return true
        }) else { return nil }

        return await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (CGRect?) -> Void = { rect in
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(returning: rect) }
            }
            queue.async {
                let rect = locate()
                busy.withLock { $0 = false }
                finish(rect)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    private static func locate() -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.06)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let element = focusedRef as! AXUIElement // swiftlint:disable:this force_cast
        AXUIElementSetMessagingTimeout(element, 0.06)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil } // swiftlint:disable:this force_cast

        // A collapsed caret often reports an empty rect: fall back to the character before (or after) it.
        var probes: [(CFRange, Bool)] = [(range, false)]
        if range.length == 0 {
            if range.location > 0 { probes.append((CFRange(location: range.location - 1, length: 1), true)) }
            probes.append((CFRange(location: range.location, length: 1), false))
        }
        for (probe, useTrailingEdge) in probes {
            var r = probe
            guard let value = AXValueCreate(.cfRange, &r) else { continue }
            var boundsRef: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                             value, &boundsRef) == .success,
                  let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { continue }
            var rect = CGRect.zero
            guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { continue } // swiftlint:disable:this force_cast
            guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.height >= 4, rect.height <= 200,
                  rect.width >= 0, rect.width < 4000 else { continue }
            if useTrailingEdge { rect = CGRect(x: rect.maxX, y: rect.minY, width: 1, height: rect.height) }
            return rect
        }
        return nil
    }
}

// MARK: - Live analyzer

struct PlacementOutcome: Sendable {
    var analysis: PlacementAnalysis
    var region: CGRect
    var request: PlacementRequest
}

/// Result of an under-notch watchdog check: what is beneath the notch's rect right now.
struct UnderNotchCheck: Sendable {
    var rect: CGRect
    var region: CGRect
    var coverage: UnderNotchCoverage
    var textBoxes: [CGRect]
    var textDetected: Bool
    var captureMs: Double
    var analysisMs: Double
}

/// Captures screen regions (always excluding our own windows, so it sees what is *beneath* the notch) and runs
/// the placement pipeline or the under-notch check on them.
actor ScreenAnalyzer {
    static let shared = ScreenAnalyzer()

    /// Capture resolution. Vision's text-rectangle detector misses UI-sized (11–13 pt) text at 1 px/pt but finds it
    /// reliably at 1.5 px/pt (~10–15 ms for a 700×580 pt region). The busyness map downsamples to 0.5 px/pt itself.
    static let pixelsPerPoint: CGFloat = 1.5
    /// Margin captured around the notch rect by the watchdog.
    static let watchMargin: CGFloat = 12
    private let contentMaxAge: TimeInterval = 20

    private var content: SCShareableContent?
    private var contentDate = Date.distantPast
    private var contentTask: Task<SCShareableContent?, Never>?
    private var warmedUp = false
    private var debugCounter = 0
    private var watchCounter = 0

    /// Fetch shareable content and load Vision ahead of the first `show`. No-op without permission.
    func prewarm() async {
        guard CGPreflightScreenCaptureAccess() else { return }
        _ = await shareableContent()
        if !warmedUp {
            warmedUp = true
            PlacementTextDetector.warmUp()
        }
    }

    func invalidateContent() {
        content = nil
        contentDate = .distantPast
    }

    private func shareableContent() async -> SCShareableContent? {
        if let content, Date().timeIntervalSince(contentDate) < contentMaxAge { return content }
        if let contentTask { return await contentTask.value }
        let task = Task<SCShareableContent?, Never> {
            try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        contentTask = task
        let fetched = await task.value
        contentTask = nil
        if let fetched {
            content = fetched
            contentDate = Date()
        }
        return fetched
    }

    /// Captures `region` (global top-left points) of one display at `pixelsPerPoint`, excluding our app.
    /// `ownVisible` is true if our windows could not be excluded (then the caller masks the notch itself).
    private func capture(region: CGRect, displayFrame: CGRect,
                         displayID: CGDirectDisplayID) async -> (image: CGImage, ownVisible: Bool)? {
        // Never call into ScreenCaptureKit without permission: that would raise the system prompt.
        guard CGPreflightScreenCaptureAccess(), region.width >= 16, region.height >= 16,
              let content = await shareableContent(),
              let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }

        let filter: SCContentFilter
        let ownVisible: Bool
        let pid = ProcessInfo.processInfo.processIdentifier
        if let me = content.applications.first(where: { $0.processID == pid }) {
            filter = SCContentFilter(display: display, excludingApplications: [me], exceptingWindows: [])
            ownVisible = false
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
            ownVisible = true
        }

        let config = SCStreamConfiguration()
        config.sourceRect = region.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
        config.width = max(1, Int((region.width * Self.pixelsPerPoint).rounded()))
        config.height = max(1, Int((region.height * Self.pixelsPerPoint).rounded()))
        config.scalesToFit = true // otherwise the source is drawn at native scale into the corner of the buffer
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.ignoreShadowsDisplay = true

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return (image, ownVisible)
        } catch {
            invalidateContent()
            return nil
        }
    }

    /// Full placement analysis around the cursor. Nil when there's no Screen Recording permission or the capture
    /// failed; the caller keeps its fallback.
    func analyze(_ request: PlacementRequest, displayID: CGDirectDisplayID) async -> PlacementOutcome? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let tStart = CACurrentMediaTime()
        async let caret = PlacementCaretLocator.caretRect(timeout: 0.08)
        let region = PlacementEngine.captureRegion(for: request)
        guard let shot = await capture(region: region, displayFrame: request.displayFrame, displayID: displayID) else {
            _ = await caret
            return nil
        }
        let tCaptured = CACurrentMediaTime()
        let caretValue = await caret
        let caretRect = caretValue.flatMap { $0.intersects(region) ? $0 : nil }

        var analysis = PlacementPipeline.run(image: shot.image, region: region, request: request, caret: caretRect,
                                             ownRectVisible: shot.ownVisible)
        analysis.timings.capture = (tCaptured - tStart) * 1000

        if let dir = Self.debugDirectory {
            debugCounter += 1
            let url = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "placement-%03d.png", debugCounter))
            PlacementDebug.write(image: shot.image, region: region, request: request, analysis: analysis, to: url)
        }
        return PlacementOutcome(analysis: analysis, region: region, request: request)
    }

    /// Under-notch watchdog: captures just `rect` (+ a small margin) and reports whether text or strongly busy
    /// content is beneath it. About 400×64 pt → ~10 ms capture + ~3 ms analysis.
    func inspect(rect: CGRect, displayFrame: CGRect, displayID: CGDirectDisplayID, ownRect: CGRect?) async -> UnderNotchCheck? {
        let tStart = CACurrentMediaTime()
        let region = rect.insetBy(dx: -Self.watchMargin, dy: -Self.watchMargin).intersection(displayFrame).integral
        guard !region.isNull,
              let shot = await capture(region: region, displayFrame: displayFrame, displayID: displayID) else { return nil }
        let tCaptured = CACurrentMediaTime()

        let detected = PlacementTextDetector.detect(in: shot.image, region: region)
        var boxes = detected ?? []
        var map = PlacementEngine.makeBusyMap(image: shot.image, region: region)
        if shot.ownVisible, let own = ownRect?.insetBy(dx: -6, dy: -6) {
            boxes.removeAll { box in
                let i = box.intersection(own)
                return !i.isNull && i.width * i.height > 0.4 * box.width * box.height
            }
            map.neutralize(own)
        }
        map.markText(boxes, dilation: PlacementTuning.standard.textDilation)
        map.buildIntegrals(peakThreshold: PlacementTuning.standard.peakThreshold)
        // Parts of the rect off the display can't hide anything; judge what is on screen.
        let onScreen = rect.intersection(displayFrame)
        let coverage = PlacementEngine.coverage(of: onScreen.isNull ? rect : onScreen, map: map, textBoxes: boxes)
        let tDone = CACurrentMediaTime()

        let check = UnderNotchCheck(rect: rect, region: region, coverage: coverage, textBoxes: boxes,
                                    textDetected: detected != nil,
                                    captureMs: (tCaptured - tStart) * 1000, analysisMs: (tDone - tCaptured) * 1000)
        if let dir = Self.debugDirectory {
            watchCounter += 1
            let url = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "watch-%03d.png", watchCounter))
            PlacementDebug.writeWatch(image: shot.image, check: check, map: map, to: url)
        }
        return check
    }

    private static var debugDirectory: String? {
        guard let dir = ProcessInfo.processInfo.environment["SFV_PLACEMENT_DEBUG"], !dir.isEmpty else { return nil }
        return dir
    }
}
