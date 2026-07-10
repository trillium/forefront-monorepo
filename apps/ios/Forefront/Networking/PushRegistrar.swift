#if canImport(UIKit)
import UIKit
import UserNotifications
import ForefrontModels

/// Thin wrapper around APNs registration + notification categories. Owned by the
/// AppDelegate.
///
/// Two push classes coexist (contract §4 vs §11, D-15):
///   - **Silent** deck refresh (`content-available`), no user-visible permission
///     strictly required.
///   - **Visible + actionable** chat reminders (`FF_REMINDER` / `FF_QUESTION`)
///     with lock-screen actions (Done / Snooze / Reply).
///
/// Permission is requested at a **contextual moment** (first chat open), not
/// blindly at launch — see `requestVisiblePermission()`.
@MainActor
public final class PushRegistrar {
    private let api: APIClient

    public init(api: APIClient) { self.api = api }

    // MARK: - Category identifiers (must match the APNs payload `category`)

    public enum Category {
        public static let reminder = "FF_REMINDER"
        public static let question = "FF_QUESTION"
    }

    /// Action identifiers surfaced in the AppDelegate's response handler.
    public enum Action {
        public static let done = "FF_ACTION_DONE"
        public static let snooze = "FF_ACTION_SNOOZE"
        public static let reply = "FF_ACTION_REPLY"
    }

    /// Register actionable categories with the notification center. Idempotent —
    /// safe to call on every launch. Must run before the first notification
    /// arrives so iOS can render the action buttons.
    public func registerCategories() {
        let done = UNNotificationAction(
            identifier: Action.done,
            title: "Done",
            options: [.authenticationRequired]
        )
        let snooze = UNNotificationAction(
            identifier: Action.snooze,
            title: "Snooze",
            options: []
        )
        let reply = UNTextInputNotificationAction(
            identifier: Action.reply,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message"
        )
        let reminder = UNNotificationCategory(
            identifier: Category.reminder,
            actions: [done, snooze, reply],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        // Questions reuse Done + Reply (quick-replies render in-app; the push
        // affordance is a fast Done or a free-text Reply).
        let question = UNNotificationCategory(
            identifier: Category.question,
            actions: [done, reply],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([reminder, question])
    }

    /// Silent-push registration path (deck). Registers for remote notifications
    /// without demanding visible permission. Best-effort; launch-poll still runs.
    /// Also installs the actionable categories so a later visible push renders
    /// its buttons.
    public func registerSilent() async {
        registerCategories()
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Request **visible** notification permission at a contextual moment (first
    /// chat open). Returns whether the user granted it. Registers for remote
    /// notifications on grant so the device token flows to the backend.
    @discardableResult
    public func requestVisiblePermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            registerCategories()
            UIApplication.shared.registerForRemoteNotifications()
            return true
        case .denied:
            EventLog.shared.warn("push", "Notification permission previously denied")
            return false
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            if granted {
                registerCategories()
                UIApplication.shared.registerForRemoteNotifications()
                EventLog.shared.success("push", "Notification permission granted")
            } else {
                EventLog.shared.warn("push", "Notification permission denied by user")
            }
            return granted
        @unknown default:
            return false
        }
    }

    /// Called from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    /// ISC-90: backend endpoint name `/push/register` is a placeholder; confirm with backend.
    public func didRegister(deviceToken: Data) {
        Task.detached(priority: .utility) {
            try? await self.api.registerDeviceToken(deviceToken)
        }
    }
}
#endif
