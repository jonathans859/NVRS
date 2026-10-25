#if os(macOS)
import AppKit
import SwiftUI

/// The full NVRS window, opened from the menu bar on demand rather than
/// living on screen for the whole session. Owned by AppKit instead of a
/// SwiftUI `Window` scene because macOS 14 has no way to stop such a scene
/// opening at launch.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()

    private var settings: SettingsStore?
    private var viewModel: MirrorViewModel?
    private var window: NSWindow?

    func configure(settings: SettingsStore, viewModel: MirrorViewModel) {
        self.settings = settings
        self.viewModel = viewModel
    }

    func show() {
        guard let settings, let viewModel else { return }
        // A menu-bar app's window is missing from Cmd-Tab, and so
        // unreachable by keyboard once the user switches away, unless the
        // app is a regular app while the window is open. The Dock icon
        // comes along with it.
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let root = ContentView()
                .environmentObject(settings)
                .environmentObject(viewModel)
            let window = ClosableWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "NVRS"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("NVRSMainWindow")
            self.window = window
        }
        // The deprecated form on purpose: the cooperative NSApp.activate()
        // may leave an accessory app behind the frontmost one.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Cmd-W closes the window even when the app's main menu has no Close
/// item, which a menu-bar-only SwiftUI app is not guaranteed to have.
private final class ClosableWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
#endif
