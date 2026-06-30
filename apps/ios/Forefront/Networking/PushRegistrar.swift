#if canImport(UIKit)
import UIKit
import UserNotifications

/// Thin wrapper around APNs registration. Owned by the AppDelegate.
@MainActor
public final class PushRegistrar {
    private let api: APIClient

    public init(api: APIClient) { self.api = api }

    /// Requests permission (silent-push only requires `.providesAppNotificationSettings`-style
    /// minimal grant) and registers for remote notifications. Best-effort.
    public func register() async {
        let center = UNUserNotificationCenter.current()
        // For silent push only, we don't strictly need user-visible permission.
        // We still request a minimal grant so the future option to surface a
        // banner is unblocked. Failure is non-fatal; launch-poll still runs.
        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
        UIApplication.shared.registerForRemoteNotifications()
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
