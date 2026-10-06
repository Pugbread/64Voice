import SwiftUI

/// Microphone choice, as rows for a settings `Section`/`Form`.
///
/// "System Default" follows whatever macOS picks. Choosing a device pins it by UID; if it's not
/// connected later, it stays selected and recording uses the system default until it's back.
struct MicrophonePickerView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var devices = AudioDeviceManager.shared

    var body: some View {
        MicrophoneRow(
            symbol: "gearshape",
            title: "System Default",
            detail: devices.systemDefaultInput.map { "(\($0.name))" },
            isSelected: settings.preferredMicUID == nil
        ) {
            select(nil)
        }

        if let uid = settings.preferredMicUID, !devices.isConnected(uid: uid) {
            MicrophoneRow(
                symbol: "mic.slash",
                title: settings.preferredMicName ?? "Saved microphone",
                subtitle: "Not connected — using \(devices.systemDefaultInput?.name ?? "no microphone") for now",
                subtitleStyle: .orange,
                isSelected: true
            ) {}
        }

        ForEach(devices.inputDevices) { device in
            MicrophoneRow(
                symbol: device.symbolName,
                title: device.name,
                subtitle: device.transportLabel,
                isSelected: settings.preferredMicUID == device.uid
            ) {
                select(device)
            }
        }
    }

    private func select(_ device: AudioInputDevice?) {
        settings.preferredMicUID = device?.uid
        settings.preferredMicName = device?.name
    }
}

private struct MicrophoneRow: View {
    let symbol: String
    let title: String
    var detail: String?
    var subtitle: String?
    var subtitleStyle: Color = .secondary
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .center)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(title).lineLimit(1)
                        if let detail {
                            Text(detail).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(subtitleStyle)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
