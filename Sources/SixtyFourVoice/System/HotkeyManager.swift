import AppKit
import ApplicationServices
import Combine
import CoreGraphics

/// `eventSourceUserData` stamped on keyboard events 64Voice synthesizes (the ⌘V paste),
/// so our own hotkey tap passes them through untouched.
enum SyntheticEventMarker {
    static let userData: Int64 = 0x3634_566F // "64Vo"
}

/// Watches the dictation key (a modifier-only key such as Right Option) system-wide.
///
/// - The event tap is serviced on its own thread, so a busy main thread never stalls typing.
/// - Callbacks are delivered asynchronously on the main thread, in event order.
/// - `onKeyDown` / `onKeyUp` always come in pairs. `onChord` fires at most once per reported hold,
///   between those two. A press made while another modifier is already held (⌘ then right ⌥) is
///   a chord from the start and reports nothing at all.
/// - The hotkey's own modifier events are never swallowed. Only Escape is, while `interceptEscape`.
@MainActor
final class HotkeyManager {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    /// Another key was pressed while the hotkey was held (e.g. ⌥A).
    var onChord: (() -> Void)?
    /// Escape was pressed while `interceptEscape` is true. That Escape never reaches other apps.
    var onEscape: (() -> Void)?

    var interceptEscape: Bool {
        get { tap.interceptEscape }
        set { tap.interceptEscape = newValue }
    }

    var isRunning: Bool { tap.isEnabled }

    private let tap: HotkeyEventTap
    private let relay: Relay
    private var hotkeyObserver: AnyCancellable?
    private var accessibilityPoll: Timer?

    init() {
        let relay = Relay()
        self.relay = relay
        tap = HotkeyEventTap(hotkey: AppSettings.shared.hotkey) { event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { relay.manager?.deliver(event) }
            }
        }
        relay.manager = self
        hotkeyObserver = AppSettings.shared.$hotkey
            .removeDuplicates()
            .sink { [weak self] key in self?.tap.setHotkey(key) }
    }

    /// Installs the event tap. Returns false if Accessibility isn't granted or the tap couldn't be
    /// created; in that case it keeps checking every 2 s and starts by itself once access is granted.
    @discardableResult
    func start() -> Bool {
        let running = tap.isEnabled || tap.install()
        if running {
            stopAccessibilityPoll()
        } else {
            startAccessibilityPoll()
        }
        return running
    }

    func stop() {
        stopAccessibilityPoll()
        tap.uninstall()
    }

    private func deliver(_ event: HotkeyEventTap.Event) {
        switch event {
        case .keyDown: onKeyDown?()
        case .keyUp: onKeyUp?()
        case .chord: onChord?()
        case .escape: onEscape?()
        }
    }

    private func startAccessibilityPoll() {
        guard accessibilityPoll == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.start()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityPoll = timer
    }

    private func stopAccessibilityPoll() {
        accessibilityPoll?.invalidate()
        accessibilityPoll = nil
    }

    /// Lets the tap's `@Sendable` emit closure reach the manager without retaining it.
    @MainActor
    private final class Relay {
        weak var manager: HotkeyManager?
    }
}

// MARK: - Event tap

/// The CGEvent tap and the hotkey state machine. Runs on the tap thread; all state is behind `lock`.
final class HotkeyEventTap: @unchecked Sendable {
    enum Event: Sendable {
        case keyDown, keyUp, chord, escape
    }

    private static let escapeKeyCode: CGKeyCode = 53

    private let lock = NSLock()
    private let emit: @Sendable (Event) -> Void

    // Guarded by `lock`.
    private var hotkey: HotkeyKey
    private var escapeIntercepted = false
    /// The hotkey is physically down, as far as the event stream tells.
    private var isHeld = false
    /// `keyDown` was emitted for the current hold (false for a hold that began as a chord).
    private var isReported = false
    private var chordReported = false
    /// A swallowed Escape keyDown; its keyUp is swallowed too.
    private var swallowingEscape = false
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedSelf: Unmanaged<HotkeyEventTap>?

    init(hotkey: HotkeyKey, emit: @escaping @Sendable (Event) -> Void) {
        self.hotkey = hotkey
        self.emit = emit
    }

    var interceptEscape: Bool {
        get { withLock { escapeIntercepted } }
        set { withLock { escapeIntercepted = newValue } }
    }

    var isEnabled: Bool {
        guard let port = withLock({ machPort }) else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    func setHotkey(_ key: HotkeyKey) {
        let wasReported: Bool = withLock {
            guard key != hotkey else { return false }
            let wasReported = isReported
            hotkey = key
            resetHoldLocked()
            return wasReported
        }
        if wasReported { emit(.keyUp) }
    }

    // MARK: Install

    func install() -> Bool {
        if isEnabled { return true }
        uninstall()
        guard AXIsProcessTrusted() else { return false }

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        let retained = Unmanaged.passRetained(self)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: retained.toOpaque()
        ) else {
            retained.release()
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            retained.release()
            return false
        }

        withLock {
            machPort = port
            runLoopSource = source
            retainedSelf = retained
            resetHoldLocked()
        }
        let runLoop = TapThread.runLoop
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopWakeUp(runLoop)

        if CGEvent.tapIsEnabled(tap: port) { return true }
        uninstall()
        return false
    }

    func uninstall() {
        let (port, source, retained) = withLock {
            let parts = (machPort, runLoopSource, retainedSelf)
            machPort = nil
            runLoopSource = nil
            retainedSelf = nil
            resetHoldLocked()
            return parts
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source {
            CFRunLoopRemoveSource(TapThread.runLoop, source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        retained?.release()
    }

    // MARK: Event handling (tap thread)

    /// Decides what to do with one event. Internal (not private) so it can be unit-tested with
    /// hand-built events, without installing a tap.
    func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = withLock({ machPort }) {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return passThrough
        case .flagsChanged, .keyDown, .keyUp:
            break
        default:
            return passThrough
        }

        if event.getIntegerValueField(.eventSourceUserData) == SyntheticEventMarker.userData {
            return passThrough
        }

        let keyCode = CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        var events: [Event] = []
        var swallow = false

        lock.lock()
        let key = hotkey
        let hotkeyIsDown = Self.isDown(key, flags: flags)
        switch type {
        case .flagsChanged:
            if keyCode == key.keyCode {
                if hotkeyIsDown, !isHeld {
                    isHeld = true
                    chordReported = false
                    isReported = !Self.hasOtherModifiers(besides: key, flags: flags)
                    if isReported { events.append(.keyDown) }
                } else if !hotkeyIsDown, isHeld {
                    releaseLocked(into: &events)
                }
            } else if isHeld, !hotkeyIsDown {
                // Every flagsChanged carries the full modifier state: heal a missed release.
                releaseLocked(into: &events)
            }

        case .keyDown:
            if isHeld, !hotkeyIsDown { releaseLocked(into: &events) }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if escapeIntercepted, keyCode == Self.escapeKeyCode, !escapeBlockedLocked(by: flags) {
                swallow = true
                swallowingEscape = true
                if !isRepeat { events.append(.escape) }
            } else if isReported, !chordReported, !isRepeat {
                // Autorepeats are ignored: they come from a key that was already down before.
                chordReported = true
                events.append(.chord)
            }

        case .keyUp:
            if keyCode == Self.escapeKeyCode, swallowingEscape {
                swallowingEscape = false
                swallow = true
            }

        default:
            break
        }
        lock.unlock()

        for event in events { emit(event) }
        return swallow ? nil : passThrough
    }

    private func releaseLocked(into events: inout [Event]) {
        isHeld = false
        chordReported = false
        if isReported {
            isReported = false
            events.append(.keyUp)
        }
    }

    private func resetHoldLocked() {
        isHeld = false
        isReported = false
        chordReported = false
        swallowingEscape = false
    }

    /// ⌘/⌃ + Escape (Force Quit is ⌥⌘Esc) always reach the system.
    private func escapeBlockedLocked(by flags: CGEventFlags) -> Bool {
        var blocking: CGEventFlags = [.maskCommand, .maskControl]
        if isHeld { blocking.remove(hotkey.modifierFlag) }
        return !flags.intersection(blocking).isEmpty
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: Modifier flags

    /// Device-dependent (left/right) modifier bits from IOKit's NX_DEVICE*KEYMASK.
    private struct Family {
        let flag: CGEventFlags
        let left: UInt64
        let right: UInt64
    }

    private static let shift = Family(flag: .maskShift, left: 0x02, right: 0x04)
    private static let control = Family(flag: .maskControl, left: 0x01, right: 0x2000)
    private static let option = Family(flag: .maskAlternate, left: 0x20, right: 0x40)
    private static let command = Family(flag: .maskCommand, left: 0x08, right: 0x10)
    private static let families = [shift, control, option, command]

    private static func family(of key: HotkeyKey) -> Family? {
        switch key {
        case .rightOption: option
        case .rightCommand: command
        case .rightControl: control
        case .fn: nil
        }
    }

    /// Whether the hotkey is held according to an event's flags. Right-side keys are told apart
    /// from left-side ones by the device bits; sources that don't set them fall back to the flag.
    static func isDown(_ key: HotkeyKey, flags: CGEventFlags) -> Bool {
        guard let family = family(of: key) else { return flags.contains(.maskSecondaryFn) }
        let raw = flags.rawValue
        if raw & (family.left | family.right) == 0 { return flags.contains(family.flag) }
        return raw & family.right != 0
    }

    /// Any modifier other than the hotkey itself (including the left twin of a right-side hotkey).
    /// Fn is ignored here: macOS also sets it for arrow and function keys.
    static func hasOtherModifiers(besides key: HotkeyKey, flags: CGEventFlags) -> Bool {
        let raw = flags.rawValue
        let own = family(of: key)
        for family in families {
            if family.left == own?.left {
                if raw & family.left != 0 { return true }
            } else if flags.contains(family.flag) {
                return true
            }
        }
        return false
    }
}

private func hotkeyTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<HotkeyEventTap>.fromOpaque(refcon).takeUnretainedValue().process(type: type, event: event)
}

/// One long-lived thread whose run loop services the keyboard tap.
private enum TapThread {
    nonisolated(unsafe) static let runLoop: CFRunLoop = {
        final class Box: @unchecked Sendable { var runLoop: CFRunLoop? }
        let box = Box()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.runLoop = CFRunLoopGetCurrent()
            // A port keeps the run loop alive while no tap source is attached.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            while true { CFRunLoopRun() }
        }
        thread.name = "64Voice.hotkey-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return box.runLoop!
    }()
}
