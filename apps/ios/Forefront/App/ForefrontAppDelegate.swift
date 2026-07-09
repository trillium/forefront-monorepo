#if canImport(UIKit)
import UIKit
import ForefrontModels
import ForefrontNetworking
import ForefrontQueue

/// AppDelegate handles APNs registration + silent push delivery.
public final class ForefrontAppDelegate: NSObject, UIApplicationDelegate {

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Push registration is best-effort and runs at first foreground.
        // ISC-166: never register for push in demo mode — App Review has no server
        // and no push infrastructure to talk to.
        Task { @MainActor in
            let env = AppEnvironment.shared
            guard !env.isDemoMode else { return }
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
            // ISC-166: demo mode never talks to a server; report no data and bail.
            guard !env.isDemoMode else { completionHandler(.noData); return }
            // Silent push is an automatic trigger — throttled and coalesced.
            let outcome = await env.service.refresh(trigger: .automatic, now: Date())
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
#endif
