import Foundation
import ForefrontModels
import ForefrontStorage

public enum RefreshOutcome: Sendable, Equatable {
    case unchanged
    case updated(CardStack)
    case offline(cached: CardStack?)
    case unauthorized
    /// An automatic (foreground / push) refresh was suppressed because the
    /// minimum interval since the last attempt had not elapsed. No network call
    /// was made and no state changed. User-initiated refreshes never throttle.
    case throttled
}

/// Why a refresh was requested. Governs throttling only — both triggers still
/// coalesce into a single in-flight flight.
public enum RefreshTrigger: Sendable {
    /// System-driven: launch task, foreground `scenePhase`, silent push. Subject
    /// to the ≥`minAutomaticInterval` throttle.
    case automatic
    /// User-driven: pull-to-refresh, explicit button. Bypasses the throttle
    /// (but still coalesces with any in-flight flight).
    case userInitiated
}

/// The network surface `StackService` orchestrates. A protocol seam so tests can
/// inject a counting fake (F2) or a `MockURLProtocol`-backed client (F3) without
/// touching real endpoints. `APIClient` is the production conformer.
public protocol StackNetworking: Sendable {
    func lastUpdated() async throws -> StackVersion
    func fetchStack() async throws -> CardStack
}

extension APIClient: StackNetworking {}

/// Protocol seam so AppEnvironment can substitute a DemoStackService for App Review
/// without touching real endpoints. StackService is the production conformer. (ISC-162)
public protocol StackRefreshing: Sendable {
    func refresh(trigger: RefreshTrigger, now: Date) async -> RefreshOutcome
}

extension StackService: StackRefreshing {}

/// Orchestrates the launch / push / pull refresh flow:
///   1. lastUpdated() — cheap probe
///   2. compare to cached version
///   3. if changed, fetchStack() — full deck
///   4. on any failure, fall back to cached stack
///
/// `refresh(trigger:)` does NOT throw. Failure degrades to `.offline(cached:)` —
/// the doctrine of "the UI never blocks on the network": every failure has a
/// representable outcome, never an exception the UI has to catch.
///
/// Single-flight (ISC-138): concurrent callers coalesce onto ONE in-flight
/// `Task`. Because `StackVersion` is equality-only by doctrine (last-write-wins,
/// no ordering), racing flights cannot be version-guarded at `adopt()` — so the
/// fix is loop structure: at most one flight runs at a time and every coalesced
/// caller receives that flight's single outcome. This guarantees at most one
/// adopt-worthy `.updated` per coalesced flight (ISC-141).
public actor StackService {
    private let api: any StackNetworking
    private let cache: any StackCaching
    private let tokenStore: KeychainStore

    /// Minimum wall-clock interval between two *automatic* refresh attempts.
    public static let minAutomaticInterval: TimeInterval = 30

    /// The single in-flight refresh, if one is running. Concurrent callers await
    /// this rather than starting their own.
    private var inFlight: Task<RefreshOutcome, Never>?
    /// Timestamp of the last attempt that actually reached the network (i.e. was
    /// not throttled and not merely coalesced). Drives the automatic throttle.
    private var lastAttemptAt: Date?

    public init(api: any StackNetworking, cache: any StackCaching, tokenStore: KeychainStore) {
        self.api = api
        self.cache = cache
        self.tokenStore = tokenStore
    }

    /// Coalescing, throttled refresh entry point.
    ///
    /// - If a flight is already running, join it (all callers share its outcome).
    /// - Else if `trigger == .automatic` and the last attempt was < 30s ago,
    ///   return `.throttled` without touching the network.
    /// - Else start a new flight and join it.
    public func refresh(
        trigger: RefreshTrigger = .automatic,
        now: Date = Date()
    ) async -> RefreshOutcome {
        // Coalesce: an in-flight flight serves every concurrent caller.
        if let inFlight {
            return await inFlight.value
        }

        // Throttle automatic triggers. User-initiated bypasses the guard.
        if trigger == .automatic, let last = lastAttemptAt,
           now.timeIntervalSince(last) < Self.minAutomaticInterval {
            return .throttled
        }

        lastAttemptAt = now
        let task = Task<RefreshOutcome, Never> { [weak self] in
            guard let self else { return .offline(cached: nil) }
            return await self.performRefresh()
        }
        inFlight = task
        let outcome = await task.value
        // Clear the flight slot so the next request starts fresh. Guard against a
        // newer flight having replaced it (defensive; the actor serializes this).
        if inFlight == task {
            inFlight = nil
        }
        return outcome
    }

    /// The actual network sequence. Runs inside exactly one coalesced flight.
    private func performRefresh() async -> RefreshOutcome {
        let cached = (try? cache.loadStack()) ?? nil
        do {
            let liveVersion = try await api.lastUpdated()
            if let cached, cached.version == liveVersion {
                // ISC-99: version equal => zero writes to disk.
                return .unchanged
            }
            let stack = try await api.fetchStack()
            // ISC-96: write cache BEFORE the queue adopts the new stack.
            try? cache.saveStack(stack)
            return .updated(stack)
        } catch ForefrontNetworkError.unauthorized {
            // Token revoked. Clear it; the UI routes into re-onboarding (F5).
            try? tokenStore.deleteToken()
            return .unauthorized
        } catch {
            return .offline(cached: cached)
        }
    }
}
