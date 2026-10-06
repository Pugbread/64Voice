import SwiftUI

/// Speech model choice and load status, as rows for a settings `Section`/`Form`.
struct ModelStatusView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var engine = TranscriptionEngine.shared

    var body: some View {
        Picker(selection: $settings.speechModel) {
            ForEach(SpeechModelChoice.allCases) { model in
                Text(model.displayName).tag(model)
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("Speech model")
                Text(summary(for: settings.speechModel))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        LabeledContent("Status") {
            status
        }
    }

    @ViewBuilder
    private var status: some View {
        switch engine.state {
        case .idle:
            HStack(spacing: 8) {
                Text("Not loaded").foregroundStyle(.secondary)
                Button("Load") { Task { await engine.prepare() } }
            }
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .frame(width: 120)
                Text("Downloading \(Int((fraction * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").foregroundStyle(.secondary)
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            HStack(spacing: 8) {
                Label("Failed: \(message)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(message)
                Button("Retry") { Task { await engine.prepare() } }
            }
        }
    }

    private func summary(for model: SpeechModelChoice) -> String {
        switch model {
        case .parakeetV2: "English only, best English accuracy"
        case .parakeetV3: "25 European languages"
        }
    }
}
