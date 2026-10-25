import SwiftUI

@main
struct NVRSApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var viewModel: MirrorViewModel

    init() {
        let settings = SettingsStore.shared
        let viewModel = MirrorViewModel(settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _viewModel = StateObject(wrappedValue: viewModel)
        #if os(macOS)
        MainWindowController.shared.configure(settings: settings, viewModel: viewModel)
        // Nothing to connect to yet: without the window a first launch
        // would show no sign of the app beyond its menu-bar icon. Deferred
        // until the app has finished launching.
        if settings.host.isEmpty {
            DispatchQueue.main.async {
                MainWindowController.shared.show()
            }
        }
        #endif
    }

    var body: some Scene {
        #if os(iOS)
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(viewModel)
        }
        #else
        // A menu-bar app (LSUIElement): no Dock icon and no window until
        // one is asked for from the menu.
        MenuBarExtra("NVRS", systemImage: "waveform") {
            MenuBarMenu()
                .environmentObject(viewModel)
        }
        .menuBarExtraStyle(.menu)
        #endif
    }
}
