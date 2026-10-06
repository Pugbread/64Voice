import CoreAudio
import Foundation

/// Synchronous CoreAudio HAL queries. Thread-safe; cheap enough for the main thread.
enum CoreAudioDevices {
    /// Every device CoreAudio currently knows about.
    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, raw.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    /// The system default input device (System Settings > Sound > Input).
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = globalAddress(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// Usable input devices, sorted by name.
    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs()
            .compactMap { inputDevice(id: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Describes `id` if it is a live device with input channels. Hidden devices and the
    /// private aggregates CoreAudio creates for AVAudioEngine are skipped unless `includeHidden`.
    static func inputDevice(id: AudioDeviceID, includeHidden: Bool = false) -> AudioInputDevice? {
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { return nil }
        if !includeHidden, isHidden(id) || uid.hasPrefix("CADefaultDeviceAggregate") { return nil }
        guard inputChannelCount(id) > 0, isAlive(id) else { return nil }
        let name = stringProperty(id, kAudioObjectPropertyName) ?? uid
        let transport = uint32Property(id, kAudioDevicePropertyTransportType).flatMap(transportName)
        return AudioInputDevice(id: id, uid: uid, name: name, transport: transport)
    }

    /// True while `id` is still enumerated and reports itself alive.
    static func isPresent(_ id: AudioDeviceID) -> Bool {
        allDeviceIDs().contains(id) && isAlive(id)
    }

    /// kAudioDevicePropertyDeviceIsAlive. Fails open: unusual devices that can't answer count as alive.
    static func isAlive(_ id: AudioDeviceID) -> Bool {
        uint32Property(id, kAudioDevicePropertyDeviceIsAlive).map { $0 != 0 } ?? true
    }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: - Helpers

    static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        (uint32Property(id, kAudioDevicePropertyIsHidden) ?? 0) != 0
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = globalAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    private static func uint32Property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = globalAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func transportName(_ type: UInt32) -> String? {
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return "builtIn"
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetoothLE"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return "aggregate"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "continuity"
        case kAudioDeviceTransportTypeAirPlay: return "airPlay"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayPort"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        case kAudioDeviceTransportTypePCI: return "pci"
        case kAudioDeviceTransportTypeFireWire: return "fireWire"
        case kAudioDeviceTransportTypeAVB: return "avb"
        default: return nil
        }
    }
}
