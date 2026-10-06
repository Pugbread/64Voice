import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Pastes text into the frontmost app: put it on the clipboard, press ⌘V, then put the user's
/// previous clipboard back.
@MainActor
final class TextInserter {
    /// How long the target app gets to read the pasteboard before it is restored. Electron apps,
    /// terminals and remote desktops can take a few hundred milliseconds.
    private let restoreDelay: Duration = .milliseconds(400)
    /// Max wait for the user to let go of ⌥/⌘/… so ⌘V doesn't arrive as ⌥⌘V.
    private let modifierReleaseTimeout: TimeInterval = 0.3

    private var lastInsert: Task<Bool, Never>?
    private var pendingRestore: Task<Void, Never>?

    init() {
        PasteKeyResolver.shared.start()
    }

    /// Returns false if the text is empty, Accessibility isn't granted (events can't be posted),
    /// or the clipboard couldn't be written. True means ⌘V was sent, not that the app accepted it.
    func insert(_ text: String) async -> Bool {
        let previous = lastInsert
        let task = Task { @MainActor [weak self] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            return await self.performInsert(text)
        }
        lastInsert = task
        return await task.value
    }

    private func performInsert(_ text: String) async -> Bool {
        guard !text.isEmpty, AXIsProcessTrusted() else { return false }

        // The previous paste may still be waiting to restore the clipboard. Let it finish so our
        // temporary text is never captured as "the user's clipboard".
        if let pending = pendingRestore {
            await pending.value
            pendingRestore = nil
        }

        await waitForModifiersReleased()

        let pasteboard = NSPasteboard.general
        let restore = AppSettings.shared.restoreClipboard
        let saved = restore ? PasteboardSnapshot(pasteboard) : nil

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if restore {
            // Clipboard managers skip these (nspasteboard.org), so the temporary text stays out of history.
            item.setData(Data(), forType: .transientMarker)
            item.setData(Data(), forType: .concealedMarker)
        }
        guard pasteboard.writeObjects([item]) else {
            saved?.restore(to: pasteboard, ifUnchangedSince: pasteboard.changeCount)
            return false
        }
        let ourChangeCount = pasteboard.changeCount

        let posted = Self.postCommandV(keyCode: PasteKeyResolver.shared.keyCode)

        if let saved {
            let delay = restoreDelay
            pendingRestore = Task { @MainActor in
                if posted { try? await Task.sleep(for: delay) }
                // If the user copied something in the meantime, theirs wins.
                saved.restore(to: pasteboard, ifUnchangedSince: ourChangeCount)
            }
        }
        return posted
    }

    // MARK: Keystroke

    private static let modifierKeyCodes: [CGKeyCode] = [
        CGKeyCode(kVK_Command), CGKeyCode(kVK_RightCommand),
        CGKeyCode(kVK_Option), CGKeyCode(kVK_RightOption),
        CGKeyCode(kVK_Control), CGKeyCode(kVK_RightControl),
        CGKeyCode(kVK_Shift), CGKeyCode(kVK_RightShift),
        CGKeyCode(kVK_Function),
    ]

    static func physicalModifiersHeld() -> Bool {
        modifierKeyCodes.contains { CGEventSource.keyState(.hidSystemState, key: $0) }
    }

    private func waitForModifiersReleased() async {
        let deadline = ProcessInfo.processInfo.systemUptime + modifierReleaseTimeout
        while Self.physicalModifiersHeld(), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// ⌘ down, V down, V up, ⌘ up from a private event source, each with explicit flags, so
    /// whatever the user is still holding can't leak in. Pressing and releasing ⌘ itself (rather
    /// than only flagging V) keeps apps that read key state happy and leaves no "stuck" ⌘.
    private static func postCommandV(keyCode v: CGKeyCode) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        let command = CGKeyCode(kVK_Command)
        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false)
        else { return false }

        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        commandUp.flags = []
        for event in [commandDown, vDown, vUp, commandUp] {
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEventMarker.userData)
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}

extension NSPasteboard.PasteboardType {
    static let transientMarker = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedMarker = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
}

// MARK: - Pasteboard snapshot

/// Every item and every representation on a pasteboard (text, rich text, images, files, …),
/// in their original order.
struct PasteboardSnapshot {
    let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type: type, data: $0) }
            }
        }
    }

    /// Restores the snapshot only if nobody wrote to the pasteboard since `changeCount`.
    @discardableResult
    func restore(to pasteboard: NSPasteboard, ifUnchangedSince changeCount: Int) -> Bool {
        guard pasteboard.changeCount == changeCount else { return false }
        pasteboard.clearContents()
        let restored = items.filter { !$0.isEmpty }.map { representations in
            let item = NSPasteboardItem()
            for representation in representations {
                item.setData(representation.data, forType: representation.type)
            }
            return item
        }
        return restored.isEmpty || pasteboard.writeObjects(restored)
    }
}

// MARK: - Layout-aware ⌘V

/// The virtual key code that types "v" with ⌘ held in the current keyboard layout
/// (47 on Dvorak, 9 on QWERTY/AZERTY and on Dvorak-QWERTY⌘). Cached, and refreshed when the
/// input source changes.
@MainActor
final class PasteKeyResolver {
    static let shared = PasteKeyResolver()
    static let ansiV = CGKeyCode(kVK_ANSI_V)

    private(set) var keyCode: CGKeyCode = PasteKeyResolver.ansiV
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Hop once more so TIS has finished switching before we read the new layout.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    func refresh() {
        keyCode = Self.resolveCurrent()
    }

    /// Current layout first; input methods without layout data (e.g. CJK) fall back to the
    /// ASCII-capable layout that macOS uses for their shortcuts; then ANSI V.
    static func resolveCurrent() -> CGKeyCode {
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let code = keyCode(for: "v", in: source)
        { return code }
        if let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let code = keyCode(for: "v", in: source)
        { return code }
        return ansiV
    }

    static func keyCode(for character: Character, in source: TISInputSource) -> CGKeyCode? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return keyCode(for: character, layoutData: data)
    }

    /// Scans the layout's ⌘ table first (Dvorak-QWERTY⌘ switches to QWERTY while ⌘ is held),
    /// then the plain table.
    static func keyCode(for character: Character, layoutData: Data) -> CGKeyCode? {
        guard let target = character.utf16.first, !layoutData.isEmpty else { return nil }
        let keyboardType = UInt32(LMGetKbdType())
        return layoutData.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var characters = [UniChar](repeating: 0, count: 4)
            for modifiers in [UInt32((cmdKey >> 8) & 0xFF), 0] {
                for key: UInt16 in 0 ..< 128 {
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    let status = UCKeyTranslate(
                        layout,
                        key,
                        UInt16(kUCKeyActionDisplay),
                        modifiers,
                        keyboardType,
                        OptionBits(kUCKeyTranslateNoDeadKeysMask),
                        &deadKeyState,
                        characters.count,
                        &length,
                        &characters
                    )
                    if status == noErr, length == 1, characters[0] == target { return CGKeyCode(key) }
                }
            }
            return nil
        }
    }
}
