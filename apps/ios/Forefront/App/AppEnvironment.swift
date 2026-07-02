#if canImport(SwiftUI)
import Foundation
import SwiftUI
import Observation
import ForefrontModels
import ForefrontStorage
import ForefrontNetworking
import ForefrontQueue

/// Shared services injected into the SwiftUI environment. One instance per app
/// launch. Holds long-lived stores and the queue model.
@MainActor
@Observable
public final class AppEnvironment {
    public let keychain: KeychainStore
    public let appConfig: AppConfigStore
    public let cache: CacheStore
    public private(set) var rotator: EndpointRotator
    public private(set) var api: APIClient
    public private(set) var service: StackService
    public let queue: StackQueueModel
    public private(set) var bearerToken: String?
    public private(set) var isOffline: Bool = false
    /// F5: set when a refresh returns `.unauthorized`. Drives a visible re-scan
    /// prompt on the deck. The cached deck stays on disk and swipeable.
    public var needsReauth: Bool = false

    public init() {
        let keychain = KeychainStore()
        let appConfig = AppConfigStore()
        // CacheStore may fail to construct in pathological environments; the
        // app intentionally bails to a fatal at @main so the user sees the
        // crash rather than silently losing the cache layer.
        let cache: CacheStore
        do { cache = try CacheStore() } catch {
            preconditionFailure("CacheStore init failed: \(error)")
        }
        self.keychain = keychain
        self.appConfig = appConfig
        self.cache = cache

        let endpoints = appConfig.loadEndpoints()
        let safeEndpoints = endpoints.isEmpty
            ? [URL(string: "https://placeholder.invalid")!]
            : endpoints
        let rotator = EndpointRotator(endpoints: safeEndpoints)
        self.rotator = rotator

        let cachedToken = (try? keychain.loadToken()) ?? nil
        self.bearerToken = cachedToken
        let tokenStore = keychain
        let api = APIClient(
            rotator: rotator,
            tokenProvider: { [tokenStore] in (try? tokenStore.loadToken()) ?? nil }
        )
        self.api = api
        self.service = StackService(api: api, cache: cache, tokenStore: keychain)
        self.queue = StackQueueModel()
    }

    /// Reload the bearer token cache after onboarding writes a fresh value.
    public func refreshBearerTokenCache() {
        bearerToken = (try? keychain.loadToken()) ?? nil
    }

    /// F5: dismiss the 401 re-scan prompt after a successful re-onboard. Does not
    /// touch the on-disk cache — the deck stays intact (ISC-150).
    public func clearReauth() {
        needsReauth = false
    }

    /// Run the refresh path: poll last-updated, fetch if changed, fall through to
    /// cache on failure. `trigger` governs the 30s automatic throttle inside the
    /// service — `.userInitiated` (pull-to-refresh) bypasses it; `.automatic`
    /// (launch, foreground, push) is throttled.
    ///
    /// Merge-only invariant (ISC-151): every branch routes new stacks through
    /// `queue.adopt(...)`, which merges without replacing the sacred `active`
    /// card. No branch here assigns `active` directly.
    public func performRefresh(trigger: RefreshTrigger = .automatic) async {
        let outcome = await service.refresh(trigger: trigger)
        switch outcome {
        case .unchanged:
            isOffline = false
            if queue.active == nil, let cached = try? cache.loadStack() ?? nil {
                queue.adopt(cached)
            }
        case .updated(let stack):
            isOffline = false
            queue.adopt(stack)
        case .offline(let cached):
            isOffline = true
            if let cached, queue.active == nil { queue.adopt(cached) }
        case .unauthorized:
            // F5: surface a guided re-scan prompt instead of a silent offline
            // state. The cached deck on disk is preserved (no cache clear).
            isOffline = false
            needsReauth = true
        case .throttled:
            // Automatic refresh suppressed by the 30s guard. Nothing to do —
            // the current deck and offline state stand.
            break
        }
    }

    /// Rebuild networking after QR re-scan changes endpoints / token.
    public func rebuildNetworking() {
        let endpoints = appConfig.loadEndpoints()
        let safeEndpoints = endpoints.isEmpty
            ? [URL(string: "https://placeholder.invalid")!]
            : endpoints
        let rotator = EndpointRotator(endpoints: safeEndpoints)
        self.rotator = rotator
        let tokenStore = keychain
        let api = APIClient(
            rotator: rotator,
            tokenProvider: { [tokenStore] in (try? tokenStore.loadToken()) ?? nil }
        )
        self.api = api
        self.service = StackService(api: api, cache: cache, tokenStore: keychain)
        refreshBearerTokenCache()
    }
}

private struct AppEnvironmentKey: EnvironmentKey {
    @MainActor static var defaultValue: AppEnvironment { AppEnvironment.shared }
}

public extension AppEnvironment {
    @MainActor static let shared = AppEnvironment()
}

public extension EnvironmentValues {
    var forefrontEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
#endif
