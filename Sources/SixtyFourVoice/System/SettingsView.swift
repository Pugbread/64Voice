import AppKit
import SwiftUI

/// The app's only window: a sidebar of pages, each a grouped form.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @State private var page: SettingsPage

    /// Opens on Permissions while something required is missing, otherwise on General.
    init() {
        _page = State(initialValue: PermissionsManager.shared.requiredGranted ? .general : .permissions)
    }

    init(page: SettingsPage) {
        _page = State(initialValue: page)
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(
                selection: $page,
                needsAttention: !permissions.requiredGranted,
                hotkey: settings.hotkey,
                mode: settings.hotkeyMode
            )
            .frame(width: 184)

            Divider()
                .ignoresSafeArea()

            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    // Sits in the title bar strip, centered on the traffic lights.
                    Text(page.title)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(height: max(proxy.safeAreaInsets.top, 28))
                        .padding(.leading, 20)

                    pageContent
                        .formStyle(.grouped)
                        .scrollContentBackground(.hidden)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .ignoresSafeArea(edges: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 560, height: 520)
        .background(SettingsWindowObserver())
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .general: GeneralPage()
        case .microphone: MicrophonePage()
        case .model: ModelPage()
        case .notch: NotchPage()
        case .permissions: PermissionsPage()
        }
    }
}

// MARK: - Pages

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, microphone, model, notch, permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .microphone: "Microphone"
        case .model: "Speech Model"
        case .notch: "Notch"
        case .permissions: "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .microphone: "mic.fill"
        case .model: "waveform"
        case .notch: "capsule.fill"
        case .permissions: "hand.raised.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .microphone: .red
        case .model: .purple
        case .notch: .indigo
        case .permissions: .blue
        }
    }
}

private struct GeneralPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Dictation key", selection: $settings.hotkey) {
                    ForEach(HotkeyKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                if settings.hotkey == .fn {
                    GlobeKeyNote()
                }
            } footer: {
                FormFootnote("Pressing another key while holding it cancels, so \(chordExample) keep working.")
            }

            Section {
                ForEach(HotkeyMode.allCases) { mode in
                    ModeRow(mode: mode, isSelected: settings.hotkeyMode == mode) {
                        settings.hotkeyMode = mode
                    }
                }
            } header: {
                Text("Activation")
            } footer: {
                FormFootnote("Press Esc to cancel a recording.")
            }

            Section {
                Toggle(isOn: $settings.playSounds) {
                    Text("Play sounds")
                    Text("A soft tick when recording starts and stops.")
                }
                Toggle(isOn: $settings.restoreClipboard) {
                    Text("Restore clipboard")
                    Text("Text is pasted through the clipboard. Your previous clipboard comes back right after.")
                }
            }
            .toggleStyle(.switch)
        }
        .animation(.snappy(duration: 0.2), value: settings.hotkey)
    }

    private var chordExample: String {
        switch settings.hotkey {
        case .rightOption: "shortcuts like ⌥A"
        case .rightCommand: "shortcuts like ⌘C"
        case .rightControl: "shortcuts like ⌃C"
        case .fn: "fn shortcuts"
        }
    }
}

private struct MicrophonePage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                MicrophonePickerView()
            }

            Section {
                Toggle(isOn: $settings.feedVirtualMic) {
                    Text("Mute calls while dictating")
                    Text("Pick 64Voice Mic as the input in Discord or any call app. It carries this microphone and goes silent while you dictate.")
                }
                .toggleStyle(.switch)
                VirtualMicStatusRow()
            } header: {
                Text("64Voice Mic")
            }
        }
    }
}

private struct VirtualMicStatusRow: View {
    @ObservedObject private var bridge = VirtualMicBridge.shared

    var body: some View {
        switch bridge.status {
        case .notInstalled:
            CalloutRow(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                text: "The 64Voice Mic driver isn't installed. Run scripts/install-mic-driver.sh from the 64Voice folder.",
                actionTitle: nil,
                action: nil
            )
        case .off:
            CalloutRow(symbol: "mic.slash.fill", tint: .secondary, text: "Off. 64Voice Mic stays silent.", actionTitle: nil, action: nil)
        case .needsMicAccess:
            CalloutRow(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                text: "Needs microphone access.",
                actionTitle: "Grant…"
            ) {
                Task { _ = await PermissionsManager.shared.requestMicrophone() }
            }
        case .waiting:
            CalloutRow(symbol: "checkmark.circle.fill", tint: .green, text: "Ready. No app is listening to 64Voice Mic right now.", actionTitle: nil, action: nil)
        case .live(let source):
            if bridge.isMuted {
                CalloutRow(symbol: "mic.slash.fill", tint: .orange, text: "Muted while you dictate.", actionTitle: nil, action: nil)
            } else {
                CalloutRow(symbol: "dot.radiowaves.left.and.right", tint: .green, text: "Live: \(source) → 64Voice Mic.", actionTitle: nil, action: nil)
            }
        case .failed(let message):
            CalloutRow(symbol: "exclamationmark.triangle.fill", tint: .red, text: "Couldn't start 64Voice Mic: \(message)", actionTitle: nil, action: nil)
        }
    }
}

private struct ModelPage: View {
    var body: some View {
        Form {
            Section {
                ModelStatusView()
            } footer: {
                FormFootnote("Speech recognition runs entirely on this Mac.")
            }
        }
    }
}

private struct NotchPage: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var permissions = PermissionsManager.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.smartPlacement) {
                    Text("Smart placement")
                    Text("Moves the notch into the emptiest space near your cursor, so it doesn't cover what you're reading.")
                }
                if settings.smartPlacement, !permissions.screenRecording {
                    CalloutRow(
                        symbol: "exclamationmark.triangle.fill",
                        tint: .orange,
                        text: "Needs Screen Recording permission to see where the free space is.",
                        actionTitle: "Grant…"
                    ) {
                        PermissionsManager.shared.requestScreenRecording()
                    }
                }
            } footer: {
                FormFootnote("Smart placement uses Screen Recording only to look at the area around the cursor.")
            }

            Section {
                Toggle(isOn: $settings.followCursor) {
                    Text("Follow cursor")
                    Text("The notch trails your pointer while you record.")
                }
                Toggle(isOn: $settings.showLiveTranscript) {
                    Text("Show live transcript")
                    Text("See your words in the notch as you speak.")
                }
            }
        }
        .toggleStyle(.switch)
        .animation(.snappy(duration: 0.2), value: settings.smartPlacement)
        .animation(.snappy(duration: 0.2), value: permissions.screenRecording)
    }
}

private struct PermissionsPage: View {
    @ObservedObject private var permissions = PermissionsManager.shared

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    symbol: "mic.fill",
                    tint: .red,
                    title: "Microphone",
                    detail: "Hears what you dictate.",
                    state: micState,
                    actionTitle: permissions.microphone == .notDetermined ? "Allow…" : "Open Settings…"
                ) {
                    Task { _ = await PermissionsManager.shared.requestMicrophone() }
                }
                PermissionRow(
                    symbol: "accessibility",
                    tint: .blue,
                    title: "Accessibility",
                    detail: "Detects the dictation key and pastes text.",
                    state: permissions.accessibility ? .granted : .required,
                    actionTitle: "Open Settings…"
                ) {
                    PermissionsManager.shared.requestAccessibility()
                }
            } header: {
                Text("Required")
            }

            Section {
                PermissionRow(
                    symbol: "rectangle.dashed.badge.record",
                    tint: .purple,
                    title: "Screen Recording",
                    detail: "Lets smart placement find free space.",
                    state: permissions.screenRecording ? .granted : .optional,
                    actionTitle: "Open Settings…"
                ) {
                    PermissionsManager.shared.requestScreenRecording()
                }
            } header: {
                Text("Optional")
            } footer: {
                FormFootnote("Changes show up here automatically. If one doesn't, quit and reopen 64Voice.")
            }
        }
        .animation(.snappy(duration: 0.2), value: permissions.microphone)
        .animation(.snappy(duration: 0.2), value: permissions.accessibility)
        .animation(.snappy(duration: 0.2), value: permissions.screenRecording)
    }

    private var micState: PermissionRow.State {
        switch permissions.microphone {
        case .granted: .granted
        case .denied: .denied
        case .notDetermined: .required
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var selection: SettingsPage
    let needsAttention: Bool
    let hotkey: HotkeyKey
    let mode: HotkeyMode

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPage.allCases) { page in
                SidebarRow(
                    page: page,
                    isSelected: selection == page,
                    showsBadge: page == .permissions && needsAttention
                ) {
                    selection = page
                }
            }

            Spacer(minLength: 0)

            HotkeyHint(hotkey: hotkey, mode: mode)
                .padding(.horizontal, 8)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            VisualEffectBackground(material: .sidebar)
                .ignoresSafeArea()
        }
    }
}

private struct SidebarRow: View {
    let page: SettingsPage
    let isSelected: Bool
    let showsBadge: Bool
    let action: () -> Void

    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                IconTile(symbol: page.symbol, tint: page.tint, size: 22)
                Text(page.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected && isKey ? Color.white : Color.primary)
                Spacer(minLength: 0)
                if showsBadge {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                        .padding(.trailing, 2)
                }
            }
            .padding(.horizontal, 5)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selectionFill)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var isKey: Bool { activeState == .key || activeState == .active }

    private var selectionFill: Color {
        guard isSelected else { return .clear }
        return isKey ? Color.accentColor : Color.primary.opacity(0.1)
    }
}

/// "Hold [Right ⌥] to dictate", reflecting the current key and mode.
private struct HotkeyHint: View {
    let hotkey: HotkeyKey
    let mode: HotkeyMode

    var body: some View {
        HStack(spacing: 5) {
            Text(mode == .toggle ? "Tap" : "Hold")
            KeyCap(hotkey: hotkey)
            Text("to dictate")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize()
    }
}

private struct KeyCap: View {
    let hotkey: HotkeyKey

    var body: some View {
        HStack(spacing: 3) {
            switch hotkey {
            case .rightOption: Text("right ⌥")
            case .rightCommand: Text("right ⌘")
            case .rightControl: Text("right ⌃")
            case .fn:
                Text("fn")
                Image(systemName: "globe")
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 0, y: 0.5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
    }
}

// MARK: - Rows

private struct ModeRow: View {
    let mode: HotkeyMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .foregroundStyle(.primary)
                    Text(explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .scaleEffect(isSelected ? 1 : 0.6)
                    .animation(.snappy(duration: 0.2), value: isSelected)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var explanation: String {
        switch mode {
        case .hybrid: "Hold to talk, or tap to go hands-free."
        case .hold: "Records only while you hold the key."
        case .toggle: "Tap to start recording, tap again to stop."
        }
    }
}

/// Fn/Globe can also open the emoji picker or switch input source, depending on Keyboard settings.
private struct GlobeKeyNote: View {
    @State private var globeDoesNothing = GlobeKeySetting.isDoNothing

    var body: some View {
        Group {
            if globeDoesNothing {
                CalloutRow(
                    symbol: "checkmark.circle.fill",
                    tint: .green,
                    text: "“Press 🌐 key to” is set to “Do Nothing”, so Fn only starts dictation.",
                    actionTitle: nil,
                    action: nil
                )
            } else {
                CalloutRow(
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange,
                    text: "Set “Press 🌐 key to” to “Do Nothing” in Keyboard settings, or Fn may also open the emoji picker or switch input source.",
                    actionTitle: "Keyboard Settings…"
                ) {
                    NSWorkspace.shared.open(GlobeKeySetting.keyboardSettingsURL)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            globeDoesNothing = GlobeKeySetting.isDoNothing
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            globeDoesNothing = GlobeKeySetting.isDoNothing
        }
    }
}

enum GlobeKeySetting {
    static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    /// System Settings › Keyboard › "Press 🌐 key to": 0 = Do Nothing.
    static var isDoNothing: Bool {
        UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int == 0
    }
}

private struct CalloutRow: View {
    let symbol: String
    let tint: Color
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct PermissionRow: View {
    enum State: Equatable {
        case granted, required, denied, optional
    }

    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let state: State
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                    StatusBadge(state: state)
                }
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if state != .granted {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct StatusBadge: View {
    let state: PermissionRow.State

    var body: some View {
        HStack(spacing: 3) {
            if state == .granted {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
            }
            Text(label)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.14)))
        .contentTransition(.opacity)
    }

    private var label: String {
        switch state {
        case .granted: "Granted"
        case .required: "Needed"
        case .denied: "Denied"
        case .optional: "Off"
        }
    }

    private var color: Color {
        switch state {
        case .granted: .green
        case .required: .orange
        case .denied: .red
        case .optional: .secondary
        }
    }
}

// MARK: - Building blocks

/// A white SF Symbol on a colored rounded square, like System Settings.
private struct IconTile: View {
    let symbol: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            }
    }
}

private struct FormFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context _: Context) {
        view.material = material
    }
}

// MARK: - Window

/// While the hosting window is on screen, keeps `PermissionsManager` refreshing every 1.5 s.
/// Also gives the window the sidebar look: hidden title, content under a transparent title bar.
private struct SettingsWindowObserver: NSViewRepresentable {
    func makeNSView(context _: Context) -> ObserverView { ObserverView() }
    func updateNSView(_: ObserverView, context _: Context) {}

    final class ObserverView: NSView {
        private var observers: [NSObjectProtocol] = []
        private var isRefreshing = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()

            guard let window else {
                setRefreshing(false)
                return
            }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)

            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.willCloseNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let closing = note.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated { self?.update(closing: closing) }
                })
            }
            update(closing: false)
        }

        private func update(closing: Bool) {
            guard let window, !closing else {
                setRefreshing(false)
                return
            }
            setRefreshing(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
        }

        private func setRefreshing(_ refreshing: Bool) {
            guard refreshing != isRefreshing else { return }
            isRefreshing = refreshing
            if refreshing {
                PermissionsManager.shared.beginLiveRefresh()
            } else {
                PermissionsManager.shared.endLiveRefresh()
            }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
            if isRefreshing {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { PermissionsManager.shared.endLiveRefresh() }
                }
            }
        }
    }
}
