import Foundation
import UserNotifications

/// Posts the "queue finished" notification (Settings ▸ Transfers, M16) when
/// the setting is on. Requests authorization lazily on first use; if the user
/// denies it, posts are silently skipped. Works in both build flavors.
enum QueueNotifier {
    static func notifyQueueFinished(completed: Int) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                post(center, completed: completed)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { post(center, completed: completed) }
                }
            default:
                break // denied — respect the user's choice
            }
        }
    }

    private static func post(_ center: UNUserNotificationCenter, completed: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Transfers complete"
        content.body = completed == 1
            ? "Ferry finished 1 transfer."
            : "Ferry finished \(completed) transfers."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        center.add(request)
    }
}
