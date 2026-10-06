import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes a PNG explaining one placement decision. Enabled by `SFV_PLACEMENT_DEBUG=<directory>`.
///
/// Left: the capture with detected text (yellow), caret zones (magenta), the cursor (red cross), every candidate's
/// center colored by cost (green = cheap, red = expensive, gray = rejected), the 5 best (thin green) and the winner
/// (cyan). Right: the busyness heat map with the text mask (blue). Bottom: costs and timings.
enum PlacementDebug {
    static func write(image: CGImage, region: CGRect, request: PlacementRequest, analysis: PlacementAnalysis, to url: URL) {
        let panelW = Int(region.width.rounded())
        let panelH = Int(region.height.rounded())
        let legendH = 54
        let width = panelW * 2 + 12
        let height = panelH + legendH
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Panels are drawn in a top-left coordinate system per panel: (0,0) = region's top-left.
        func withPanel(_ index: Int, _ body: () -> Void) {
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(index * (panelW + 12)), y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.clip(to: CGRect(x: 0, y: 0, width: panelW, height: panelH))
            body()
            ctx.restoreGState()
        }
        func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -region.minX, dy: -region.minY) }
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - region.minX, y: p.y - region.minY) }

        let valid = analysis.candidates.filter { !$0.rejected }
        let costs = valid.map(\.cost).sorted()
        let lo = costs.first ?? 0
        let hi = costs.isEmpty ? 1 : costs[min(costs.count - 1, Int(Double(costs.count) * 0.9))]
        func costColor(_ cost: Double) -> CGColor {
            let t = hi > lo ? min(1, max(0, (cost - lo) / (hi - lo))) : 0
            return CGColor(red: CGFloat(min(1, 2 * t)), green: CGFloat(min(1, 2 * (1 - t))), blue: 0.1, alpha: 0.95)
        }

        func drawOverlays(showText: Bool) {
            if showText {
                ctx.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0, alpha: 0.95))
                ctx.setLineWidth(1.5)
                for box in analysis.textBoxes { ctx.stroke(local(box)) }
            }
            if let caret = analysis.caret {
                ctx.setStrokeColor(CGColor(red: 1, green: 0.2, blue: 0.9, alpha: 0.9))
                ctx.setLineWidth(1.5)
                for zone in PlacementEngine.caretZones(for: caret) { ctx.stroke(local(zone)) }
                ctx.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.9, alpha: 1))
                ctx.fill(local(caret).insetBy(dx: -1, dy: 0))
            }
            for c in analysis.candidates {
                let p = local(CGPoint(x: c.rect.midX, y: c.rect.midY))
                if c.rejected {
                    ctx.setFillColor(CGColor(gray: 0.55, alpha: 0.5))
                    ctx.fill(CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2))
                } else {
                    ctx.setFillColor(costColor(c.cost))
                    ctx.fillEllipse(in: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5))
                }
            }
            ctx.setStrokeColor(CGColor(red: 0.3, green: 1, blue: 0.4, alpha: 0.6))
            ctx.setLineWidth(1)
            for c in valid.sorted(by: { $0.cost < $1.cost }).prefix(5) { ctx.stroke(local(c.rect)) }
            if let current = request.current {
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
                ctx.setLineDash(phase: 0, lengths: [4, 3])
                ctx.stroke(local(current))
                ctx.setLineDash(phase: 0, lengths: [])
            }
            ctx.setStrokeColor(CGColor(red: 0, green: 0.9, blue: 1, alpha: 1))
            ctx.setLineWidth(3)
            ctx.stroke(local(analysis.rect))
            let cur = local(request.cursor)
            ctx.setStrokeColor(CGColor(red: 1, green: 0.15, blue: 0.15, alpha: 1))
            ctx.setLineWidth(2)
            ctx.strokeLineSegments(between: [CGPoint(x: cur.x - 10, y: cur.y), CGPoint(x: cur.x + 10, y: cur.y),
                                             CGPoint(x: cur.x, y: cur.y - 10), CGPoint(x: cur.x, y: cur.y + 10)])
            ctx.setLineWidth(1)
            ctx.stroke(local(PlacementTuning.standard.hotspotGuard.offsetBy(dx: request.cursor.x, dy: request.cursor.y)))
        }

        // Left: capture.
        withPanel(0) {
            ctx.saveGState()
            // CGContext.draw expects a bottom-left space; undo the panel flip for the image.
            ctx.translateBy(x: 0, y: CGFloat(panelH))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: panelW, height: panelH))
            ctx.restoreGState()
            drawOverlays(showText: true)
        }

        // Right: heat map + text mask.
        withPanel(1) {
            let map = analysis.map
            let ox = map.region.minX - region.minX
            let oy = map.region.minY - region.minY
            for row in 0..<map.rows {
                for col in 0..<map.cols {
                    let v = CGFloat(map.busy[row * map.cols + col])
                    ctx.setFillColor(CGColor(red: v, green: v * v * 0.8, blue: 0.08 + (1 - v) * 0.12, alpha: 1))
                    let cell = CGRect(x: ox + CGFloat(col) * map.cell, y: oy + CGFloat(row) * map.cell, width: map.cell, height: map.cell)
                    ctx.fill(cell)
                    if map.text[row * map.cols + col] > 0 {
                        ctx.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 1, alpha: 0.55))
                        ctx.fill(cell)
                    }
                }
            }
            drawOverlays(showText: false)
        }

        // Legend.
        let t = analysis.timings
        let current = analysis.currentCost.map { String(format: "%.3f", $0) } ?? "-"
        let line1 = String(format: "winner cost %.3f  current %@  kept %@  candidates %d (%d valid)  text boxes %d  caret %@",
                           analysis.cost, current, analysis.keptCurrent ? "yes" : "no", analysis.candidates.count, valid.count,
                           analysis.textBoxes.count, analysis.caret == nil ? "no" : "yes")
        let line2 = String(format: "capture %.1f ms  text %.1f ms  map %.1f ms  score %.2f ms  analysis %.1f ms  region %.0fx%.0f pt  notch %.0fx%.0f",
                           t.capture, t.text, t.map, t.score, t.analysis, region.width, region.height,
                           request.notchSize.width, request.notchSize.height)
        drawText(line1, in: ctx, at: CGPoint(x: 10, y: 30))
        drawText(line2, in: ctx, at: CGPoint(x: 10, y: 10))

        guard let out = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        CGImageDestinationAddImage(dest, out, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Watchdog check: the strip beneath the notch (top), its heat map (bottom), text boxes (yellow) and the notch
    /// rect, red if the notch must move, cyan if it may stay.
    static func writeWatch(image: CGImage, check: UnderNotchCheck, map: PlacementBusyMap, to url: URL) {
        let scale: CGFloat = 2
        let region = check.region
        let panelW = Int(region.width * scale)
        let panelH = Int(region.height * scale)
        let legendH = 34
        let width = max(panelW, 560)
        let height = panelH * 2 + 8 + legendH
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        func panel(_ index: Int, _ body: () -> Void) {
            ctx.saveGState()
            // Top-left space in points, panel `index` from the top.
            ctx.translateBy(x: 0, y: CGFloat(height - index * (panelH + 8)))
            ctx.scaleBy(x: scale, y: -scale)
            ctx.translateBy(x: -region.minX, y: -region.minY)
            body()
            ctx.restoreGState()
        }
        let verdict = check.coverage.mustMove
        func overlays() {
            ctx.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0, alpha: 1))
            ctx.setLineWidth(1)
            for box in check.textBoxes { ctx.stroke(box) }
            ctx.setStrokeColor(verdict ? CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1) : CGColor(red: 0, green: 0.9, blue: 1, alpha: 1))
            ctx.setLineWidth(1.5)
            ctx.stroke(check.rect)
        }
        panel(0) {
            ctx.saveGState()
            ctx.translateBy(x: region.minX, y: region.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: region.width, height: region.height))
            ctx.restoreGState()
            overlays()
        }
        panel(1) {
            for row in 0..<map.rows {
                for col in 0..<map.cols {
                    let v = CGFloat(map.busy[row * map.cols + col])
                    ctx.setFillColor(CGColor(red: v, green: v * v * 0.8, blue: 0.08 + (1 - v) * 0.12, alpha: 1))
                    ctx.fill(CGRect(x: map.region.minX + CGFloat(col) * map.cell, y: map.region.minY + CGFloat(row) * map.cell,
                                    width: map.cell, height: map.cell))
                }
            }
            overlays()
        }
        let c = check.coverage
        let line = String(format: "%@  textHit %@  textArea %.2f  busy %.2f  peak %.2f  boxes %d  capture %.1f ms  analysis %.1f ms",
                          verdict ? "MUST MOVE" : "ok", c.textHit ? "yes" : "no", c.textArea, c.busy, c.peak,
                          check.textBoxes.count, check.captureMs, check.analysisMs)
        drawText(line, in: ctx, at: CGPoint(x: 8, y: 11))

        guard let out = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        CGImageDestinationAddImage(dest, out, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func drawText(_ string: String, in ctx: CGContext, at point: CGPoint) {
        let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.92, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = point
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
