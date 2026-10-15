@preconcurrency import AVFoundation
import Combine
import CoreAudio
import Foundation
import Synchronization

/// Plays the pinned mic into "64Voice Mic", the virtual input installed by
/// scripts/install-mic-driver.sh, and silences it while dictating. Choose 64Voice Mic as the
/// input in Discord (or any call app) and you're muted there whenever you talk to 64Voice.
///
/// The driver (Driver/) publishes two devices that share one loopback buffer: the visible,
/// input-only "64Voice Mic" and the hidden, output-only "64Voice Mic Feed". 64Voice only ever
/// opens the feed, so "64Voice Mic is running somewhere" means another app is listening, and only
/// then is the real mic opened. Nobody listening: no mic, no orange dot.
@MainActor
final class VirtualMicBridge: ObservableObject {
    static let shared = VirtualMicBridge()

    /// Set by Driver/VirtualMicConfig.h.
    nonisolated static let micUID = "64VoiceMic_UID"
    nonisolated static let feedUID = "64VoiceMic_2_UID"

    enum Status: Equatable {
        case notInstalled
        case off
        case needsMicAccess
        /// Installed, but no app is listening to 64Voice Mic.
        case waiting
        case live(source: String)
        case failed(String)
    }

    @Published private(set) var status: Status = .notInstalled
    /// True while dictation has 64Voice Mic silenced.
    @Published private(set) var isMuted = false

    private let settings = AppSettings.shared
    private let gate = MicGate()
    private var passthrough: MicPassthrough?
    private var watchedMic: (id: AudioDeviceID, block: AudioObjectPropertyListenerBlock)?
    private var observers: Set<AnyCancellable> = []
    private var evaluatePending = false
    private var stopWork: DispatchWorkItem?
    private var unmuteWork: DispatchWorkItem?
    private var isStarted = false

    /// Stay muted this long after dictation ends, so the last syllable doesn't reach the call.
    private let unmuteDelay: TimeInterval = 0.25
    /// Apps briefly stop and restart input when they switch devices; don't churn the real mic.
    private let stopDelay: TimeInterval = 1.0

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        installSystemListeners()
        // @Published fires before the value is stored, so re-read everything on the next turn.
        let changes: [AnyPublisher<Void, Never>] = [
            settings.$feedVirtualMic.map { _ in }.eraseToAnyPublisher(),
            settings.$preferredMicUID.map { _ in }.eraseToAnyPublisher(),
            AudioDeviceManager.shared.$inputDevices.map { _ in }.eraseToAnyPublisher(),
            AudioDeviceManager.shared.$systemDefaultInput.map { _ in }.eraseToAnyPublisher(),
            PermissionsManager.shared.$microphone.map { _ in }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .sink { [weak self] in self?.scheduleEvaluate() }
            .store(in: &observers)
        evaluate()
    }

    /// AppState calls this with true from the hotkey press until the recording ends.
    func setDictating(_ dictating: Bool) {
        unmuteWork?.cancel()
        unmuteWork = nil
        if dictating {
            gate.muted.store(true, ordering: .relaxed)
            if !isMuted { isMuted = true }
        } else if isMuted {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.gate.muted.store(false, ordering: .relaxed)
                    self.isMuted = false
                }
            }
            unmuteWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + unmuteDelay, execute: work)
        }
    }

    // MARK: - State

    private func scheduleEvaluate() {
        guard !evaluatePending else { return }
        evaluatePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.evaluatePending = false
                self.evaluate()
            }
        }
    }

    private func evaluate() {
        let micID = CoreAudioDevices.deviceID(uid: Self.micUID)
        watchRunningState(of: micID)

        guard let micID, let feedID = CoreAudioDevices.deviceID(uid: Self.feedUID) else {
            stopPassthrough()
            setStatus(.notInstalled)
            return
        }
        guard settings.feedVirtualMic else {
            stopPassthrough()
            setStatus(.off)
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            stopPassthrough()
            setStatus(.needsMicAccess)
            return
        }
        guard CoreAudioDevices.isRunningSomewhere(micID) else {
            scheduleStop()
            return
        }
        stopWork?.cancel()
        stopWork = nil

        guard let source = AudioDeviceManager.shared.resolvedInput(preferredUID: settings.preferredMicUID) else {
            stopPassthrough()
            setStatus(.failed("No microphone is connected."))
            return
        }
        if let passthrough, passthrough.sourceID == source.id, passthrough.feedID == feedID {
            setStatus(.live(source: source.name))
            return
        }

        stopPassthrough()
        do {
            passthrough = try MicPassthrough(source: source, feedID: feedID, gate: gate)
            setStatus(.live(source: source.name))
        } catch {
            NSLog("64Voice: 64Voice Mic couldn't start from %@: %@", source.name, error.localizedDescription)
            setStatus(.failed(error.localizedDescription))
        }
    }

    private func scheduleStop() {
        guard passthrough != nil else {
            setStatus(.waiting)
            return
        }
        guard stopWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stopWork = nil
                if let micID = CoreAudioDevices.deviceID(uid: Self.micUID), CoreAudioDevices.isRunningSomewhere(micID) {
                    return
                }
                self.stopPassthrough()
                self.setStatus(.waiting)
            }
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stopDelay, execute: work)
    }

    private func stopPassthrough() {
        stopWork?.cancel()
        stopWork = nil
        passthrough?.stop()
        passthrough = nil
    }

    private func setStatus(_ new: Status) {
        if status != new { status = new }
    }

    // MARK: - Listeners

    /// Device list changes cover installing/removing the driver and mics coming and going.
    private func installSystemListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyServiceRestarted] {
            var address = CoreAudioDevices.globalAddress(selector)
            let isRestart = selector == kAudioHardwarePropertyServiceRestarted
            AudioObjectAddPropertyListenerBlock(system, &address, DispatchQueue.main) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if isRestart {
                        // Every device ID is stale; the old aggregate is gone with the old server.
                        self.stopPassthrough()
                        self.watchRunningState(of: nil)
                    }
                    self.scheduleEvaluate()
                }
            }
        }
    }

    /// Follows "is any app listening to 64Voice Mic".
    private func watchRunningState(of micID: AudioDeviceID?) {
        guard watchedMic?.id != micID else { return }
        var address = CoreAudioDevices.globalAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        if let watchedMic {
            AudioObjectRemovePropertyListenerBlock(watchedMic.id, &address, DispatchQueue.main, watchedMic.block)
            self.watchedMic = nil
        }
        guard let micID else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleEvaluate() }
        }
        if AudioObjectAddPropertyListenerBlock(micID, &address, DispatchQueue.main, block) == noErr {
            watchedMic = (micID, block)
        }
    }
}

// MARK: - Passthrough

/// A private aggregate of the source mic (clock) and the feed device (drift-corrected), with one
/// IOProc that copies the mic into every feed channel through the mute gate. The aggregate keeps
/// the two clocks in step, so there's no buffer to drift and crackle over a long call.
final class MicPassthrough {
    struct PassthroughError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let sourceID: AudioDeviceID
    let feedID: AudioDeviceID
    private var aggregateID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    init(source: AudioInputDevice, feedID: AudioDeviceID, gate: MicGate) throws {
        sourceID = source.id
        self.feedID = feedID

        // Sub-devices of an aggregate run at one rate. The feed follows the mic.
        if let rate = CoreAudioDevices.nominalSampleRate(source.id),
           CoreAudioDevices.nominalSampleRate(feedID) != rate
        {
            CoreAudioDevices.setNominalSampleRate(feedID, rate)
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "64Voice Mic Bridge",
            kAudioAggregateDeviceUIDKey: "com.pug64.64voice.mic-bridge.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: source.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: source.uid],
                [kAudioSubDeviceUIDKey: VirtualMicBridge.feedUID, kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]
        var status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            throw PassthroughError(message: "couldn't combine \(source.name) with 64Voice Mic (\(CoreAudioInputCapture.describe(status)))")
        }

        do {
            guard let inputFormat = CoreAudioDevices.firstStreamFormat(aggregateID, scope: kAudioObjectPropertyScopeInput),
                  let layout = InputLayout(inputFormat)
            else { throw PassthroughError(message: "\(source.name) has an unsupported format") }
            guard let outputFormat = CoreAudioDevices.firstStreamFormat(aggregateID, scope: kAudioObjectPropertyScopeOutput),
                  outputFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0, outputFormat.mBitsPerChannel == 32
            else { throw PassthroughError(message: "64Voice Mic has an unexpected format") }

            // ~5 ms at 48 kHz. Keeps the added call latency small.
            var frames: UInt32 = 256
            var address = CoreAudioDevices.globalAddress(kAudioDevicePropertyBufferFrameSize)
            AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

            var procID: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(
                &procID, aggregateID, nil,
                Self.makeIOBlock(gate: gate, layout: layout, sampleRate: inputFormat.mSampleRate))
            guard status == noErr, let procID else {
                throw PassthroughError(message: "couldn't open 64Voice Mic (\(CoreAudioInputCapture.describe(status)))")
            }
            ioProcID = procID
            status = AudioDeviceStart(aggregateID, procID)
            guard status == noErr else {
                throw PassthroughError(message: "\(source.name) didn't start (\(CoreAudioInputCapture.describe(status)))")
            }
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
    }

    /// Idempotent. 64Voice Mic goes silent once the IOProc stops writing.
    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioDeviceID(kAudioObjectUnknown)
        }
    }

    /// Built in a nonisolated static context so the block never inherits an actor.
    private static func makeIOBlock(gate: MicGate, layout: InputLayout, sampleRate: Double) -> AudioDeviceIOBlock {
        let fallStep = Float(1 / (0.005 * sampleRate))  // mute in 5 ms
        let riseStep = Float(1 / (0.02 * sampleRate))   // unmute in 20 ms
        return { _, inputData, _, outputData, _ in
            gate.render(from: inputData, to: outputData, layout: layout, fallStep: fallStep, riseStep: riseStep)
        }
    }
}

// MARK: - Gate

/// The mute switch and its gain ramp. Outlives individual passthroughs so a rebuild mid-dictation
/// stays muted.
final class MicGate: @unchecked Sendable {
    let muted = Atomic<Bool>(false)
    /// IO thread only. Only one passthrough runs at a time.
    private var gain: Float = 1

    /// IO thread. Writes the mic (first one or two channels averaged) into every output channel.
    @inline(__always)
    func render(
        from inputData: UnsafePointer<AudioBufferList>, to outputData: UnsafeMutablePointer<AudioBufferList>,
        layout: InputLayout, fallStep: Float, riseStep: Float
    ) {
        // Output buffers aren't guaranteed to arrive zeroed.
        let outputs = UnsafeMutableAudioBufferListPointer(outputData)
        var frames = Int.max
        for buffer in outputs {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
            if buffer.mNumberChannels > 0 {
                frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * Int(buffer.mNumberChannels)))
            }
        }

        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let input = inputs.first(where: { $0.mData != nil && $0.mNumberChannels > 0 }),
              let source = input.mData.map(UnsafeRawPointer.init)
        else { return }
        let inChannels = Int(input.mNumberChannels)
        frames = min(frames, Int(input.mDataByteSize) / (layout.bytesPerSample * inChannels))
        guard frames > 0, frames != .max else { return }
        let averageTwo = layout.channelsToUse > 1 && inChannels > 1

        let target: Float = muted.load(ordering: .relaxed) ? 0 : 1
        var gain = self.gain
        for frame in 0..<frames {
            if gain != target {
                gain = gain < target ? min(target, gain + riseStep) : max(target, gain - fallStep)
            }
            var sample = layout.sample(source, frame * inChannels)
            if averageTwo {
                sample = (sample + layout.sample(source, frame * inChannels + 1)) * 0.5
            }
            sample *= gain
            for buffer in outputs {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = Int(buffer.mNumberChannels)
                for channel in 0..<channels {
                    data[frame * channels + channel] = sample
                }
            }
        }
        self.gain = gain
    }
}
