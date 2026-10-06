import CoreGraphics
import Foundation

// Smart placement: "fly into the emptiest space near the cursor".
//
// Everything in this file is pure: it takes a captured image plus geometry and returns a decision, so it can be
// driven from a live ScreenCaptureKit capture (`ScreenAnalyzer`) or from a PNG on disk (tests / debugging).
//
// Coordinates: global *top-left* screen space in points (origin at the top-left of the primary display, y grows
// downward). That is the space CGWindowList, ScreenCaptureKit and Accessibility use. `OverlayController`
// converts to AppKit's bottom-left space at the boundary.

struct PlacementRequest: Sendable {
    /// Cursor hotspot.
    var cursor: CGPoint
    /// Size of the notch pill (without shadow).
    var notchSize: CGSize
    /// Frame of the display the cursor is on.
    var displayFrame: CGRect
    /// Display frame minus menu bar and Dock.
    var visibleFrame: CGRect
    /// Where the notch would sit if it kept its current relative spot (for hysteresis). `nil` on first placement.
    var current: CGRect?
    /// Where our own notch is drawn right now. Only used if the capture could not exclude our windows.
    var ownRect: CGRect?
}

struct PlacementTuning: Sendable {
    /// Free space between the cursor hotspot and the notch edge, per candidate ring.
    var gaps: [CGFloat] = [14, 24, 38, 56, 80, 110, 150, 195, 240]
    var angleCount = 24
    /// Margin around the notch that also counts when measuring busyness (so it lands with breathing room).
    var breathingRoom: CGFloat = 8
    /// Margin around the notch for the text-overlap test.
    var textRoom: CGFloat = 3
    /// Detected text boxes are grown by this much before scoring.
    var textDilation: CGFloat = 4
    /// Keep this far inside the visible frame (menu bar, Dock, screen edges).
    var edgeInset: CGFloat = 8
    /// Area around the hotspot the notch must never cover. Relative to the hotspot; the arrow and the
    /// I-beam extend down and right of it.
    var hotspotGuard = CGRect(x: -14, y: -14, width: 36, height: 44)

    // Cost weights.
    var wBusy = 1.6
    var wPeak = 1.0
    var wText = 5.0
    var wTextAny = 0.9
    var wCaret = 4.0
    var wCaretAny = 1.2
    var wDistance = 0.55
    var wDirection = 0.07
    var wTight = 0.04
    /// Flying across text on the way there (fraction of the path where the pill would cover text).
    var wPath = 0.6

    /// Hysteresis: switch only if the best spot costs less than `switchRatio` × the current one
    /// and the absolute improvement is at least `switchFloor`.
    var switchRatio = 0.75
    var switchFloor = 0.06

    /// Points per busyness cell, points per analysis pixel.
    var cell: CGFloat = 4
    var pixel: CGFloat = 2
    /// Busyness above this counts as "busy" for the peak term.
    var peakThreshold: Float = 0.45

    static let standard = PlacementTuning()
}

struct PlacementCandidate: Sendable {
    var rect: CGRect
    var gap: CGFloat
    var busy: Double = 0
    var peak: Double = 0
    var text: Double = 0
    var caret: Double = 0
    var cost: Double = .infinity
    var rejected = false
}

struct PlacementTimings: Sendable {
    var capture: Double = 0
    var text: Double = 0
    var map: Double = 0
    var score: Double = 0
    /// Analysis only (text + map + score), excluding the capture.
    var analysis: Double { text + map + score }
}

struct PlacementAnalysis: Sendable {
    var rect: CGRect
    var cost: Double
    var currentCost: Double?
    var keptCurrent: Bool
    var candidates: [PlacementCandidate]
    var map: PlacementBusyMap
    var textBoxes: [CGRect]
    var caret: CGRect?
    var timings = PlacementTimings()
    /// False if Vision failed: text avoidance then relies on busyness only.
    var textDetected = true
}

/// What is under a given notch rect, according to an analyzed map.
struct UnderNotchCoverage: Sendable {
    /// Text would be (partly) hidden: ≥ 6 pt of a text box's width and ≥ a quarter of its height.
    var textHit: Bool
    /// Fraction of the rect covered by raw text boxes.
    var textArea: Double
    /// Mean busyness and fraction of busy cells under the rect (unanalyzed parts count as busy).
    var busy: Double
    var peak: Double
    /// The rect lies entirely inside the analyzed region.
    var analyzed: Bool

    /// Strongly busy: most of the rect sits on dense UI, images or video.
    var stronglyBusy: Bool { busy >= 0.5 && peak >= 0.5 }
    /// Covering this is not allowed: the notch has to move (not merely "could do better").
    var mustMove: Bool { textHit || stronglyBusy }
}

// MARK: - Busyness map

/// A coarse grid over the captured region: per-cell busyness (edges + local contrast) and a text mask,
/// each with a summed-area table so any rectangle's mean is O(1).
struct PlacementBusyMap: Sendable {
    let region: CGRect
    let cell: CGFloat
    let cols: Int
    let rows: Int
    var busy: [Float]
    var text: [Float]
    private(set) var busyII: [Double] = []
    private(set) var peakII: [Double] = []
    private(set) var textII: [Double] = []

    init(region: CGRect, cell: CGFloat, cols: Int, rows: Int, busy: [Float]) {
        self.region = region
        self.cell = cell
        self.cols = cols
        self.rows = rows
        self.busy = busy
        self.text = [Float](repeating: 0, count: cols * rows)
    }

    /// Cells covered by `rect`, clamped to the grid. Half-open ranges.
    func cellRange(_ rect: CGRect) -> (c0: Int, r0: Int, c1: Int, r1: Int)? {
        let c0 = max(0, Int(((rect.minX - region.minX) / cell).rounded(.down)))
        let r0 = max(0, Int(((rect.minY - region.minY) / cell).rounded(.down)))
        let c1 = min(cols, Int(((rect.maxX - region.minX) / cell).rounded(.up)))
        let r1 = min(rows, Int(((rect.maxY - region.minY) / cell).rounded(.up)))
        guard c1 > c0, r1 > r0 else { return nil }
        return (c0, r0, c1, r1)
    }

    mutating func markText(_ boxes: [CGRect], dilation: CGFloat) {
        for box in boxes {
            guard let r = cellRange(box.insetBy(dx: -dilation, dy: -dilation)) else { continue }
            for row in r.r0..<r.r1 {
                for col in r.c0..<r.c1 { text[row * cols + col] = 1 }
            }
        }
    }

    /// Our own notch showed up in the capture: treat its area as mildly busy, never as text.
    mutating func neutralize(_ rect: CGRect) {
        guard let r = cellRange(rect) else { return }
        for row in r.r0..<r.r1 {
            for col in r.c0..<r.c1 {
                busy[row * cols + col] = 0.15
                text[row * cols + col] = 0
            }
        }
    }

    mutating func buildIntegrals(peakThreshold: Float) {
        busyII = Self.integral(cols: cols, rows: rows) { Double(busy[$0]) }
        peakII = Self.integral(cols: cols, rows: rows) { busy[$0] > peakThreshold ? 1 : 0 }
        textII = Self.integral(cols: cols, rows: rows) { Double(text[$0]) }
    }

    private static func integral(cols: Int, rows: Int, value: (Int) -> Double) -> [Double] {
        let stride = cols + 1
        var ii = [Double](repeating: 0, count: stride * (rows + 1))
        for row in 0..<rows {
            var rowSum = 0.0
            for col in 0..<cols {
                rowSum += value(row * cols + col)
                ii[(row + 1) * stride + col + 1] = ii[row * stride + col + 1] + rowSum
            }
        }
        return ii
    }

    /// Mean of a summed-area table over the cells `rect` touches. Cells outside the grid were never analyzed and
    /// count as `outside` (default: fully busy / fully text, never empty).
    func mean(_ ii: [Double], over rect: CGRect, outside: Double = 1) -> Double {
        let totalCols = max(1, Int((rect.width / cell).rounded(.up)))
        let totalRows = max(1, Int((rect.height / cell).rounded(.up)))
        let total = Double(totalCols * totalRows)
        guard let r = cellRange(rect) else { return outside }
        let stride = cols + 1
        let sum = ii[r.r1 * stride + r.c1] - ii[r.r0 * stride + r.c1] - ii[r.r1 * stride + r.c0] + ii[r.r0 * stride + r.c0]
        let inside = Double((r.c1 - r.c0) * (r.r1 - r.r0))
        let missing = max(0, total - inside)
        return (sum + missing * outside) / max(inside + missing, 1)
    }
}

// MARK: - Engine

enum PlacementEngine {
    /// The screen region worth capturing for a request: enough to hold every candidate, clipped to the display.
    static func captureRegion(for request: PlacementRequest, tuning: PlacementTuning = .standard) -> CGRect {
        let maxGap = tuning.gaps.max() ?? 240
        let room = tuning.breathingRoom + 8
        let halfW = min(maxGap + request.notchSize.width, 440) + room
        let halfH = maxGap + request.notchSize.height + room
        let rect = CGRect(x: request.cursor.x - halfW, y: request.cursor.y - halfH, width: halfW * 2, height: halfH * 2)
        return rect.intersection(request.displayFrame).integral
    }

    /// Grayscale → Sobel gradient magnitude + local contrast, pooled into `tuning.cell`-point cells.
    static func makeBusyMap(image: CGImage, region: CGRect, tuning: PlacementTuning = .standard) -> PlacementBusyMap {
        let pxPerCell = max(1, Int((tuning.cell / tuning.pixel).rounded()))
        let cols = max(1, Int((region.width / tuning.cell).rounded(.down)))
        let rows = max(1, Int((region.height / tuning.cell).rounded(.down)))
        let w = cols * pxPerCell
        let h = rows * pxPerCell

        // 1. Downsample to 8-bit gray. Bitmap row 0 is the top of the image.
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            ctx.interpolationQuality = .medium
            let drawW = region.width / tuning.pixel
            let drawH = region.height / tuning.pixel
            ctx.draw(image, in: CGRect(x: 0, y: CGFloat(h) - drawH, width: drawW, height: drawH))
        }

        let cellCount = cols * rows
        var edgeSum = [Float](repeating: 0, count: cellCount)
        var lumSum = [Float](repeating: 0, count: cellCount)
        var lumSq = [Float](repeating: 0, count: cellCount)

        // 2. Sobel magnitude and luminance moments per cell.
        bytes.withUnsafeBufferPointer { src in
            edgeSum.withUnsafeMutableBufferPointer { edge in
                lumSum.withUnsafeMutableBufferPointer { sum in
                    lumSq.withUnsafeMutableBufferPointer { sq in
                        let k: Float = 1.0 / 255.0
                        for y in 0..<h {
                            let cellRow = (y / pxPerCell) * cols
                            let interiorY = y > 0 && y < h - 1
                            for x in 0..<w {
                                let i = y * w + x
                                let c = cellRow + x / pxPerCell
                                let g = Float(src[i]) * k
                                sum[c] += g
                                sq[c] += g * g
                                if interiorY, x > 0, x < w - 1 {
                                    let tl = Float(src[i - w - 1]), t = Float(src[i - w]), tr = Float(src[i - w + 1])
                                    let l = Float(src[i - 1]), r = Float(src[i + 1])
                                    let bl = Float(src[i + w - 1]), b = Float(src[i + w]), br = Float(src[i + w + 1])
                                    let gx = (tr + 2 * r + br) - (tl + 2 * l + bl)
                                    let gy = (bl + 2 * b + br) - (tl + 2 * t + tr)
                                    edge[c] += (gx * gx + gy * gy).squareRoot() * k
                                }
                            }
                        }
                    }
                }
            }
        }

        // 3. Combine: mean edge strength per cell, and luminance spread over the 3×3 cell neighborhood.
        let perCell = Float(pxPerCell * pxPerCell)
        var busy = [Float](repeating: 0, count: cellCount)
        for row in 0..<rows {
            for col in 0..<cols {
                let idx = row * cols + col
                let edge = edgeSum[idx] / perCell
                var s: Float = 0, s2: Float = 0, n: Float = 0
                for dr in -1...1 {
                    let rr = row + dr
                    guard rr >= 0, rr < rows else { continue }
                    for dc in -1...1 {
                        let cc = col + dc
                        guard cc >= 0, cc < cols else { continue }
                        s += lumSum[rr * cols + cc]
                        s2 += lumSq[rr * cols + cc]
                        n += perCell
                    }
                }
                let mean = s / n
                let std = max(0, s2 / n - mean * mean).squareRoot()
                let edgeTerm = min(1, max(0, (edge - 0.04) / 0.55))
                let contrastTerm = min(1, max(0, (std - 0.03) / 0.22))
                busy[idx] = max(edgeTerm, 0.85 * contrastTerm)
            }
        }

        // 4. Dilate by one cell so the notch keeps a little distance from busy things.
        var dilated = busy
        for row in 0..<rows {
            for col in 0..<cols {
                var m: Float = 0
                for rr in max(0, row - 1)...min(rows - 1, row + 1) {
                    for cc in max(0, col - 1)...min(cols - 1, col + 1) { m = max(m, busy[rr * cols + cc]) }
                }
                dilated[row * cols + col] = m
            }
        }

        let covered = CGRect(x: region.minX, y: region.minY,
                             width: CGFloat(cols) * tuning.cell, height: CGFloat(rows) * tuning.cell)
        return PlacementBusyMap(region: covered, cell: tuning.cell, cols: cols, rows: rows, busy: dilated)
    }

    /// Candidate rectangles around the cursor: rings of constant free gap × angles, plus classic tooltip anchors.
    static func candidates(for request: PlacementRequest, tuning: PlacementTuning = .standard) -> [PlacementCandidate] {
        let w = request.notchSize.width
        let h = request.notchSize.height
        let hw = w / 2
        let hh = h / 2
        let p = request.cursor
        var out: [PlacementCandidate] = []
        out.reserveCapacity(tuning.gaps.count * tuning.angleCount + 8)

        for gap in tuning.gaps {
            for k in 0..<tuning.angleCount {
                let theta = Double(k) / Double(tuning.angleCount) * 2 * Double.pi
                let dx = cos(theta)
                let dy = sin(theta)
                let tx = abs(dx) > 1e-6 ? Double(hw) / abs(dx) : .infinity
                let ty = abs(dy) > 1e-6 ? Double(hh) / abs(dy) : .infinity
                let d = Double(gap) + min(tx, ty)
                let c = CGPoint(x: p.x + CGFloat(dx * d), y: p.y + CGFloat(dy * d))
                out.append(PlacementCandidate(rect: CGRect(x: c.x - hw, y: c.y - hh, width: w, height: h), gap: gap))
            }
        }

        let anchors: [CGPoint] = [
            CGPoint(x: p.x + 14, y: p.y + 26),         // below-right (tooltip)
            CGPoint(x: p.x - hw, y: p.y + 30),         // below, centered
            CGPoint(x: p.x - hw, y: p.y - 18 - h),     // above, centered
            CGPoint(x: p.x + 10, y: p.y - 16 - h),     // above-right
            CGPoint(x: p.x + 26, y: p.y - hh),         // right
            CGPoint(x: p.x - 18 - w, y: p.y - hh),     // left
            CGPoint(x: p.x - 10 - w, y: p.y + 26),     // below-left
            CGPoint(x: p.x - 10 - w, y: p.y - 16 - h), // above-left
        ]
        for origin in anchors {
            let rect = CGRect(origin: origin, size: request.notchSize)
            out.append(PlacementCandidate(rect: rect, gap: distance(from: p, to: rect)))
        }
        return out
    }

    /// Scores every candidate and picks the winner, with hysteresis against `request.current`.
    static func choose(request: PlacementRequest, map: PlacementBusyMap, textBoxes: [CGRect], caret: CGRect?,
                       tuning: PlacementTuning = .standard) -> PlacementAnalysis {
        let caretZones = caret.map(caretZones(for:)) ?? []
        var candidates = candidates(for: request, tuning: tuning)
        for i in candidates.indices {
            score(&candidates[i], request: request, map: map, caretZones: caretZones, tuning: tuning)
        }

        var currentCost: Double?
        if let current = request.current {
            var c = PlacementCandidate(rect: current, gap: distance(from: request.cursor, to: current))
            score(&c, request: request, map: map, caretZones: caretZones, tuning: tuning)
            if !c.rejected { currentCost = c.cost }
        }

        let best = candidates.filter { !$0.rejected }.min { $0.cost < $1.cost }
        guard let best else {
            // Nothing valid (tiny screen?): keep what we have, else fall back to geometry.
            let rect = request.current ?? geometricFallback(cursor: request.cursor, size: request.notchSize,
                                                             visibleFrame: request.visibleFrame, tuning: tuning)
            return PlacementAnalysis(rect: rect, cost: .infinity, currentCost: currentCost, keptCurrent: request.current != nil,
                                     candidates: candidates, map: map, textBoxes: textBoxes, caret: caret)
        }

        if let current = request.current, let currentCost {
            let better = best.cost < currentCost * tuning.switchRatio && currentCost - best.cost >= tuning.switchFloor
            if !better {
                return PlacementAnalysis(rect: current, cost: currentCost, currentCost: currentCost, keptCurrent: true,
                                         candidates: candidates, map: map, textBoxes: textBoxes, caret: caret)
            }
        }
        return PlacementAnalysis(rect: best.rect, cost: best.cost, currentCost: currentCost, keptCurrent: false,
                                 candidates: candidates, map: map, textBoxes: textBoxes, caret: caret)
    }

    static func score(_ c: inout PlacementCandidate, request: PlacementRequest, map: PlacementBusyMap, caretZones: [CGRect],
                      tuning: PlacementTuning) {
        let rect = c.rect
        let allowed = request.visibleFrame.insetBy(dx: tuning.edgeInset, dy: tuning.edgeInset)
        let hotspot = tuning.hotspotGuard.offsetBy(dx: request.cursor.x, dy: request.cursor.y)
        // Every candidate must lie entirely inside what was actually captured and analyzed.
        guard allowed.contains(rect), map.region.insetBy(dx: -0.5, dy: -0.5).contains(rect), !rect.intersects(hotspot) else {
            c.rejected = true
            c.cost = .infinity
            return
        }
        let roomy = rect.insetBy(dx: -tuning.breathingRoom, dy: -tuning.breathingRoom)
        c.busy = map.mean(map.busyII, over: roomy)
        c.peak = map.mean(map.peakII, over: roomy)
        c.text = map.mean(map.textII, over: rect.insetBy(dx: -tuning.textRoom, dy: -tuning.textRoom))

        let area = Double(rect.width * rect.height)
        let probe = rect.insetBy(dx: -4, dy: -4)
        c.caret = caretZones.reduce(0) { worst, zone in
            let i = probe.intersection(zone)
            return i.isNull ? worst : max(worst, min(1, Double(i.width * i.height) / area))
        }

        let maxGap = Double(tuning.gaps.max() ?? 240)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let vx = Double(center.x - request.cursor.x)
        let vy = Double(center.y - request.cursor.y)
        let len = max((vx * vx + vy * vy).squareRoot(), 1e-6)
        let cosToBelowRight = (vx + vy) / (len * 2.0.squareRoot()) // y grows downward: (1, 1) is below-right

        // Prefer spots the notch can reach without flying across text (it travels in a straight line).
        var pathCost = 0.0
        if let own = request.ownRect, tuning.wPath > 0 {
            let hw = own.width / 2
            let destX = rect.width > own.width ? min(max(own.midX, rect.minX + hw), rect.maxX - hw) : rect.midX
            let from = CGPoint(x: own.midX, y: own.midY)
            let to = CGPoint(x: destX, y: rect.midY)
            let samples = 6
            var crossing = 0
            for k in 1...samples {
                let t = CGFloat(k) / CGFloat(samples + 1)
                let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                let pill = CGRect(x: p.x - hw, y: p.y - own.height / 2, width: own.width, height: own.height)
                if map.mean(map.textII, over: pill) > 0.08 { crossing += 1 }
            }
            pathCost = Double(crossing) / Double(samples)
        }

        var cost = tuning.wBusy * c.busy + tuning.wPeak * c.peak + tuning.wPath * pathCost
        cost += tuning.wText * c.text + (c.text > 0.01 ? tuning.wTextAny : 0)
        cost += tuning.wCaret * c.caret + (c.caret > 0 ? tuning.wCaretAny : 0)
        cost += tuning.wDistance * min(1.5, Double(c.gap) / maxGap)
        cost += tuning.wDirection * (1 - cosToBelowRight) / 2
        if c.gap < 20 { cost += tuning.wTight }
        c.cost = cost
    }

    /// What lies under `rect` according to `map` (+ the raw text boxes found in the same capture).
    static func coverage(of rect: CGRect, map: PlacementBusyMap, textBoxes: [CGRect]) -> UnderNotchCoverage {
        let analyzed = map.region.insetBy(dx: -0.5, dy: -0.5).contains(rect)
        var hit = false
        var area: CGFloat = 0
        for box in textBoxes {
            let i = box.intersection(rect)
            guard !i.isNull, i.width > 0, i.height > 0 else { continue }
            area += i.width * i.height
            // Covering a quarter of a line's height already makes it hard to read.
            if i.width >= 6, i.height >= max(3, box.height * 0.25) { hit = true }
        }
        let rectArea = max(rect.width * rect.height, 1)
        return UnderNotchCoverage(textHit: hit, textArea: Double(min(1, area / rectArea)),
                                  busy: map.mean(map.busyII, over: rect), peak: map.mean(map.peakII, over: rect),
                                  analyzed: analyzed)
    }

    /// Where dictated text will appear: around the caret, and along its line (mostly to the right of it).
    static func caretZones(for caret: CGRect) -> [CGRect] {
        let height = max(caret.height, 12)
        return [
            CGRect(x: caret.minX - 24, y: caret.minY - 14, width: caret.width + 48, height: height + 28),
            CGRect(x: caret.minX - 90, y: caret.minY - 6, width: 90 + 520, height: height + 12),
        ]
    }

    /// No screen access or smart placement off: below-right of the cursor, flipped near screen edges.
    static func geometricFallback(cursor: CGPoint, size: CGSize, visibleFrame: CGRect,
                                  tuning: PlacementTuning = .standard) -> CGRect {
        let inset = tuning.edgeInset
        let allowed = visibleFrame.insetBy(dx: inset, dy: inset)
        var rect = CGRect(x: cursor.x + 18, y: cursor.y + 30, width: size.width, height: size.height)
        if rect.maxX > allowed.maxX { rect.origin.x = cursor.x - 18 - size.width }
        if rect.maxY > allowed.maxY { rect.origin.y = cursor.y - 22 - size.height }
        rect.origin.x = min(max(rect.minX, allowed.minX), max(allowed.minX, allowed.maxX - size.width))
        rect.origin.y = min(max(rect.minY, allowed.minY), max(allowed.minY, allowed.maxY - size.height))
        return rect
    }

    static func distance(from p: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
        let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
