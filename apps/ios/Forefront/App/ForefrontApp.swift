#if canImport(SwiftUI)
import SwiftUI

/// @main entry point. WindowGroup hosts AppRoot.
@main
public struct ForefrontApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(ForefrontAppDelegate.self) private var appDelegate
    #endif

    public init() {}

    public var body: some Scene {
        WindowGroup {
            AppRoot()
                .environment(\.forefrontEnvironment, AppEnvironment.shared)
                .environment(\.forefrontChatEnvironment, ChatEnvironment.shared)
        }
    }
}
#endif
