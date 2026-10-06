import AppKit
import FluidAudio
import Foundation

/// Developer entry points used from the command line.
@MainActor
enum DevTools {
    /// `64Voice --transcribe file.wav`
    static func transcribeFile(_ path: String) async {
        let url = URL(fileURLWithPath: path)
        do {
            let samples = try AudioConverter().resampleAudioFile(url)
            let loadStart = Date()
            await TranscriptionEngine.shared.prepare()
            let loadTime = Date().timeIntervalSince(loadStart)
            let start = Date()
            let text = try await TranscriptionEngine.shared.transcribe(samples)
            let elapsed = Date().timeIntervalSince(start)
            print(String(format: "model load %.2fs, transcribe %.3fs for %.1fs of audio", loadTime, elapsed, Double(samples.count) / 16_000))
            print(text)
        } catch {
            print("error: \(error)")
        }
    }

    /// `64Voice --demo-overlay`: plays every notch state at the cursor, then quits.
    static func runOverlayDemo() {
        let overlay = OverlayController.shared
        let words = "this is a quick demo of the notch flying into the emptiest space next to your cursor".split(separator: " ")
        overlay.show(phase: .listening)

        Task { @MainActor in
            let start = Date()
            var shown = 0
            while Date().timeIntervalSince(start) < 4.5 {
                let t = Date().timeIntervalSince(start)
                overlay.setLevel(Float(0.35 + 0.35 * sin(t * 9) * sin(t * 2.3)).clamped)
                let target = min(words.count, Int(t * 3.5))
                if target != shown {
                    shown = target
                    overlay.setTranscript(words.prefix(shown).joined(separator: " "))
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
            overlay.setPhase(.transcribing)
            try? await Task.sleep(for: .seconds(1.2))
            overlay.setPhase(.done)
            overlay.hide(after: 0.6)
            try? await Task.sleep(for: .seconds(1.6))
            overlay.show(phase: .error("Mic disconnected"))
            overlay.hide(after: 1.6)
            try? await Task.sleep(for: .seconds(2.4))
            NSApp.terminate(nil)
        }
    }
}

private extension Float {
    var clamped: Float { Swift.min(1, Swift.max(0, self)) }
}
