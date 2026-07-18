import Foundation
import UserNotifications

/// Posts a local notification when mirrored speech matches a user filter.
/// Rides on the already-alive background-audio session; no push involved.
final class NotificationFilterEngine {
    var filters: [NotificationFilter] = []

    /// Don't re-notify for the same filter within this window.
    private let perFilterCooldown: TimeInterval = 10
    private var lastFired: [UUID: Date] = [:]

    func process(_ text: String) {
        guard !text.isEmpty else { return }
        let now = Date()
        for filter in filters where filter.isEnabled && !filter.pattern.isEmpty {
            if let last = lastFired[filter.id], now.timeIntervalSince(last) < perFilterCooldown {
                continue
            }
            guard matches(filter, text: text) else { continue }
            lastFired[filter.id] = now
            postNotification(pattern: filter.pattern, text: text)
        }
    }

    private func matches(_ filter: NotificationFilter, text: String) -> Bool {
        if filter.isRegex {
            return (try? NSRegularExpression(pattern: filter.pattern, options: [.caseInsensitive]))
                .map {
                    $0.firstMatch(
                        in: text,
                        options: [],
                        range: NSRange(text.startIndex..., in: text)
                    ) != nil
                } ?? false
        }
        return text.localizedCaseInsensitiveContains(filter.pattern)
    }

    private func postNotification(pattern: String, text: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "NVDA spoke “\(pattern)”")
        content.body = String(text.prefix(200))
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

/// iOS suppresses banners/sounds for notifications posted by the
/// foregrounded app unless a delegate opts in — without this, filter
/// alerts vanish exactly while the app is open.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
