@preconcurrency import AVFoundation
import Foundation
import os

/// Sample rate of everything the recorder hands out (what Parakeet expects).
let captureSampleRate: Double = 16_000

// MARK: - SampleStore

/// Lock-protected, append-only buffer of 16 kHz mono samples for one recording session.
final class SampleStore: Sendable {
    private struct State {
        var samples: [Float] = []
        var lastAppendUptime: TimeInterval = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func reset(reservingSeconds seconds: Double = 0) {
        state.withLockUnchecked { state in
            state.samples = []
            state.samples.reserveCapacity(Int(seconds * captureSampleRate))
            state.lastAppendUptime = 0
        }
    }

    func append(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        state.withLockUnchecked { state in
            state.samples.append(contentsOf: samples)
            state.lastAppendUptime = now
        }
    }

    var count: Int { state.withLockUnchecked { $0.samples.count } }

    /// `systemUptime` of the most recent append, or 0 if nothing arrived yet.
    var lastAppendUptime: TimeInterval { state.withLockUnchecked { $0.lastAppendUptime } }

    /// Copy of the newest `count` samples.
    func tail(_ count: Int) -> [Float] {
        state.withLockUnchecked { Array($0.samples.suffix(max(0, count))) }
    }

    /// Hands over everything captured and empties the store (no copy).
    func takeAll() -> [Float] {
        state.withLockUnchecked { state in
            let all = state.samples
            state.samples = []
            return all
        }
    }
}

// MARK: - LevelMeter

/// Turns captured audio into a queue of normalized loudness values, one per 16 ms window.
/// The recorder's main-thread timer plays this queue back at display rate, so the meter stays
/// smooth even when macOS delivers audio in 100 ms chunks.
final class LevelMeter: @unchecked Sendable {
    static let windowSamples = 256
    static let windowDuration = Double(windowSamples) / captureSampleRate

    /// Window RMS mapped from [floorDB, ceilingDB] to 0...1.
    private static let floorDB: Float = -50
    private static let ceilingDB: Float = -15
    /// Hard cap on queued windows (~1 s), in case nobody consumes.
    private static let maxQueued = 64

    private let lock = NSLock()
    private var pending: [Float] = []
    private var sumOfSquares: Float = 0
    private var accumulated = 0
    /// Windows produced by the latest tap buffer; tells normal chunking apart from lag.
    private var lastBatch = 1

    func reset() {
        lock.withLock {
            pending.removeAll(keepingCapacity: true)
            sumOfSquares = 0
            accumulated = 0
            lastBatch = 1
        }
    }

    /// Called from the capture thread with freshly converted 16 kHz samples.
    func ingest(_ samples: UnsafeBufferPointer<Float>) {
        lock.withLock {
            var produced = 0
            for sample in samples {
                sumOfSquares += sample * sample
                accumulated += 1
                if accumulated == Self.windowSamples {
                    pending.append(Self.normalize(rms: (sumOfSquares / Float(accumulated)).squareRoot()))
                    sumOfSquares = 0
                    accumulated = 0
                    produced += 1
                }
            }
            if produced > 0 { lastBatch = produced }
            if pending.count > Self.maxQueued {
                pending.removeFirst(pending.count - Self.maxQueued)
            }
        }
    }

    /// Pops up to `count` windows and returns the loudest, or nil if nothing is queued.
    /// If the queue holds more than one tap buffer's worth beyond what's due (the main thread
    /// was busy), the oldest windows are skipped so the meter catches up instead of lagging.
    func consume(upTo count: Int) -> Float? {
        lock.withLock {
            guard count > 0, !pending.isEmpty else { return nil }
            let allowed = count + lastBatch + 2
            if pending.count > allowed {
                pending.removeFirst(pending.count - allowed)
            }
            let n = min(count, pending.count)
            let peak = pending[0..<n].max()
            pending.removeFirst(n)
            return peak
        }
    }

    static func normalize(rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-7))
        let linear = min(max((db - floorDB) / (ceilingDB - floorDB), 0), 1)
        return pow(linear, 1.2)
    }
}

/// Main-thread side of the meter: plays the queued 16 ms windows back in real time with a
/// fast attack and a slower release, so it looks lively without jitter.
struct LevelPlayback {
    private(set) var level: Float = 0
    private var target: Float = 0
    private var lastEmitted: Float = -1
    private var budget: Double = 0
    private var lastStep: TimeInterval

    init(now: TimeInterval) {
        lastStep = now
    }

    /// Advances to `now`. Returns the new level when it moved enough to be worth drawing.
    mutating func step(now: TimeInterval, meter: LevelMeter) -> Float? {
        let elapsed = min(max(now - lastStep, 0), 0.1)
        lastStep = now

        budget = min(budget + elapsed / LevelMeter.windowDuration, 3)
        let due = Int(budget)
        if due > 0 {
            budget -= Double(due)
            if let peak = meter.consume(upTo: due) {
                target = peak
            } else {
                target *= 0.8  // Starved between tap buffers: ease off.
            }
        }

        level += (target - level) * (target > level ? 0.5 : 0.15)
        if level < 0.002 { level = 0 }
        guard abs(level - lastEmitted) >= 0.004 else { return nil }
        lastEmitted = level
        return level
    }
}

// MARK: - CaptureSink

/// Receives PCM buffers (any rate, any channel count; `CoreAudioInputCapture` hands it mono Float32
/// at the device rate), converts them to 16 kHz mono Float32, and feeds the store and level meter.
/// One sink per capture instance.
///
/// The resampler is kept for the whole stream so its filter state carries across buffers
/// (re-creating a converter per buffer causes clicks at every boundary).
final class CaptureSink: @unchecked Sendable {
    private let lock = NSLock()
    private let store: SampleStore
    private let meter: LevelMeter
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: captureSampleRate, channels: 1, interleaved: false)!

    private var isClosed = false
    private var sourceFormat: AVAudioFormat?
    /// Mono Float32 at the source rate -> 16 kHz. Nil when the source is already 16 kHz.
    private var resampler: AVAudioConverter?
    /// Fallback for non-Float32 sources: source format -> 16 kHz mono in one converter.
    private var genericConverter: AVAudioConverter?
    private var monoBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?

    init(store: SampleStore, meter: LevelMeter) {
        self.store = store
        self.meter = meter
    }

    /// Called serially from the capture's drain queue (never the realtime IO thread).
    func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, buffer.frameLength > 0 else { return }

        if sourceFormat.map({ !$0.isEqual(buffer.format) }) ?? true {
            drainConverters()
            configure(for: buffer.format)
        }

        if let generic = genericConverter {
            convert(buffer, with: generic, endOfStream: false)
        } else if let mono = downmix(buffer) {
            if let resampler {
                convert(mono, with: resampler, endOfStream: false)
            } else {
                emit(mono)
            }
        }
    }

    /// Stops accepting buffers and flushes the resampler's last few milliseconds into the store.
    /// Waits for a tap callback that's still running. Safe to call more than once.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        drainConverters()
        isClosed = true
        resampler = nil
        genericConverter = nil
    }

    // MARK: Conversion

    private func configure(for format: AVAudioFormat) {
        sourceFormat = format
        resampler = nil
        genericConverter = nil

        if format.commonFormat != .pcmFormatFloat32 {
            let converter = AVAudioConverter(from: format, to: targetFormat)
            converter?.downmix = true
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            genericConverter = converter
            return
        }
        guard format.sampleRate != captureSampleRate,
              let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)
        else { return }
        let converter = AVAudioConverter(from: monoFormat, to: targetFormat)
        converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        resampler = converter
    }

    /// Mono Float32 at the source rate. Averages the first two channels: on multichannel virtual and
    /// aggregate devices the signal lives there, and averaging all 16 BlackHole channels would bury it.
    private func downmix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard channels > 0 else { return nil }

        if monoBuffer == nil || monoBuffer!.format.sampleRate != buffer.format.sampleRate
            || monoBuffer!.frameCapacity < buffer.frameLength
        {
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false)
            else { return nil }
            monoBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(buffer.frameLength, 4096))
        }
        guard let mono = monoBuffer, let destination = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = buffer.frameLength

        let used = min(channels, 2)
        if buffer.format.isInterleaved {
            let stride = buffer.stride
            let data = source[0]
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<used { sum += data[frame * stride + channel] }
                destination[frame] = sum / Float(used)
            }
        } else if used == 1 {
            destination.update(from: source[0], count: frames)
        } else {
            let left = source[0]
            let right = source[1]
            for frame in 0..<frames {
                destination[frame] = (left[frame] + right[frame]) * 0.5
            }
        }
        return mono
    }

    /// Streams `input` through `converter`. With `endOfStream == false` the converter keeps its
    /// state for the next buffer; `true` drains it (used on close / format change).
    private func convert(_ input: AVAudioPCMBuffer?, with converter: AVAudioConverter, endOfStream: Bool) {
        let ratio = captureSampleRate / converter.inputFormat.sampleRate
        let inputFrames = Double(input?.frameLength ?? 0)
        let capacity = AVAudioFrameCount((inputFrames * ratio).rounded(.up)) + 1024
        if outputBuffer == nil || outputBuffer!.frameCapacity < capacity {
            outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        }
        guard let output = outputBuffer else { return }

        let feed = FeedState(buffer: input, endOfStream: endOfStream)
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if let next = feed.next() {
                    inputStatus.pointee = .haveData
                    return next
                }
                inputStatus.pointee = feed.endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if output.frameLength > 0 { emit(output) }
            // .haveData means the output buffer filled up and more is pending.
            guard status == .haveData, error == nil else { break }
        }
    }

    private func drainConverters() {
        if let resampler { convert(nil, with: resampler, endOfStream: true) }
        if let genericConverter { convert(nil, with: genericConverter, endOfStream: true) }
    }

    private func emit(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let samples = UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))
        store.append(samples)
        meter.ingest(samples)
    }

    /// Hands the input buffer to the converter exactly once per `convert` call.
    private final class FeedState: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        let endOfStream: Bool

        init(buffer: AVAudioPCMBuffer?, endOfStream: Bool) {
            self.buffer = buffer
            self.endOfStream = endOfStream
        }

        func next() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }
}
