import CoreGraphics
import Foundation

/// The key that starts dictation. Modifier-only keys, detected via flagsChanged events.
enum HotkeyKey: String, CaseIterable, Identifiable, Codable, Sendable {
    case rightOption
    case rightCommand
    case rightControl
    case fn

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rightOption: "Right Option ⌥"
        case .rightCommand: "Right Command ⌘"
        case .rightControl: "Right Control ⌃"
        case .fn: "Fn / Globe 🌐"
        }
    }

    /// Virtual key code reported in flagsChanged events for this key.
    var keyCode: CGKeyCode {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .fn: 63
        }
    }

    /// The modifier flag that is set while this key is held.
    var modifierFlag: CGEventFlags {
        switch self {
        case .rightOption: .maskAlternate
        case .rightCommand: .maskCommand
        case .rightControl: .maskControl
        case .fn: .maskSecondaryFn
        }
    }
}

enum HotkeyMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Hold to talk, or quick-tap to start hands-free and tap again to stop.
    case hybrid
    /// Recording only while the key is held.
    case hold
    /// Tap to start, tap to stop.
    case toggle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hybrid: "Hold or tap"
        case .hold: "Hold to talk"
        case .toggle: "Tap to toggle"
        }
    }
}

enum SpeechModelChoice: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Parakeet TDT 0.6B v2 — English only, best English accuracy.
    case parakeetV2
    /// Parakeet TDT 0.6B v3 — 25 European languages.
    case parakeetV3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeetV2: "Parakeet v2 · English"
        case .parakeetV3: "Parakeet v3 · Multilingual"
        }
    }
}

/// What the overlay notch is showing.
enum OverlayPhase: Equatable, Sendable {
    case listening
    case transcribing
    case done
    case error(String)
}
