import CoreAudio
import Foundation

/// A CoreAudio device that has input channels.
///
/// `uid` (kAudioDevicePropertyDeviceUID) is the stable identity that gets persisted;
/// `id` (AudioDeviceID) is only valid while the device is connected and can change on reconnect.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    /// Short transport identifier: "builtIn", "bluetooth", "bluetoothLE", "usb", "virtual",
    /// "aggregate", "continuity", "airPlay", "hdmi", "displayPort", "thunderbolt", "pci",
    /// "fireWire", "avb". `nil` when CoreAudio doesn't report a known transport.
    let transport: String?
}

extension AudioInputDevice {
    /// SF Symbol that fits the device (AirPods, laptop, iPhone, virtual, ...).
    var symbolName: String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("iphone") || transport == "continuity" { return "iphone" }
        if lower.contains("ipad") { return "ipad" }
        if lower.contains("display") { return "display" }
        switch transport {
        case "builtIn": return lower.contains("imac") ? "desktopcomputer" : "laptopcomputer"
        case "bluetooth", "bluetoothLE": return "headphones"
        case "virtual": return "waveform"
        case "aggregate": return "square.stack.3d.up"
        case "airPlay": return "airplayaudio"
        default: return "mic"
        }
    }

    /// Human-readable transport, e.g. "Bluetooth".
    var transportLabel: String? {
        switch transport {
        case "builtIn": return "Built-in"
        case "bluetooth", "bluetoothLE": return "Bluetooth"
        case "usb": return "USB"
        case "virtual": return "Virtual"
        case "aggregate": return "Aggregate"
        case "continuity": return "Continuity"
        case "airPlay": return "AirPlay"
        case "hdmi": return "HDMI"
        case "displayPort": return "DisplayPort"
        case "thunderbolt": return "Thunderbolt"
        case "pci": return "PCI"
        case "fireWire": return "FireWire"
        case "avb": return "AVB"
        default: return nil
        }
    }
}
