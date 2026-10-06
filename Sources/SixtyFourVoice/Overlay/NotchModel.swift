import AppKit
import SwiftUI

// MARK: - Style

enum NotchStyle {
    static let height: CGFloat = 40
    static let maxWidth: CGFloat = 360
    /// Transparent margin around the pill inside the panel: room for the shadow, the entrance overshoot and the shake.
    static let marginX: CGFloat = 44
    static let marginY: CGFloat = 36
    static var panelSize: CGSize { CGSize(width: maxWidth + marginX * 2, height: height + marginY * 2) }

    static let fontSize: CGFloat = 13
    static let font = Font.system(size: fontSize, weight: .medium)
    static let nsFont = NSFont.systemFont(ofSize: fontSize, weight: .medium)
    static let spaceWidth: CGFloat = ceil((" " as NSString).size(withAttributes: [.font: nsFont]).width * 100) / 100

    static let red = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let green = Color(red: 0.19, green: 0.80, blue: 0.35)

    /// SwiftUI animation for a layout change, built from the same `OverlaySpring` the controller uses to shift the
    /// window, so a growing pill keeps its cursor-side edge still.
    static func animation(_ p: OverlaySpring) -> Animation {
        .spring(response: p.response, dampingFraction: p.damping)
    }
}

// MARK: - Metrics

/// Deterministic layout of the pill: [pad][leading glyph][gap][waveform/dots][gap][text][pad].
/// Computed (not measured by SwiftUI) so the controller knows the target size before SwiftUI animates to it.
struct NotchMetrics: Equatable {
    var padLeading: CGFloat = 16
    var leading: CGFloat = 0
    var gap1: CGFloat = 0
    var center: CGFloat = 0
    var gap2: CGFloat = 0
    var text: CGFloat = 0
    var padTrailing: CGFloat = 16
    var textOverflows = false

    var width: CGFloat { padLeading + leading + gap1 + center + gap2 + text + padTrailing }
    var size: CGSize { CGSize(width: width, height: NotchStyle.height) }

    static var waveWidth: CGFloat { NotchWaveformState.size.width } // 9 bars × 3 pt + 8 gaps × 2.5 pt
    static let dotsWidth: CGFloat = 30

    static func make(phase: OverlayPhase, transcriptWidth: CGFloat, errorWidth: CGFloat) -> NotchMetrics {
        var m = NotchMetrics()
        switch phase {
        case .listening:
            m.leading = 8
            m.gap1 = 10
            m.center = waveWidth
            if transcriptWidth > 0 {
                m.gap2 = 11
                m.padTrailing = 17
                let available = NotchStyle.maxWidth - (m.padLeading + m.leading + m.gap1 + m.center + m.gap2 + m.padTrailing)
                m.text = min(transcriptWidth, available)
                m.textOverflows = transcriptWidth > available + 0.5
            }
        case .transcribing:
            m.padLeading = 15
            m.padTrailing = 15
            m.center = dotsWidth
            if transcriptWidth > 0 {
                m.gap2 = 10
                m.padTrailing = 17
                let available = NotchStyle.maxWidth - (m.padLeading + m.center + m.gap2 + m.padTrailing)
                m.text = min(transcriptWidth, available)
                m.textOverflows = transcriptWidth > available + 0.5
            }
        case .done:
            m.padLeading = 9
            m.padTrailing = 9
            m.leading = 22
        case .error:
            m.padLeading = 9
            m.padTrailing = 16
            m.leading = 22
            if errorWidth > 0 {
                m.gap1 = 9
                let available = NotchStyle.maxWidth - (m.padLeading + m.leading + m.gap1 + m.padTrailing)
                m.text = min(errorWidth, available)
            }
        }
        return m
    }
}

// MARK: - Transcript words

struct NotchTranscriptWord: Identifiable, Equatable {
    let id: Int
    let text: String
    let width: CGFloat
}

/// Turns successive live transcripts into a word list with stable identities, so SwiftUI can slide existing words
/// and fade in only the new ones (instead of crossfading the whole line every update).
@MainActor
final class NotchTranscriptDiffer {
    private(set) var words: [NotchTranscriptWord] = []
    private var nextID = 0
    private var widthCache: [String: CGFloat] = [:]

    /// Only the tail that can be visible is kept (plus some slack for the leading fade).
    private let keepWidth = NotchStyle.maxWidth + 120

    func reset() { words = [] }

    func update(_ text: String) -> [NotchTranscriptWord] {
        let tokens = text.split(whereSeparator: \.isWhitespace).suffix(80).map(String.init)
        guard !tokens.isEmpty else {
            words = []
            return words
        }
        let old = words
        let n = old.count
        let m = tokens.count

        // Longest run of identical consecutive words shared by the old list and the new text. Handles a growing
        // tail, a head trimmed off for display, and a live-preview window that dropped words at its start.
        var runLength = 0
        var runOld = 0
        var runNew = 0
        if n > 0 {
            var previous = [Int](repeating: 0, count: m + 1)
            var current = [Int](repeating: 0, count: m + 1)
            for i in 1...n {
                for j in 1...m {
                    if old[i - 1].text == tokens[j - 1] {
                        current[j] = previous[j - 1] + 1
                        if current[j] > runLength {
                            runLength = current[j]
                            runOld = i - runLength
                            runNew = j - runLength
                        }
                    } else {
                        current[j] = 0
                    }
                }
                swap(&previous, &current)
            }
        }

        var result: [NotchTranscriptWord] = []
        result.reserveCapacity(m)
        if runLength == 0 {
            result = tokens.map(makeWord)
        } else {
            // Before the run: walk backward the same way (a word revised near the start keeps its neighbors).
            var head: [NotchTranscriptWord] = []
            var hi = runOld - 1
            var hj = runNew - 1
            while hj >= 0 {
                let token = tokens[hj]
                if hi >= 0, old[hi].text == token {
                    head.append(old[hi])
                    hi -= 1
                } else if hi >= 1, old[hi - 1].text == token {
                    head.append(old[hi - 1])
                    hi -= 2
                } else {
                    head.append(makeWord(token))
                    if hi >= 1, hj >= 1, old[hi - 1].text == tokens[hj - 1] { hi -= 1 }
                }
                hj -= 1
            }
            result += head.reversed()
            result += old[runOld..<(runOld + runLength)]
            // After the run: keep identities where words still line up, allowing a dropped or replaced word.
            var oi = runOld + runLength
            var j = runNew + runLength
            while j < m {
                let token = tokens[j]
                if oi < n, old[oi].text == token {
                    result.append(old[oi])
                    oi += 1
                } else if oi + 1 < n, old[oi + 1].text == token {
                    result.append(old[oi + 1]) // a word was dropped
                    oi += 2
                } else {
                    result.append(makeWord(token))
                    // Replaced in place: keep the old pointer aligned with what follows.
                    if oi + 1 < n, j + 1 < m, old[oi + 1].text == tokens[j + 1] { oi += 1 }
                }
                j += 1
            }
        }

        // Trim the head to what can be seen.
        var total: CGFloat = 0
        var firstVisible = result.count
        for index in result.indices.reversed() {
            total += result[index].width + NotchStyle.spaceWidth
            firstVisible = index
            if total > keepWidth { break }
        }
        words = Array(result[firstVisible...])
        return words
    }

    static func lineWidth(_ words: [NotchTranscriptWord]) -> CGFloat {
        guard !words.isEmpty else { return 0 }
        return words.reduce(0) { $0 + $1.width } + NotchStyle.spaceWidth * CGFloat(words.count - 1)
    }

    private func makeWord(_ text: String) -> NotchTranscriptWord {
        defer { nextID += 1 }
        return NotchTranscriptWord(id: nextID, text: text, width: width(of: text))
    }

    private func width(of word: String) -> CGFloat {
        if let cached = widthCache[word] { return cached }
        let w = ceil((word as NSString).size(withAttributes: [.font: NotchStyle.nsFont]).width)
        if widthCache.count > 2000 { widthCache.removeAll(keepingCapacity: true) }
        widthCache[word] = w
        return w
    }

    static func measure(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NotchStyle.nsFont]).width)
    }
}

// MARK: - Model

/// What the SwiftUI notch renders. Only discrete changes live here (phase, words, layout); per-frame motion
/// (presence, waveform) is applied to Core Animation layers by `OverlayController` and never invalidates SwiftUI.
@MainActor
final class NotchModel: ObservableObject {
    @Published var phase: OverlayPhase = .listening
    @Published var words: [NotchTranscriptWord] = []
    /// Width of the words that the latest transcript update inserted.
    var insertShift: CGFloat = 0
    @Published var metrics = NotchMetrics.make(phase: .listening, transcriptWidth: 0, errorWidth: 0)
    @Published var reduceMotion = false

    /// Mic level and waveform state, rendered every frame into CALayers.
    let wave = NotchWaveformState()

    var errorMessage: String? {
        if case let .error(message) = phase { return message }
        return nil
    }
}
