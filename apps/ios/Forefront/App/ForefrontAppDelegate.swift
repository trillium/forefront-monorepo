#if canImport(UIKit)
import UIKit
import UserNotifications
import ForefrontModels
import ForefrontNetworking
import ForefrontQueue

/// AppDelegate handles APNs registration + push delivery for BOTH classes:
///   - **Silent** deck refresh (`content-available`) → runs the launch refresh.
///   - **Visible + actionable** chat reminders (`FF_REMINDER`/`FF_QUESTION`) →
///     presented while foregrounded, tap deep-links into the chat, and the
///     Done/Snooze/Reply actions post user messages via the chat outbox (§11).
public final class ForefrontAppDelegate: NSObject, UIApplicationDelegate {

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Become the notification-center delegate so foreground presentation and
        // action responses route here.
        UNUserNotificationCenter.current().delegate = self

        // Register (silent) + install actionable categories. Visible permission is
        // requested contextually on first chat open, not here (D-15).
        Task { @MainActor in
            let env = AppEnvironment.shared
            let registrar = PushRegistrar(api: env.api)
            await registrar.registerSilent()
        }
        return true
    }

    public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            let env = AppEnvironment.shared
            PushRegistrar(api: env.api).didRegister(deviceToken: deviceToken)
        }
    }

    public func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Silent fail — launch poll still runs (ISC-91).
    }

    /// Silent push handler. iOS allows ~30 s of background time; we use it to
    /// run the same refresh path as launch (ISC-87, ISC-91, ISC-92). A chat
    /// alert push arrives through `UNUserNotificationCenterDelegate` instead, so
    /// here we only handle the silent (`content-available`) deck case and also
    /// opportunistically sync the chat inbox + drain the outbox.
    public func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let env = AppEnvironment.shared
            // Silent push is an automatic trigger — throttled and coalesced.
            let outcome = await env.service.refresh(trigger: .automatic, now: Date())
            // Opportunistic chat drain (best-effort; does not gate the result).
            #if canImport(SwiftUI)
            Task { await ChatEnvironment.shared.drainOutbox() }
            #endif
            switch outcome {
            case .unchanged: completionHandler(.noData)
            case .updated(let stack):
                env.queue.adopt(stack)
                completionHandler(.newData)
            case .offline:
                completionHandler(.failed)
            case .unauthorized:
                env.needsReauth = true
                completionHandler(.failed)
            case .throttled:
                // A refresh ran too recently; nothing new to report.
                completionHandler(.noData)
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate (visible + actionable chat push)

extension ForefrontAppDelegate: UNUserNotificationCenterDelegate {

    /// Present chat reminders while the app is foregrounded (banner + sound), so
    /// a nag is visible even when the user is already in the app.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    /// Handle a tap or an action button on a chat notification.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let chatId = userInfo["chatId"] as? String

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            // A plain tap → deep-link into the chat.
            routeToChat(chatId)

        case PushRegistrar.Action.done:
            postActionMessage(chatId: chatId, body: "Done")

        case PushRegistrar.Action.snooze:
            // Backend owns re-scheduling; the client only records the intent.
            postActionMessage(chatId: chatId, body: "Snooze")

        case PushRegistrar.Action.reply:
            if let textResponse = response as? UNTextInputNotificationResponse {
                let text = textResponse.userText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { postActionMessage(chatId: chatId, body: text) }
            }

        case UNNotificationDismissActionIdentifier:
            break  // Explicit dismiss — nothing to do.

        default:
            break
        }
        completionHandler()
    }

    /// Route the UI to the Chats tab / the specific thread via the deep-link
    /// notification `AppRoot` observes.
    private func routeToChat(_ chatId: String?) {
        var info: [String: Any] = [:]
        if let chatId { info["chatId"] = chatId }
        NotificationCenter.default.post(name: .forefrontOpenChat, object: nil, userInfo: info)
    }

    /// Post a user message for a notification action (Done/Snooze/Reply). Goes
    /// through the chat outbox so it is idempotent and survives being off-tailnet
    /// — acting on a reminder needs the tailnet (contract §11), and the outbox is
    /// exactly the mechanism that lets the action queue until reconnect.
    private func postActionMessage(chatId: String?, body: String) {
        guard let chatId else { return }
        #if canImport(SwiftUI)
        Task { @MainActor in
            let chatEnv = ChatEnvironment.shared
            await chatEnv.openThread(chatId)
            await chatEnv.send(body)
        }
        #endif
        // Also surface the chat so the user sees the result of their action.
        routeToChat(chatId)
    }
}
#endif
