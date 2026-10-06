import ServiceManagement
import SwiftUI

/// The menu shown from the menu bar icon.
struct MenuBarContentView: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var devices = AudioDeviceManager.shared
    @ObservedObject private var engine = TranscriptionEngine.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Text(statusLine)

        Divider()

        Picker("Microphone", selection: micSelection) {
            Text(systemDefaultLabel).tag(String?.none)
            ForEach(devices.inputDevices) { device in
                Text(device.name).tag(Optional(device.uid))
            }
            if let uid = settings.preferredMicUID, !devices.isConnected(uid: uid) {
                Text("\(settings.preferredMicName ?? "Saved mic") (not connected)").tag(Optional(uid))
            }
        }

        Button("Copy Last Transcript") { state.copyLastTranscript() }
            .disabled(state.lastTranscript.isEmpty)

        Divider()

        Toggle("Launch at Login", isOn: Binding(
            get: { launchAtLogin },
            set: { setLaunchAtLogin($0) }
        ))
        Button("Settings…") { SettingsWindowController.shared.show() }
            .keyboardShortcut(",")
        Button("Quit 64Voice") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch state.status {
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .idle: break
        }
        switch engine.state {
        case .idle, .loading: return "Loading speech model…"
        case let .downloading(progress): return "Downloading model \(Int(progress * 100))%"
        case let .failed(message): return "Model error: \(message)"
        case .ready: return "Ready · hold \(settings.hotkey.displayName)"
        }
    }

    private var systemDefaultLabel: String {
        if let name = devices.systemDefaultInput?.name { return "System Default (\(name))" }
        return "System Default"
    }

    private var micSelection: Binding<String?> {
        Binding(
            get: { settings.preferredMicUID },
            set: { uid in
                settings.preferredMicUID = uid
                if let uid {
                    settings.preferredMicName = devices.inputDevices.first { $0.uid == uid }?.name ?? settings.preferredMicName
                } else {
                    settings.preferredMicName = nil
                }
            }
        )
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("64Voice: launch at login change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
