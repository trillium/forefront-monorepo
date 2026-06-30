import Foundation

public enum RefreshOutcome: Sendable {
    case unchanged
    case updated(CardStack)
    case offline(cached: CardStack?)
    case unauthorized
}

/// Orchestrates the launch / push refresh flow:
///   1. lastUpdated() — cheap probe
///   2. compare to cached version
///   3. if changed, fetchStack() — full deck
///   4. on any failure, fall back to cached stack
///
/// `refresh()` does NOT throw. Failure degrades to `.offline(cached:)`. This is
/// the doctrine of "the UI never blocks on the network" — every failure has a
/// representable outcome, never an exception that the UI has to catch.
public final class StackService: Sendable {
    private let api: APIClient
    private let cache: CacheStore
    private let tokenStore: KeychainStore

    public init(api: APIClient, cache: CacheStore, tokenStore: KeychainStore) {
        self.api = api
        self.cache = cache
        self.tokenStore = tokenStore
    }

    public func refresh() async -> RefreshOutcome {
        let cached = (try? cache.loadStack()) ?? nil
        do {
            let liveVersion = try await api.lastUpdated()
            if let cached, cached.version == liveVersion {
                // ISC-99: version equal => zero writes to disk.
                return .unchanged
            }
            let stack = try await api.fetchStack()
            // ISC-96: write cache before mutating consumers.
            try? cache.saveStack(stack)
            return .updated(stack)
        } catch ForefrontNetworkError.unauthorized {
            // Token revoked. Clear it; force re-onboarding.
            try? tokenStore.deleteToken()
            return .unauthorized
        } catch {
            return .offline(cached: cached)
        }
    }
}
