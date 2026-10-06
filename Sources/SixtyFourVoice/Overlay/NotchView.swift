import SwiftUI

/// The black, Dynamic-Island-like pill. All geometry comes from `NotchMetrics`; all animation is driven by the
/// controller wrapping model changes in explicit animations.
struct NotchView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let m = model.metrics
        ZStack {
            NotchSurface(errorTint: model.errorMessage != nil)
            HStack(spacing: 0) {
                leadingSlot
                    .frame(width: m.leading, height: NotchStyle.height)
                Color.clear.frame(width: m.gap1)
                centerSlot
                    .frame(width: m.center, height: NotchStyle.height)
                Color.clear.frame(width: m.gap2)
                textSlot(m)
                    .frame(width: m.text, height: NotchStyle.height)
            }
            .padding(.leading, m.padLeading)
            .padding(.trailing, m.padTrailing)
            .frame(width: m.width, height: NotchStyle.height, alignment: .leading)
            .clipShape(Capsule(style: .continuous))
        }
        .frame(width: m.width, height: NotchStyle.height)
        .frame(width: NotchStyle.panelSize.width, height: NotchStyle.panelSize.height)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var leadingSlot: some View {
        ZStack {
            switch model.phase {
            case .listening:
                NotchRecordingDot(reduceMotion: model.reduceMotion)
                    .frame(width: 8, height: 8)
                    .transition(.notchIcon)
            case .transcribing:
                Color.clear.frame(width: 0, height: 0)
            case .done:
                NotchCheckBadge(reduceMotion: model.reduceMotion)
                    .transition(.notchIcon)
            case .error:
                NotchErrorBadge()
                    .transition(.notchIcon)
            }
        }
    }

    @ViewBuilder private var centerSlot: some View {
        ZStack {
            if model.phase == .listening || model.phase == .transcribing {
                NotchWaveformBars(state: model.wave)
                    .frame(width: NotchWaveformState.size.width, height: NotchWaveformState.size.height)
                    .transition(.notchIcon)
            }
        }
    }

    @ViewBuilder private func textSlot(_ m: NotchMetrics) -> some View {
        ZStack(alignment: .leading) {
            if let message = model.errorMessage {
                Text(message)
                    .font(NotchStyle.font)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: m.text, alignment: .leading)
                    .fixedSize()
                    .transition(.notchText)
            } else if (model.phase == .listening || model.phase == .transcribing) && !model.words.isEmpty {
                NotchTranscriptLine(words: model.words, insertShift: model.insertShift, width: m.text,
                                    overflows: m.textOverflows, dimmed: model.phase == .transcribing)
                    .transition(.notchText)
            }
        }
        .frame(width: m.text, height: NotchStyle.height, alignment: .leading)
    }
}

// MARK: - Surface

struct NotchSurface: View {
    let errorTint: Bool

    var body: some View {
        let shape = Capsule(style: .continuous)
        shape
            .fill(Color(white: 0.015))
            // Soft inner glow along the top, so the pill has a lit edge on dark backgrounds.
            .overlay {
                shape.fill(LinearGradient(colors: [.white.opacity(0.075), .white.opacity(0)],
                                          startPoint: .top, endPoint: .center))
            }
            .overlay {
                shape.fill(RadialGradient(colors: [NotchStyle.red.opacity(errorTint ? 0.30 : 0), .clear],
                                          center: .leading, startRadius: 0, endRadius: 150))
            }
            // Hairline: brighter on top, fading toward the bottom.
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.07)],
                                                  startPoint: .top, endPoint: .bottom),
                                   lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.22), radius: 1, x: 0, y: 0.5)
            .shadow(color: .black.opacity(0.32), radius: 12, x: 0, y: 6)
    }
}

// MARK: - Transcript

/// One line of live transcript: the tail stays pinned to the trailing edge, older words slide left under a fade,
/// new words fade in from a blur. Word identities come from `NotchTranscriptDiffer`.
struct NotchTranscriptLine: View {
    let words: [NotchTranscriptWord]
    /// Width of the words inserted by the latest update (they slide in by this much).
    let insertShift: CGFloat
    let width: CGFloat
    let overflows: Bool
    let dimmed: Bool

    var body: some View {
        Color.clear
            .overlay(alignment: .trailing) {
                HStack(spacing: NotchStyle.spaceWidth) {
                    ForEach(words) { word in
                        Text(word.text)
                            .font(NotchStyle.font)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                            .transition(.notchWord(shift: insertShift))
                    }
                }
                .fixedSize()
                .opacity(dimmed ? 0.55 : 0.93)
            }
            .mask(alignment: .leading) {
                // Leading fade when the line overflows. The mask also reaches into the trailing padding with a short
                // fade, so words sliding in from the right appear softly instead of being cut at the slot edge.
                let total = max(width + Self.trailingReveal, 1)
                let fade = overflows ? min(0.35, 30 / total) : 0
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: fade),
                                       .init(color: .black, location: max(fade, width / total)),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: total)
            }
    }

    static let trailingReveal: CGFloat = 13
}

// MARK: - Badges

struct NotchCheckBadge: View {
    let reduceMotion: Bool
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Circle().fill(NotchStyle.green)
            NotchCheckmarkShape()
                .trim(from: 0, to: progress)
                .stroke(.white, style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round))
                .frame(width: 10, height: 8)
                .offset(x: -0.25, y: 0.25)
        }
        .frame(width: 22, height: 22)
        .onAppear {
            if reduceMotion {
                progress = 1
            } else {
                withAnimation(.easeOut(duration: 0.26).delay(0.1)) { progress = 1 }
            }
        }
    }
}

struct NotchCheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

struct NotchErrorBadge: View {
    var body: some View {
        ZStack {
            Circle().fill(NotchStyle.red)
            Image(systemName: "exclamationmark")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: 22, height: 22)
    }
}

// MARK: - Motion helpers

/// Icons swap with scale + blur + opacity (0.25 → 1, 4 pt → 0, 0 → 1).
private struct BlurScaleFade: ViewModifier {
    let opacity: Double
    let scale: CGFloat
    let blur: CGFloat
    var x: CGFloat = 0
    let y: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .blur(radius: blur)
            .offset(x: x, y: y)
            .opacity(opacity)
    }
}

extension AnyTransition {
    static var notchIcon: AnyTransition {
        .modifier(active: BlurScaleFade(opacity: 0, scale: 0.25, blur: 4, y: 0),
                  identity: BlurScaleFade(opacity: 1, scale: 1, blur: 0, y: 0))
    }

    static var notchText: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurScaleFade(opacity: 0, scale: 0.96, blur: 4, y: 0),
                                 identity: BlurScaleFade(opacity: 1, scale: 1, blur: 0, y: 0)),
            removal: .modifier(active: BlurScaleFade(opacity: 0, scale: 0.98, blur: 3, y: 0),
                               identity: BlurScaleFade(opacity: 1, scale: 1, blur: 0, y: 0))
        )
    }

    /// New words enter from `shift` points to the right (the width of everything inserted in this update), so they
    /// travel with the older words sliding left instead of popping in at their final spot and overlapping them.
    static func notchWord(shift: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurScaleFade(opacity: 0, scale: 1, blur: 5, x: shift, y: 2),
                                 identity: BlurScaleFade(opacity: 1, scale: 1, blur: 0, y: 0)),
            removal: .opacity
        )
    }
}
