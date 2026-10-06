@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// Input-only capture from exactly one CoreAudio device, via a device IOProc.
///
/// Nothing else is opened: no I/O unit bound to the default input, no output device, no
/// aggregate. AVAudioEngine touches the default devices even when its input is routed elsewhere;
/// in testing that briefly stopped AirPods playback while recording from the MacBook mic.
///
/// The IOProc runs on the HAL's realtime thread and only downmixes into a preallocated
/// lock-free ring. A 10 ms timer on a private queue drains the ring into the `CaptureSink`
/// (resampling to 16 kHz, sample store, level meter).
final class CoreAudioInputCapture: @unchecked Sendable {
    enum Event: Sendable {
        /// Sample rate, stream layout or sample format changed: rebuild the capture.
        case formatChanged
        /// The device stopped being alive (unplugged, Bluetooth dropped).
        case deviceDied
        /// coreaudiod restarted; every device ID may be stale.
        case serviceRestarted
    }

    struct CaptureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let deviceID: AudioDeviceID
    let sampleRate: Double
    /// e.g. "48000 Hz, 1 ch Float32 (using 1)"
    let formatDescription: String

    private let layout: InputLayout
    private let ring = SampleRing(capacityLog2: 18)  // 262k samples: ~5 s at 48 kHz
    private let sink: CaptureSink
    private let drainQueue = DispatchQueue(label: "64Voice.capture.drain", qos: .userInteractive)
    private let listenerQueue = DispatchQueue(label: "64Voice.capture.listeners", qos: .userInitiated)
    private let onEvent: @Sendable (Event) -> Void
    private let scratch: AVAudioPCMBuffer
    private var ioProcID: AudioDeviceIOProcID?
    private var drainTimer: DispatchSourceTimer?
    private var listeners: [Listener] = []
    private var isStopped = false

    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    /// Prepares capture (reads the format, registers the IOProc and listeners) without starting IO.
    /// `onEvent` is called on the main queue.
    init(deviceID: AudioDeviceID, sink: CaptureSink, onEvent: @escaping @Sendable (Event) -> Void) throws {
        self.deviceID = deviceID
        self.sink = sink
        self.onEvent = onEvent

        guard let snapshot = Self.readInputFormat(deviceID) else {
            throw CaptureError(message: "the device has no input stream")
        }
        guard let layout = InputLayout(snapshot.format) else {
            throw CaptureError(message: "unsupported audio format (\(Self.describe(snapshot.format)))")
        }
        self.layout = layout
        self.sampleRate = snapshot.format.mSampleRate
        self.formatDescription = "\(Self.describe(snapshot.format)), \(snapshot.streamCount) stream(s), using \(layout.channelsToUse) ch"

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
            let scratch = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 16_384)
        else {
            throw CaptureError(message: "couldn't allocate audio buffers")
        }
        self.scratch = scratch

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID, deviceID, nil, Self.makeIOBlock(ring: ring, layout: layout))
        guard status == noErr, let procID else {
            throw CaptureError(message: "couldn't open the device (\(Self.describe(status)))")
        }
        ioProcID = procID
        installListeners(streams: snapshot.streams)
    }

    deinit {
        // Owners call stop() first. If not, release the device without draining: the last
        // reference may be dropped on the drain queue itself, where a sync drain would deadlock.
        stop(drainingTail: false)
    }

    /// Starts IO on the device. Throws if the HAL refuses (e.g. another app has exclusive access).
    func start() throws {
        guard let ioProcID, !isStopped else { throw CaptureError(message: "capture was already stopped") }
        let status = AudioDeviceStart(deviceID, ioProcID)
        guard status == noErr else {
            throw CaptureError(message: Self.startFailureMessage(status))
        }
        let timer = DispatchSource.makeTimerSource(queue: drainQueue)
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        drainTimer = timer
    }

    /// Stops IO, hands every sample already captured to the sink, and releases the device.
    /// Idempotent. Call from one thread at a time (the recorder uses the main thread).
    func stop() {
        stop(drainingTail: true)
    }

    private func stop(drainingTail: Bool) {
        guard !isStopped else { return }
        isStopped = true
        removeListeners()
        if let ioProcID {
            // Synchronous with the IO thread: the IOProc won't run again once this returns.
            AudioDeviceStop(deviceID, ioProcID)
        }
        drainTimer?.cancel()
        drainTimer = nil
        if drainingTail {
            drainQueue.sync { drain() }
        }
        if let ioProcID {
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            self.ioProcID = nil
        }
    }

    /// Samples dropped because the drain queue fell more than ~5 s behind (should stay 0).
    var droppedCallbacks: Int { ring.dropped.load(ordering: .relaxed) }

    // MARK: - Draining

    private func drain() {
        guard let destination = scratch.floatChannelData?[0] else { return }
        while true {
            let count = ring.read(into: destination, maxCount: Int(scratch.frameCapacity))
            guard count > 0 else { return }
            scratch.frameLength = AVAudioFrameCount(count)
            sink.process(scratch)
        }
    }

    // MARK: - Realtime IOProc

    /// Built in a nonisolated static context so the block never inherits an actor.
    private static func makeIOBlock(ring: SampleRing, layout: InputLayout) -> AudioDeviceIOBlock {
        { _, inputData, _, _, _ in
            ring.write(from: inputData, layout: layout)
        }
    }

    // MARK: - Listeners

    private func installListeners(streams: [AudioStreamID]) {
        let device = deviceID
        var targets: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (device, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput),
            (device, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
            (AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyServiceRestarted, kAudioObjectPropertyScopeGlobal),
        ]
        for stream in streams {
            targets.append((stream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal))
        }

        for (object, selector, scope) in targets {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.propertyChanged(selector)
            }
            if AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block) == noErr {
                listeners.append(Listener(object: object, address: address, block: block))
            }
        }
    }

    private func removeListeners() {
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, listenerQueue, listener.block)
        }
        listeners.removeAll()
    }

    /// Runs on `listenerQueue`.
    private func propertyChanged(_ selector: AudioObjectPropertySelector) {
        switch selector {
        case kAudioDevicePropertyDeviceIsAlive:
            if !CoreAudioDevices.isAlive(deviceID) { post(.deviceDied) }
        case kAudioHardwarePropertyServiceRestarted:
            ring.isOpen.store(false, ordering: .releasing)
            post(.serviceRestarted)
        default:
            // Ignore notifications that didn't actually change what the IOProc decodes.
            if let snapshot = Self.readInputFormat(deviceID),
               snapshot.format.mSampleRate == sampleRate,
               InputLayout(snapshot.format) == layout
            {
                return
            }
            // Stop publishing right away: until the rebuild, buffers would be decoded with the old format.
            ring.isOpen.store(false, ordering: .releasing)
            post(.formatChanged)
        }
    }

    private func post(_ event: Event) {
        let onEvent = onEvent
        DispatchQueue.main.async { onEvent(event) }
    }

    // MARK: - Format

    private struct FormatSnapshot {
        let format: AudioStreamBasicDescription
        let streams: [AudioStreamID]
        var streamCount: Int { streams.count }
    }

    /// The first input stream's virtual format: the format the IOProc receives.
    private static func readInputFormat(_ deviceID: AudioDeviceID) -> FormatSnapshot? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard streams.withUnsafeMutableBytes({ raw in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw.baseAddress!)
        }) == noErr, let first = streams.first else { return nil }

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(first, &formatAddress, 0, nil, &formatSize, &format) == noErr,
              format.mSampleRate > 0
        else { return nil }
        return FormatSnapshot(format: format, streams: streams)
    }

    static func describe(_ format: AudioStreamBasicDescription) -> String {
        let flags = format.mFormatFlags
        let kind = flags & kAudioFormatFlagIsFloat != 0 ? "Float\(format.mBitsPerChannel)" : "Int\(format.mBitsPerChannel)"
        let interleaving = flags & kAudioFormatFlagIsNonInterleaved != 0 ? "non-interleaved" : "interleaved"
        return "\(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) ch \(kind) \(interleaving)"
    }

    static func describe(_ status: OSStatus) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: UInt32(bitPattern: status) >> $0) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return "'\(String(decoding: bytes, as: UTF8.self))'"
        }
        return "OSStatus \(status)"
    }

    private static func startFailureMessage(_ status: OSStatus) -> String {
        if status == kAudioDevicePermissionsError {
            return "another app is using it exclusively"
        }
        return "the device didn't start (\(describe(status)))"
    }
}

// MARK: - Input layout

/// How to decode the first one or two channels of the IOProc's input buffers into mono Float.
struct InputLayout: Equatable, Sendable {
    enum SampleKind: Equatable, Sendable { case float32, int16, int24, int32 }

    let kind: SampleKind
    let bytesPerSample: Int
    /// Channels averaged into mono: the first two (on multichannel virtual and aggregate devices
    /// the signal lives there; averaging all 16 BlackHole channels would bury it), never more
    /// than the first stream has, so streams with different formats are never mixed.
    let channelsToUse: Int

    init?(_ format: AudioStreamBasicDescription) {
        let flags = format.mFormatFlags
        guard format.mFormatID == kAudioFormatLinearPCM,
              flags & kAudioFormatFlagIsBigEndian == 0,
              format.mChannelsPerFrame > 0, format.mBytesPerFrame > 0
        else { return nil }
        let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let divisor = nonInterleaved ? 1 : Int(format.mChannelsPerFrame)
        guard Int(format.mBytesPerFrame) % divisor == 0 else { return nil }
        let bytes = Int(format.mBytesPerFrame) / divisor

        if flags & kAudioFormatFlagIsFloat != 0 {
            guard format.mBitsPerChannel == 32, bytes == 4 else { return nil }
            kind = .float32
        } else if flags & kAudioFormatFlagIsSignedInteger != 0 {
            switch (format.mBitsPerChannel, bytes) {
            case (16, 2): kind = .int16
            case (24, 3): kind = .int24
            case (32, 4): kind = .int32
            default: return nil
            }
        } else {
            return nil
        }
        bytesPerSample = bytes
        channelsToUse = min(2, Int(format.mChannelsPerFrame))
    }

    @inline(__always)
    func sample(_ base: UnsafeRawPointer, _ index: Int) -> Float {
        let offset = index * bytesPerSample
        switch kind {
        case .float32:
            return base.loadUnaligned(fromByteOffset: offset, as: Float.self)
        case .int16:
            return Float(base.loadUnaligned(fromByteOffset: offset, as: Int16.self)) / 32_768
        case .int32:
            return Float(Double(base.loadUnaligned(fromByteOffset: offset, as: Int32.self)) / 2_147_483_648)
        case .int24:
            let b0 = Int32(base.load(fromByteOffset: offset, as: UInt8.self))
            let b1 = Int32(base.load(fromByteOffset: offset + 1, as: UInt8.self))
            let b2 = Int32(base.load(fromByteOffset: offset + 2, as: UInt8.self))
            let value = ((b0 | (b1 << 8) | (b2 << 16)) << 8) >> 8  // sign-extend 24 -> 32 bits
            return Float(value) / 8_388_608
        }
    }
}

// MARK: - Lock-free ring

/// Single-producer (HAL IO thread) / single-consumer (drain queue) ring of mono Float samples.
/// The producer never blocks or allocates; if the consumer falls behind it drops whole callbacks.
final class SampleRing: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    let dropped = Atomic<Int>(0)
    /// Cleared when the device format changes, so stale-format buffers aren't decoded.
    let isOpen = Atomic<Bool>(true)

    init(capacityLog2: Int) {
        capacity = 1 << capacityLog2
        mask = capacity - 1
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
    }

    /// IO thread. Averages up to `layout.channelsToUse` leading channels into the ring.
    @inline(__always)
    func write(from inputData: UnsafePointer<AudioBufferList>, layout: InputLayout) {
        guard isOpen.load(ordering: .acquiring) else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))

        var frames = Int.max
        var source0: UnsafeRawPointer?
        var stride0 = 1
        var channel0 = 0
        var source1: UnsafeRawPointer?
        var stride1 = 1
        var channel1 = 0
        var found = 0
        for buffer in buffers {
            guard found < layout.channelsToUse else { break }
            guard let data = buffer.mData, buffer.mNumberChannels > 0, buffer.mDataByteSize > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            // Frame count comes from the buffer's real layout, not the ASBD (they can disagree mid-route-change).
            frames = min(frames, Int(buffer.mDataByteSize) / (layout.bytesPerSample * channels))
            var channel = 0
            while channel < channels, found < layout.channelsToUse {
                if found == 0 {
                    source0 = UnsafeRawPointer(data); stride0 = channels; channel0 = channel
                } else {
                    source1 = UnsafeRawPointer(data); stride1 = channels; channel1 = channel
                }
                found += 1
                channel += 1
            }
        }
        guard let source0, frames > 0, frames != .max else { return }

        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        guard capacity - (write - read) >= frames else {
            dropped.add(1, ordering: .relaxed)
            return
        }

        if let source1 {
            for frame in 0..<frames {
                let a = layout.sample(source0, frame * stride0 + channel0)
                let b = layout.sample(source1, frame * stride1 + channel1)
                storage[(write + frame) & mask] = (a + b) * 0.5
            }
        } else {
            for frame in 0..<frames {
                storage[(write + frame) & mask] = layout.sample(source0, frame * stride0 + channel0)
            }
        }
        writeIndex.store(write + frames, ordering: .releasing)
    }

    /// Consumer side. Copies up to `maxCount` samples out; returns how many.
    func read(into destination: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        let write = writeIndex.load(ordering: .acquiring)
        let read = readIndex.load(ordering: .relaxed)
        let count = min(write - read, maxCount)
        guard count > 0 else { return 0 }
        let start = read & mask
        let firstPart = min(count, capacity - start)
        destination.update(from: storage + start, count: firstPart)
        if count > firstPart {
            (destination + firstPart).update(from: storage, count: count - firstPart)
        }
        readIndex.store(read + count, ordering: .releasing)
        return count
    }
}
