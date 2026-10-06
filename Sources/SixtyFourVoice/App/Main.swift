import AppKit
import SwiftUI

@main
@MainActor
enum Main {
    static func main() {
        let args = CommandLine.arguments

        // Dev: `64Voice --transcribe file.wav` prints a transcript and exits.
        if let index = args.firstIndex(of: "--transcribe"), index + 1 < args.count {
            let path = args[index + 1]
            Task { @MainActor in
                await DevTools.transcribeFile(path)
                exit(0)
            }
            dispatchMain()
        }

        SixtyFourVoiceApp.main()
    }
}

struct SixtyFourVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
        } label: {
            Image(systemName: state.status == .idle ? "waveform" : "waveform.circle.fill")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        if Self.anotherInstanceIsRunning() {
            NSApp.terminate(nil)
            return
        }

        MainActor.assumeIsolated {
            if CommandLine.arguments.contains("--demo-overlay") {
                DevTools.runOverlayDemo()
                return
            }

            AppState.shared.start()

            let permissions = PermissionsManager.shared
            permissions.refresh()
            if !permissions.accessibility || permissions.microphone != .granted {
                SettingsWindowController.shared.show()
            }
        }
    }

    /// Opening the app again (Spotlight, Finder) shows Settings, in case the menu bar icon is
    /// hidden behind the notch on a crowded menu bar.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        MainActor.assumeIsolated { SettingsWindowController.shared.show() }
        return false
    }

    private static func anotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        others.first?.activate()
        return !others.isEmpty
    }
}
