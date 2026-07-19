import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Speaks a short status line through the running screen reader
/// (VoiceOver on both platforms).
enum Announce {
    @MainActor
    static func post(_ text: String) {
        #if os(iOS)
        UIAccessibility.post(notification: .announcement, argument: text)
        #elseif os(macOS)
        let element: Any
        if let window = NSApplication.shared.mainWindow {
            element = window
        } else {
            element = NSApplication.shared
        }
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
        #endif
    }
}
