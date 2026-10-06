# 64Voice architecture

A small macOS menu-bar dictation app: hold a hotkey, talk, release, and the text is pasted into
whatever app you're typing in. Speech recognition runs on-device (Parakeet via FluidAudio). The
recording "notch" appears at the mouse cursor and flies into the emptiest nearby screen space.

Swift package, executable target `SixtyFourVoice` (Swift module names can't start with a digit),
bundled into `64Voice.app` by `scripts/build-app.sh`. macOS 15+, Swift 5 language mode, SwiftUI + AppKit.

```
Sources/SixtyFourVoice/
  Shared/    AppSettings (UserDefaults-backed), SharedTypes (HotkeyKey, HotkeyMode, SpeechModelChoice, OverlayPhase)
  App/       @main app, AppState orchestrator, menu bar UI              — integration
  Audio/     device list, persistent mic choice, AVAudioEngine capture   — audio & speech
  Speech/    FluidAudio model download/load + transcription            — audio & speech
  Overlay/   cursor notch panel, SwiftUI notch view, placement engine   — overlay
  System/    global hotkey, text insertion, permissions, settings UI   — system
```

## Flow

1. `HotkeyManager` reports key down/up for the chosen modifier key (default Right Option).
2. `AppState` starts `AudioRecorder` on the pinned mic and shows `OverlayController` at the cursor.
3. While recording: levels go to the overlay; every ~0.7 s the last ~12 s of audio is transcribed
   for a live preview.
4. On release (or a second tap in toggle mode): stop, transcribe everything, paste with `TextInserter`.

## Contracts (exact public surface each module provides)

### Audio & Speech
```swift
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID; let uid: String; let name: String; let transport: String?
}
@MainActor final class AudioDeviceManager: ObservableObject {
    static let shared: AudioDeviceManager
    @Published private(set) var inputDevices: [AudioInputDevice]
    @Published private(set) var systemDefaultInput: AudioInputDevice?
    func resolvedInput(preferredUID: String?) -> AudioInputDevice?   // preferred if connected, else system default
    func isConnected(uid: String) -> Bool
}
@MainActor final class AudioRecorder {
    var onLevel: ((Float) -> Void)?            // main thread, ~30–60 Hz, 0...1
    var onInterruption: ((String) -> Void)?    // main thread; device vanished / engine failed mid-recording
    private(set) var isRecording: Bool
    private(set) var activeDeviceName: String?
    var capturedDuration: Double { get }       // seconds
    func start(preferredUID: String?) throws
    func stop() -> [Float]                     // all audio, 16 kHz mono Float32
    func cancel()
    func recentSamples(seconds: Double) -> [Float]   // thread-safe tail copy, 16 kHz mono
}
@MainActor final class TranscriptionEngine: ObservableObject {
    static let shared: TranscriptionEngine
    enum State: Equatable { case idle, downloading(Double), loading, ready, failed(String) }
    @Published private(set) var state: State
    @Published private(set) var loadedModel: SpeechModelChoice?
    func prepare() async                                   // idempotent; uses AppSettings.shared.speechModel
    func transcribe(_ samples: [Float]) async throws -> String
}
struct MicrophonePickerView: View   // settings section body
struct ModelStatusView: View        // settings section body
```

### Overlay
```swift
@MainActor final class OverlayController {
    static let shared: OverlayController
    func show(phase: OverlayPhase)
    func setPhase(_ phase: OverlayPhase)
    func setLevel(_ level: Float)
    func setTranscript(_ text: String)
    func hide(after delay: TimeInterval = 0)
}
```

### System
```swift
@MainActor final class HotkeyManager {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onChord: (() -> Void)?       // another key pressed while the hotkey was held (e.g. ⌥A)
    var onEscape: (() -> Void)?      // only while interceptEscape == true; the event is swallowed
    var interceptEscape: Bool
    var isRunning: Bool { get }
    @discardableResult func start() -> Bool   // false if Accessibility isn't granted
    func stop()
}
@MainActor final class TextInserter {
    func insert(_ text: String) async -> Bool
}
enum PermissionStatus { case granted, denied, notDetermined }
@MainActor final class PermissionsManager: ObservableObject {
    static let shared: PermissionsManager
    @Published private(set) var microphone: PermissionStatus
    @Published private(set) var accessibility: Bool
    @Published private(set) var screenRecording: Bool
    func refresh()
    func requestMicrophone() async -> Bool
    func requestAccessibility()
    func requestScreenRecording()
}
enum Sounds { static func playStart(); static func playStop(); static func playError() }
struct SettingsView: View
```
