import Combine
import CoreAudio
import Foundation

/// Live list of input devices plus the system default, kept current by CoreAudio listeners.
///
/// The mic preference lives in `AppSettings.preferredMicUID` and is never changed here:
/// `resolvedInput` falls back to the system default for as long as the preferred device is
/// missing, and picks it again the moment it reappears. The system default is never modified.
@MainActor
final class AudioDeviceManager: ObservableObject {
    static let shared = AudioDeviceManager()

    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published private(set) var systemDefaultInput: AudioInputDevice?

    private init() {
        refresh()
        installListeners()
    }

    /// The preferred device if it's connected, otherwise the current system default input.
    func resolvedInput(preferredUID: String?) -> AudioInputDevice? {
        if let uid = preferredUID, !uid.isEmpty, let device = device(uid: uid) {
            return device
        }
        // No usable default (e.g. the system input is set to 64Voice Mic): the built-in mic is the safest pick.
        return systemDefaultInput ?? inputDevices.first { $0.transport == "builtIn" } ?? inputDevices.first
    }

    func isConnected(uid: String) -> Bool {
        inputDevices.contains { $0.uid == uid }
    }

    func device(uid: String) -> AudioInputDevice? {
        inputDevices.first { $0.uid == uid }
    }

    /// Re-reads the device list and default input from CoreAudio. Listeners call this
    /// automatically; call it directly only if you suspect the cached list is stale.
    func refresh() {
        let devices = CoreAudioDevices.inputDevices()
        let defaultInput = CoreAudioDevices.defaultInputDeviceID().flatMap { id in
            devices.first { $0.id == id } ?? CoreAudioDevices.inputDevice(id: id, includeHidden: true)
        }
        if devices != inputDevices { inputDevices = devices }
        if defaultInput != systemDefaultInput { systemDefaultInput = defaultInput }
        rememberPreferredNameIfMissing()
    }

    /// The UID imported from FluidVoice arrives without a display name. Fill it in once the device
    /// is seen so it can still be shown while disconnected. Never touches the UID itself.
    private func rememberPreferredNameIfMissing() {
        let settings = AppSettings.shared
        guard let uid = settings.preferredMicUID, settings.preferredMicName == nil,
              let device = device(uid: uid)
        else { return }
        settings.preferredMicName = device.name
    }

    private func installListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]
        for selector in selectors {
            var address = CoreAudioDevices.globalAddress(selector)
            let isDeviceList = selector == kAudioHardwarePropertyDevices
            let status = AudioObjectAddPropertyListenerBlock(system, &address, DispatchQueue.main) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refresh()
                    if isDeviceList { self.scheduleSettledRefresh() }
                }
            }
            if status != noErr {
                NSLog("64Voice: couldn't observe CoreAudio property %u (OSStatus %d)", selector, status)
            }
        }
    }

    /// Bluetooth and Continuity devices can appear before their input streams are configured.
    /// One extra pass a moment later picks them up without a separate per-device listener.
    private var settledRefreshPending = false

    private func scheduleSettledRefresh() {
        guard !settledRefreshPending else { return }
        settledRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settledRefreshPending = false
                self.refresh()
            }
        }
    }
}
