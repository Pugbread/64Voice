import AppKit
import Combine
import Foundation

/// Runs a dictation session: hotkey → record → live preview → transcribe → paste.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Status: Equatable {
        case idle
        case recording
        case transcribing
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastTranscript = ""

    private let settings = AppSettings.shared
    private let recorder = AudioRecorder()
    private let hotkeys = HotkeyManager()
    private let inserter = TextInserter()
    private var engine: TranscriptionEngine { .shared }
    private var overlay: OverlayController { .shared }

    /// Identifies the current session; async work checks it so a cancelled session can't act.
    private var session: UUID?
    /// Set while the press that started the current recording is still held.
    private var pressStartedAt: Date?
    /// A press that hasn't been held long enough yet to rule out an ⌥-shortcut.
    private var pendingStart: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    /// Keeps timers precise from key press until the session ends (menu bar apps get throttled).
    private var latencyActivity: NSObjectProtocol?

    /// In hybrid mode, a press shorter than this is a tap (hands-free); longer is push-to-talk.
    private let holdThreshold: TimeInterval = 0.3
    /// How long the hotkey must be held alone before the mic opens (see hotkeyDown).
    private let chordGrace: Duration = .milliseconds(140)
    private let sampleRate = 16_000.0

    private init() {}

    func start() {
        hotkeys.onKeyDown = { [weak self] in self?.hotkeyDown() }
        hotkeys.onKeyUp = { [weak self] in self?.hotkeyUp() }
        hotkeys.onChord = { [weak self] in self?.hotkeyChord() }
        hotkeys.onEscape = { [weak self] in self?.cancel() }
        hotkeys.start()

        _ = OverlayController.shared  // prewarms rendering, ScreenCaptureKit and Vision
        recorder.onLevel = { [weak self] level in self?.overlay.setLevel(level) }
        recorder.onInterruption = { [weak self] _ in self?.finishRecording() }

        Task { await engine.prepare() }
    }

    func permissionsMayHaveChanged() {
        if !hotkeys.isRunning { hotkeys.start() }
    }

    func copyLastTranscript() {
        guard !lastTranscript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    // MARK: Hotkey

    // Right Option doubles as AltGr on many layouts (Norwegian ⌥2 = @). The mic only opens
    // once the key has been held alone for `chordGrace`, so typing @ { [ $ never touches it.

    private func hotkeyDown() {
        switch status {
        case .idle:
            guard pendingStart == nil else { return }
            beginLatencyCritical()
            pressStartedAt = Date()
            let grace = chordGrace
            pendingStart = Task { [weak self] in
                try? await Task.sleep(for: grace)
                guard let self, !Task.isCancelled, self.pendingStart != nil else { return }
                self.pendingStart = nil
                self.beginRecording()
            }
        case .recording:
            // Second press while hands-free stops the recording.
            if settings.hotkeyMode != .hold {
                pressStartedAt = nil
                finishRecording()
            }
        case .transcribing:
            break
        }
    }

    private func hotkeyUp() {
        if let pending = pendingStart {
            // Released within the grace period: a quick tap starts hands-free mode.
            pending.cancel()
            pendingStart = nil
            pressStartedAt = nil
            if settings.hotkeyMode != .hold {
                beginRecording()
            } else {
                endLatencyCritical()
            }
            return
        }
        guard status == .recording, let startedAt = pressStartedAt else { return }
        pressStartedAt = nil
        let held = Date().timeIntervalSince(startedAt)
        switch settings.hotkeyMode {
        case .hold:
            finishRecording()
        case .hybrid:
            if held >= holdThreshold { finishRecording() }
        case .toggle:
            break
        }
    }

    /// The hotkey was part of a shortcut (e.g. ⌥A for a special character), not a dictation press.
    private func hotkeyChord() {
        if let pending = pendingStart {
            pending.cancel()
            pendingStart = nil
            pressStartedAt = nil
            endLatencyCritical()
            return
        }
        guard status == .recording, pressStartedAt != nil else { return }
        cancel()
    }

    // MARK: Session

    private func beginRecording() {
        switch PermissionsManager.shared.microphone {
        case .granted:
            break
        case .notDetermined:
            pressStartedAt = nil
            endLatencyCritical()
            Task { _ = await PermissionsManager.shared.requestMicrophone() }
            return
        case .denied:
            pressStartedAt = nil
            endLatencyCritical()
            showTransientError("Microphone access is off")
            SettingsWindowController.shared.show()
            return
        }

        do {
            try recorder.start(preferredUID: settings.preferredMicUID)
        } catch {
            pressStartedAt = nil
            endLatencyCritical()
            showTransientError(error.localizedDescription)
            return
        }

        let id = UUID()
        session = id
        status = .recording
        hotkeys.interceptEscape = true
        Sounds.playStart()
        overlay.setTranscript("")
        overlay.show(phase: .listening)
        startLivePreview(session: id)
    }

    private func startLivePreview(session id: UUID) {
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, !Task.isCancelled, self.session == id, self.status == .recording else { return }
                guard self.settings.showLiveTranscript,
                      self.engine.state == .ready,
                      self.recorder.capturedDuration > 0.6
                else { continue }

                let samples = self.recorder.recentSamples(seconds: 12)
                guard let text = try? await self.engine.transcribe(samples),
                      self.session == id, self.status == .recording
                else { continue }
                self.overlay.setTranscript(text)
            }
        }
    }

    private func finishRecording() {
        guard status == .recording, let id = session else { return }
        previewTask?.cancel()
        pressStartedAt = nil

        let samples = recorder.stop()
        Sounds.playStop()

        guard Double(samples.count) / sampleRate >= 0.3 else {
            endSession()
            overlay.hide()
            return
        }

        status = .transcribing
        overlay.show(phase: .transcribing)
        if engine.state != .ready {
            overlay.setTranscript("Loading speech model…")
        }

        Task { [weak self] in
            guard let self else { return }
            await self.engine.prepare()
            guard self.session == id else { return }

            do {
                let raw = try await self.engine.transcribe(samples)
                guard self.session == id else { return }
                let text = Self.clean(raw)
                guard !text.isEmpty else {
                    self.overlay.setPhase(.error("Didn't catch that"))
                    self.overlay.hide(after: 1.1)
                    self.endSession()
                    return
                }

                let output = CaretContext.needsLeadingSpace(before: text) ? " " + text : text
                self.lastTranscript = text
                if await self.inserter.insert(output) {
                    self.overlay.setPhase(.done)
                    self.overlay.hide(after: 0.6)
                } else {
                    self.copyLastTranscript()
                    Sounds.playError()
                    self.overlay.setPhase(.error("Couldn't paste. Copied instead"))
                    self.overlay.hide(after: 1.8)
                }
            } catch {
                guard self.session == id else { return }
                Sounds.playError()
                self.overlay.setPhase(.error(error.localizedDescription))
                self.overlay.hide(after: 1.8)
            }
            self.endSession()
        }
    }

    /// Escape, a chord, or a too-short press: drop everything without pasting.
    private func cancel() {
        guard status != .idle else { return }
        previewTask?.cancel()
        if recorder.isRecording { recorder.cancel() }
        pressStartedAt = nil
        endSession()
        overlay.hide()
    }

    private func endSession() {
        session = nil
        status = .idle
        hotkeys.interceptEscape = false
        endLatencyCritical()
    }

    private func beginLatencyCritical() {
        guard latencyActivity == nil else { return }
        latencyActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Dictation in progress"
        )
    }

    private func endLatencyCritical() {
        guard let activity = latencyActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        latencyActivity = nil
    }

    private func showTransientError(_ message: String) {
        Sounds.playError()
        overlay.show(phase: .error(message))
        overlay.hide(after: 1.8)
    }

    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
