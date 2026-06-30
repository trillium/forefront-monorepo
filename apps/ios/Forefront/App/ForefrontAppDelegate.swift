#if canImport(UIKit)
import UIKit

/// AppDelegate handles APNs registration + silent push delivery.
public final class ForefrontAppDelegate: NSObject, UIApplicationDelegate {

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Push registration is best-effort and runs at first foreground.
        Task { @MainActor in
            let env = AppEnvironment.shared
            let registrar = PushRegistrar(api: env.api)
            await registrar.register()
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
    /// run the same refresh path as launch (ISC-87, ISC-91, ISC-92).
    public func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let env = AppEnvironment.shared
            let outcome = await env.service.refresh()
            switch outcome {
            case .unchanged: completionHandler(.noData)
            case .updated(let stack):
                env.queue.adopt(stack)
                completionHandler(.newData)
            case .offline:
                completionHandler(.failed)
            case .unauthorized:
                completionHandler(.failed)
            }
        }
    }
}
#endif
