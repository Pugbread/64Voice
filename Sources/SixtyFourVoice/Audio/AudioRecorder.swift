@preconcurrency import AVFoundation
import Combine
import CoreAudio
import Foundation

enum AudioRecorderError: LocalizedError {
    case microphoneAccessDenied
    case microphoneAccessNotDetermined
    case noInputDevice
    case inputNotReady(device: String)
    case engineStartFailed(device: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied:
            "Microphone access is off for 64Voice. Turn it on in System Settings › Privacy & Security › Microphone."
        case .microphoneAccessNotDetermined:
            "64Voice needs microphone access. Allow it in the system prompt, then try again."
        case .noInputDevice:
            "No microphone is connected."
        case .inputNotReady(let device):
            "\(device) isn't ready yet. Try again in a moment."
        case .engineStartFailed(let device, let reason):
            "Couldn't start recording from \(device): \(reason)"
        }
    }
}

/// Records from the pinned microphone (or the system default when it's missing) into a
/// 16 kHz mono Float32 buffer.
///
/// Only the resolved input device is opened, directly through CoreAudio, and only while
/// recording. No other device is touched, so e.g. AirPods playing music stay in their
/// high-quality profile while you dictate into the MacBook mic. The system default input is
/// never changed.
///
/// After `onInterruption` fires, capture has stopped but the session stays open
/// (`isRecording` is still true) so `stop()` returns everything captured so far.
@MainActor
final class AudioRecorder {
    /// Main thread, up to 60 Hz while recording, normalized 0...1.
    var onLevel: ((Float) -> Void)?
    /// Main thread. The device vanished or capture failed mid-recording.
    var onInterruption: ((String) -> Void)?

    private(set) var isRecording = false
    private(set) var activeDeviceName: String?
    /// Diagnostics: the device's native input format for the current recording.
    private(set) var activeFormatDescription: String?

    nonisolated var capturedDuration: Double {
        Double(store.count) / captureSampleRate
    }

    private nonisolated let store = SampleStore()
    private let meter = LevelMeter()

    private var capture: CoreAudioInputCapture?
    private var sink: CaptureSink?
    private var captureGeneration = 0
    private var deviceListObserver: AnyCancellable?
    private var activeDevice: AudioInputDevice?
    private var isCapturing = false
    private var restartCount = 0
    private var captureStartUptime: TimeInterval = 0

    private var levelTimer: Timer?
    private var levelPlayback = LevelPlayback(now: 0)

    init() {}

    // MARK: - Public API

    /// Starts recording. Throws `AudioRecorderError` if mic access is missing or the device
    /// can't start. Does nothing if a recording is already in progress.
    func start(preferredUID: String?) throws {
        guard !isRecording else { return }
        try Self.checkMicrophoneAccess()

        let devices = AudioDeviceManager.shared
        var device = devices.resolvedInput(preferredUID: preferredUID)
        if device.map({ !CoreAudioDevices.isAlive($0.id) }) ?? true {
            // A listener notification may still be queued behind us; re-read before giving up.
            devices.refresh()
            device = devices.resolvedInput(preferredUID: preferredUID)
        }
        guard let device else { throw AudioRecorderError.noInputDevice }

        store.reset(reservingSeconds: 60)
        meter.reset()
        restartCount = 0

        var used = device
        do {
            try startCapture(on: device)
        } catch {
            // The pinned device refused to start (exclusive use by another app, exotic format):
            // record from the system default rather than not at all.
            guard let fallback = devices.systemDefaultInput, fallback.id != device.id,
                  (try? startCapture(on: fallback)) != nil
            else { throw error }
            NSLog("64Voice: %@ failed (%@); recording from %@", device.name, error.localizedDescription, fallback.name)
            used = fallback
        }

        activeDevice = used
        activeDeviceName = used.name
        isRecording = true
        isCapturing = true
        startLevelTimer()
        observeDeviceList()
    }

    /// Ends the session and returns all captured audio (16 kHz mono Float32).
    func stop() -> [Float] {
        endSession()
        return store.takeAll()
    }

    /// Ends the session and discards the audio.
    func cancel() {
        endSession()
        store.reset()
    }

    /// Copy of the newest `seconds` of audio. Safe from any thread.
    nonisolated func recentSamples(seconds: Double) -> [Float] {
        store.tail(Int(max(0, seconds) * captureSampleRate))
    }

    // MARK: - Capture

    private func startCapture(on device: AudioInputDevice) throws {
        captureGeneration += 1
        let generation = captureGeneration
        let sink = CaptureSink(store: store, meter: meter)
        let capture: CoreAudioInputCapture
        do {
            capture = try CoreAudioInputCapture(
                deviceID: device.id, sink: sink, onEvent: Self.makeEventHandler(self, generation: generation))
            try capture.start()
        } catch let error as CoreAudioInputCapture.CaptureError {
            sink.close()
            throw AudioRecorderError.engineStartFailed(device: device.name, reason: error.message)
        }
        self.capture = capture
        self.sink = sink
        activeFormatDescription = capture.formatDescription
        captureStartUptime = ProcessInfo.processInfo.systemUptime
    }

    /// Stops the device and flushes everything captured into the store. Keeps the samples.
    private func teardownCapture() {
        captureGeneration += 1  // Ignore events still queued from this capture.
        capture?.stop()
        sink?.close()
        capture = nil
        sink = nil
    }

    private func endSession() {
        isCapturing = false
        isRecording = false
        teardownCapture()
        stopLevelTimer()
        deviceListObserver = nil
        activeDevice = nil
        activeDeviceName = nil
        activeFormatDescription = nil
    }

    private func handle(_ event: CoreAudioInputCapture.Event, generation: Int) {
        guard generation == captureGeneration, isCapturing, let device = activeDevice else { return }
        switch event {
        case .deviceDied:
            interrupt("\(device.name) was disconnected.")
        case .formatChanged, .serviceRestarted:
            restartCapture(stalled: false)
        }
    }

    /// Reopens the same device (keeping the audio captured so far), or reports an
    /// interruption if the device is gone or keeps failing.
    private func restartCapture(stalled: Bool) {
        guard isCapturing, let device = activeDevice else { return }
        teardownCapture()
        guard CoreAudioDevices.isPresent(device.id) else {
            interrupt("\(device.name) was disconnected.")
            return
        }
        guard restartCount < 3 else {
            interrupt(stalled ? "No audio is coming from \(device.name)." : "\(device.name) stopped working.")
            return
        }
        restartCount += 1
        do {
            try startCapture(on: device)
        } catch {
            interrupt("Recording stopped: \(error.localizedDescription)")
        }
    }

    private func observeDeviceList() {
        deviceListObserver = AudioDeviceManager.shared.$inputDevices
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isCapturing, let device = self.activeDevice else { return }
                    if !CoreAudioDevices.isPresent(device.id) {
                        self.interrupt("\(device.name) was disconnected.")
                    }
                }
            }
    }

    private func interrupt(_ message: String) {
        guard isCapturing else { return }
        isCapturing = false
        teardownCapture()
        stopLevelTimer()
        deviceListObserver = nil
        onLevel?(0)
        onInterruption?(message)
    }

    // MARK: - Level meter

    private func startLevelTimer() {
        stopLevelTimer()
        levelPlayback = LevelPlayback(now: ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let level = levelPlayback.step(now: now, meter: meter) {
            onLevel?(level)
        }
        checkForStall(now: now)
    }

    /// A running device always delivers buffers, even silent ones. If none arrive, it stalled
    /// (seen with sleeping Continuity mics and half-connected Bluetooth headsets): reopen it
    /// once or twice, then give up. Bluetooth can take a second or two to deliver the first buffer.
    private func checkForStall(now: TimeInterval) {
        guard isCapturing, capture != nil else { return }
        let lastAudio = store.lastAppendUptime
        let stalled = lastAudio > captureStartUptime
            ? now - lastAudio > 2.5
            : now - captureStartUptime > 5
        if stalled {
            restartCapture(stalled: true)
        }
    }

    // MARK: - Helpers

    private static func checkMicrophoneAccess() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            // Show the system prompt now so the next attempt works.
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            throw AudioRecorderError.microphoneAccessNotDetermined
        default:
            throw AudioRecorderError.microphoneAccessDenied
        }
    }

    /// Built outside the main actor; events arrive on the main queue.
    private nonisolated static func makeEventHandler(
        _ recorder: AudioRecorder, generation: Int
    ) -> @Sendable (CoreAudioInputCapture.Event) -> Void {
        { [weak recorder] event in
            MainActor.assumeIsolated { recorder?.handle(event, generation: generation) }
        }
    }
}
