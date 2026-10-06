import Combine
import Foundation

/// All user settings, persisted to UserDefaults on every change.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    // MARK: Microphone

    /// UID (kAudioDevicePropertyDeviceUID) of the chosen mic. `nil` means "follow the system default".
    /// The UID is stable across reboots and reconnects. It is never cleared automatically:
    /// if the device is missing we fall back to the system default for that recording only.
    @Published var preferredMicUID: String? {
        didSet { defaults.set(preferredMicUID, forKey: Keys.preferredMicUID) }
    }

    /// Display name of the chosen mic, so it can be shown while disconnected.
    @Published var preferredMicName: String? {
        didSet { defaults.set(preferredMicName, forKey: Keys.preferredMicName) }
    }

    // MARK: Hotkey

    @Published var hotkey: HotkeyKey {
        didSet { defaults.set(hotkey.rawValue, forKey: Keys.hotkey) }
    }

    @Published var hotkeyMode: HotkeyMode {
        didSet { defaults.set(hotkeyMode.rawValue, forKey: Keys.hotkeyMode) }
    }

    // MARK: Speech

    @Published var speechModel: SpeechModelChoice {
        didSet { defaults.set(speechModel.rawValue, forKey: Keys.speechModel) }
    }

    // MARK: Overlay

    /// Analyze the screen around the cursor and fly the notch into the emptiest nearby space.
    @Published var smartPlacement: Bool {
        didSet { defaults.set(smartPlacement, forKey: Keys.smartPlacement) }
    }

    /// Keep the notch trailing the cursor while recording.
    @Published var followCursor: Bool {
        didSet { defaults.set(followCursor, forKey: Keys.followCursor) }
    }

    /// Show the live partial transcript inside the notch.
    @Published var showLiveTranscript: Bool {
        didSet { defaults.set(showLiveTranscript, forKey: Keys.showLiveTranscript) }
    }

    // MARK: Behavior

    @Published var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: Keys.playSounds) }
    }

    /// Put the previous clipboard contents back after pasting the transcript.
    @Published var restoreClipboard: Bool {
        didSet { defaults.set(restoreClipboard, forKey: Keys.restoreClipboard) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.hotkey: HotkeyKey.rightOption.rawValue,
            Keys.hotkeyMode: HotkeyMode.hybrid.rawValue,
            Keys.speechModel: SpeechModelChoice.parakeetV2.rawValue,
            Keys.smartPlacement: true,
            Keys.followCursor: true,
            Keys.showLiveTranscript: true,
            Keys.playSounds: true,
            Keys.restoreClipboard: true,
        ])

        Self.importFluidVoiceMicIfFirstRun(defaults)

        preferredMicUID = defaults.string(forKey: Keys.preferredMicUID)
        preferredMicName = defaults.string(forKey: Keys.preferredMicName)
        hotkey = defaults.string(forKey: Keys.hotkey).flatMap(HotkeyKey.init(rawValue:)) ?? .rightOption
        hotkeyMode = defaults.string(forKey: Keys.hotkeyMode).flatMap(HotkeyMode.init(rawValue:)) ?? .hybrid
        speechModel = defaults.string(forKey: Keys.speechModel).flatMap(SpeechModelChoice.init(rawValue:)) ?? .parakeetV2
        smartPlacement = defaults.bool(forKey: Keys.smartPlacement)
        followCursor = defaults.bool(forKey: Keys.followCursor)
        showLiveTranscript = defaults.bool(forKey: Keys.showLiveTranscript)
        playSounds = defaults.bool(forKey: Keys.playSounds)
        restoreClipboard = defaults.bool(forKey: Keys.restoreClipboard)
    }

    /// On the very first launch, adopt the mic FluidVoice had selected so there's nothing to re-pick.
    private static func importFluidVoiceMicIfFirstRun(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: Keys.didFirstRun) else { return }
        defaults.set(true, forKey: Keys.didFirstRun)
        guard defaults.string(forKey: Keys.preferredMicUID) == nil,
              let fluid = UserDefaults(suiteName: "com.FluidApp.app"),
              let uid = fluid.string(forKey: "PreferredInputDeviceUID"), !uid.isEmpty
        else { return }
        defaults.set(uid, forKey: Keys.preferredMicUID)
    }

    private enum Keys {
        static let didFirstRun = "sfv.didFirstRun"
        static let preferredMicUID = "sfv.preferredMicUID"
        static let preferredMicName = "sfv.preferredMicName"
        static let hotkey = "sfv.hotkey"
        static let hotkeyMode = "sfv.hotkeyMode"
        static let speechModel = "sfv.speechModel"
        static let smartPlacement = "sfv.smartPlacement"
        static let followCursor = "sfv.followCursor"
        static let showLiveTranscript = "sfv.showLiveTranscript"
        static let playSounds = "sfv.playSounds"
        static let restoreClipboard = "sfv.restoreClipboard"
    }
}
