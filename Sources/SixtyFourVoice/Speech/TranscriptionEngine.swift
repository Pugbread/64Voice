import Combine
import FluidAudio
import Foundation

enum TranscriptionError: LocalizedError {
    case notReady(String)

    var errorDescription: String? {
        switch self {
        case .notReady(let reason): "The speech model isn't ready (\(reason))."
        }
    }
}

/// On-device speech recognition with FluidAudio's Parakeet TDT models.
///
/// Models live in FluidAudio's default cache (~/Library/Application Support/FluidAudio/Models),
/// the same place FluidVoice uses, so existing downloads are reused as-is.
///
/// `transcribe` calls run one at a time, in call order, each with a fresh decoder state, so a
/// live preview can never bleed into the final result. A call still waiting for its turn throws
/// `CancellationError` if its Task is cancelled: cancel the preview Task before the final
/// transcription and the final one runs right after the preview that's already in flight.
@MainActor
final class TranscriptionEngine: ObservableObject {
    static let shared = TranscriptionEngine()

    enum State: Equatable {
        case idle
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The model that `transcribe` uses right now. While a newly selected model downloads,
    /// the previous one keeps working.
    @Published private(set) var loadedModel: SpeechModelChoice?

    /// Clips shorter than this return "" (nothing useful to recognize).
    private static let minimumSamples = Int(0.25 * 16_000)
    /// Shorter clips are padded with silence up to this length; Parakeet rejects < 0.3 s.
    private static let paddedMinimumSamples = 16_000

    private var manager: AsrManager?
    private var prepareTask: Task<Void, Never>?
    private var prepareTaskModel: SpeechModelChoice?
    private var activeLoadID: UUID?
    private var downloadFraction: Double = 0
    private let gate = SerialGate()
    private var settingsObserver: AnyCancellable?

    private init() {
        settingsObserver = AppSettings.shared.$speechModel
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                // $speechModel fires before the new value is stored; the Task runs after.
                Task { @MainActor in await self?.prepare() }
            }
    }

    // MARK: - Loading

    /// Downloads (if needed) and loads the model selected in settings. Idempotent and safe to
    /// call concurrently: concurrent callers share one load.
    func prepare() async {
        while true {
            let target = AppSettings.shared.speechModel
            if prepareTask == nil, manager != nil, loadedModel == target {
                if state != .ready { state = .ready }
                return
            }
            if let running = prepareTask {
                let runningModel = prepareTaskModel
                await running.value
                if runningModel == target { return }
                continue  // The selection changed during that load.
            }
            prepareTaskModel = target
            let task = Task { await self.load(target) }
            prepareTask = task
            await task.value
            return
        }
    }

    private func load(_ target: SpeechModelChoice) async {
        let loadID = UUID()
        activeLoadID = loadID
        downloadFraction = 0
        defer {
            activeLoadID = nil
            prepareTask = nil
            prepareTaskModel = nil
        }

        let version: AsrModelVersion = target == .parakeetV2 ? .v2 : .v3
        let directory = AsrModels.defaultCacheDirectory(for: version)
        let progress = Self.makeProgressHandler { [weak self] update in
            self?.applyProgress(update, loadID: loadID)
        }

        do {
            let haveCurrent = AsrModels.modelsExist(at: directory, version: version)
            let legacyDirectory = haveCurrent ? nil : Self.legacyDirectory(for: version)
            if !haveCurrent, legacyDirectory == nil {
                state = .downloading(0)
                // Downloads only what's missing; the previous model keeps transcribing meanwhile.
                try await AsrModels.download(to: directory, version: version, progressHandler: progress)
            }
            state = .loading

            // Free the old model before loading the new one (each is ~0.5 GB).
            if let old = manager {
                await gate.acquireUncancellable()
                manager = nil
                loadedModel = nil
                gate.release()
                await old.cleanup()
            }

            var models: AsrModels?
            if let legacyDirectory {
                do {
                    models = try await Self.loadLegacy(from: legacyDirectory, version: version)
                } catch {
                    NSLog("64Voice: couldn't load %@ (%@); using FluidAudio's cache", legacyDirectory.path, "\(error)")
                }
            }
            if models == nil {
                // Downloads into FluidAudio's cache if anything is missing or unreadable.
                models = try await AsrModels.load(from: directory, version: version, progressHandler: progress)
            }
            guard let models else { throw TranscriptionError.notReady("no model files") }

            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            await Self.warmUp(asr)

            manager = asr
            loadedModel = target
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func applyProgress(_ update: DownloadProgress, loadID: UUID) {
        guard activeLoadID == loadID else { return }
        switch update.phase {
        case .listing:
            break
        case .downloading(_, let totalFiles):
            // totalFiles == 0 is FluidAudio's "already cached" signal.
            guard totalFiles > 0 else { return }
            // FluidAudio reports repo downloads in 0...0.5 and Core ML compilation in 0.5...1.
            let fraction = min(1, update.fractionCompleted / 0.5)
            // Publish whole percents only; FluidAudio reports every few kilobytes.
            guard fraction >= downloadFraction + 0.01 || (fraction == 1 && downloadFraction < 1) else { return }
            downloadFraction = fraction
            state = .downloading(fraction)
        case .compiling:
            if case .downloading = state { state = .loading }
        }
    }

    /// FluidVoice (older FluidAudio) cached models in "<repo>-coreml"; FluidAudio 0.17 looks in
    /// "<repo>" instead. The files are identical, so load the old folder rather than download again.
    private nonisolated static func legacyDirectory(for version: AsrModelVersion) -> URL? {
        let current = AsrModels.defaultCacheDirectory(for: version)
        let legacy = current.deletingLastPathComponent()
            .appendingPathComponent(current.lastPathComponent + "-coreml", isDirectory: true)
        let models = version == .v2 ? ModelNames.ASR.requiredModels : ModelNames.ASR.requiredModelsV3()
        let required = models.union([ModelNames.ASR.vocabularyFile])
        let fileManager = FileManager.default
        guard required.allSatisfy({ fileManager.fileExists(atPath: legacy.appendingPathComponent($0).path) })
        else { return nil }
        return legacy
    }

    /// Loads compiled models from `directory` as-is (no download, no writes). Off the main actor:
    /// the first Core ML / Neural Engine compile of a model can take ~20 s.
    private nonisolated static func loadLegacy(from directory: URL, version: AsrModelVersion) async throws -> AsrModels {
        try await Task.detached(priority: .userInitiated) {
            try AsrModels.loadLocal(from: directory, version: version)
        }.value
    }

    /// The first inference after loading is slow (Core ML/ANE warm-up); pay that cost now.
    private nonisolated static func warmUp(_ asr: AsrManager) async {
        _ = try? await run(asr, [Float](repeating: 0, count: paddedMinimumSamples))
    }

    private nonisolated static func makeProgressHandler(
        _ forward: @escaping @MainActor @Sendable (DownloadProgress) -> Void
    ) -> ProgressHandler {
        { update in Task { @MainActor in forward(update) } }
    }

    // MARK: - Transcription

    /// Transcribes 16 kHz mono Float32 audio. Returns trimmed text, or "" for clips under 0.25 s.
    /// Throws `TranscriptionError.notReady` if no model is loaded.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard samples.count >= Self.minimumSamples else { return "" }
        guard manager != nil else { throw TranscriptionError.notReady(statusDescription) }

        try await gate.acquire()
        defer { gate.release() }
        try Task.checkCancellation()
        guard let asr = manager else { throw TranscriptionError.notReady(statusDescription) }

        var input = samples
        if input.count < Self.paddedMinimumSamples {
            input.append(contentsOf: repeatElement(0, count: Self.paddedMinimumSamples - input.count))
        }
        return try await Self.run(asr, input)
    }

    private nonisolated static func run(_ asr: AsrManager, _ samples: [Float]) async throws -> String {
        var decoderState = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(samples, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var statusDescription: String {
        switch state {
        case .idle: "not loaded"
        case .downloading(let fraction): "downloading, \(Int(fraction * 100))%"
        case .loading: "loading"
        case .ready: "ready"
        case .failed(let message): message
        }
    }
}

/// FIFO async mutex. Waiters whose Task is cancelled leave the queue with `CancellationError`.
@MainActor
final class SerialGate {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private var isHeld = false
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0

    func acquire() async throws {
        try Task.checkCancellation()
        if !isHeld {
            isHeld = true
            return
        }
        nextID += 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor in self.removeWaiter(id) }
        }
    }

    /// For internal maintenance (model swaps) that must not be skipped.
    func acquireUncancellable() async {
        if !isHeld {
            isHeld = true
            return
        }
        nextID += 1
        let id = nextID
        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiters.append(Waiter(id: id, continuation: continuation))
        }
    }

    /// Hands the gate to the next waiter, or frees it.
    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func removeWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
