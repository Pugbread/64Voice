import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

enum PermissionStatus: Equatable, Sendable {
    case granted, denied, notDetermined
}

/// Microphone, Accessibility and Screen Recording access. Reading never prompts; only the
/// `request…` calls do. Refreshes when the app becomes active and, while the Settings window is
/// visible, every 1.5 s (driven by `SettingsView`).
@MainActor
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published private(set) var microphone: PermissionStatus
    /// Needed for the global hotkey (event tap) and for posting ⌘V.
    @Published private(set) var accessibility: Bool
    /// Optional; only used by smart notch placement.
    @Published private(set) var screenRecording: Bool

    /// Microphone and Accessibility are both required for dictation to work.
    var requiredGranted: Bool { microphone == .granted && accessibility }

    private var activationObserver: NSObjectProtocol?
    private var liveRefreshTimer: Timer?
    private var liveRefreshClients = 0

    private init() {
        microphone = Self.readMicrophone()
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let microphone = Self.readMicrophone()
        let accessibility = AXIsProcessTrusted()
        let screenRecording = CGPreflightScreenCaptureAccess()
        // Only publish real changes so the 1.5 s refresh doesn't re-render observers.
        if microphone != self.microphone { self.microphone = microphone }
        if accessibility != self.accessibility { self.accessibility = accessibility }
        if screenRecording != self.screenRecording { self.screenRecording = screenRecording }
    }

    /// Shows the system prompt the first time; after a denial, opens System Settings instead.
    func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            refresh()
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            refresh()
            return granted
        default:
            open(.microphone)
            refresh()
            return false
        }
    }

    /// Registers 64Voice in the Accessibility list (with the system prompt) and opens the pane.
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            refresh()
            return
        }
        open(.accessibility)
    }

    func requestScreenRecording() {
        if CGPreflightScreenCaptureAccess() {
            refresh()
            return
        }
        CGRequestScreenCaptureAccess()
        open(.screenRecording)
    }

    // MARK: Settings panes

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"

        var url: URL {
            URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!
        }
    }

    func open(_ pane: Pane) {
        NSWorkspace.shared.open(pane.url)
    }

    // MARK: Live refresh

    /// Polls every 1.5 s while at least one client (the visible Settings window) wants it.
    /// Calls must be balanced.
    func beginLiveRefresh() {
        liveRefreshClients += 1
        guard liveRefreshTimer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveRefreshTimer = timer
    }

    func endLiveRefresh() {
        liveRefreshClients = max(0, liveRefreshClients - 1)
        guard liveRefreshClients == 0 else { return }
        liveRefreshTimer?.invalidate()
        liveRefreshTimer = nil
    }

    private static func readMicrophone() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}
