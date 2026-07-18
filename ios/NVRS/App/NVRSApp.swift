import SwiftUI
import UserNotifications

@main
struct NVRSApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var viewModel: MirrorViewModel

    init() {
        let settings = SettingsStore.shared
        _settings = StateObject(wrappedValue: settings)
        _viewModel = StateObject(wrappedValue: MirrorViewModel(settings: settings))
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(viewModel)
        }
    }
}
