import XCTest
@testable import ForefrontModels
@testable import ForefrontStorage
@testable import ForefrontNetworking

/// F2 — single-flight coalescing + throttle (ISC-138..141).
final class StackServiceTests: XCTestCase {

    // MARK: - Counting fake network

    /// A `StackNetworking` fake that counts probe/fetch calls and lets the test
    /// hold a flight open long enough for a second caller to coalesce.
    private actor CountingNetwork: StackNetworking {
        private(set) var probeCount = 0
        private(set) var fetchCount = 0
        private let version: StackVersion
        private let stack: CardStack
        /// Seconds each `lastUpdated()` blocks, to widen the coalescing window.
        private let probeDelay: UInt64

        init(version: StackVersion, stack: CardStack, probeDelayNanos: UInt64 = 50_000_000) {
            self.version = version
            self.stack = stack
            self.probeDelay = probeDelayNanos
        }

        func lastUpdated() async throws -> StackVersion {
            probeCount += 1
            if probeDelay > 0 { try? await Task.sleep(nanoseconds: probeDelay) }
            return version
        }

        func fetchStack() async throws -> CardStack {
            fetchCount += 1
            return stack
        }

        var counts: (probes: Int, fetches: Int) { (probeCount, fetchCount) }
    }

    // MARK: - Helpers

    private func makeStack(versionInt: Int) -> CardStack {
        CardStack(
            version: StackVersion(integer: versionInt),
            cards: [
                Card(id: "a", url: URL(string: "https://x/a")!, title: "A", priority: 0,
                     createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
            ]
        )
    }

    /// A CacheStore whose backing file is empty at the start of each test, so the
    /// service always sees "no cached version" and proceeds to fetch.
    private func makeEmptyCache() throws -> CacheStore {
        let store = try CacheStore()
        try store.clear()
        return store
    }

    // MARK: - ISC-138 / ISC-139: two concurrent refreshes -> one probe

    func testConcurrentRefreshCoalescesToSingleProbe() async throws {
        let stack = makeStack(versionInt: 7)
        let net = CountingNetwork(version: stack.version, stack: stack)
        let cache = try makeEmptyCache()
        let service = StackService(api: net, cache: cache, tokenStore: KeychainStore())

        // Fire two refreshes concurrently. The first opens a flight (and blocks
        // in the delayed probe); the second must coalesce onto it.
        async let first = service.refresh(trigger: .userInitiated)
        async let second = service.refresh(trigger: .userInitiated)
        let outcomes = await [first, second]

        let counts = await net.counts
        XCTAssertEqual(counts.probes, 1, "two concurrent refreshes must issue exactly one /stack/last-updated probe")
        XCTAssertEqual(counts.fetches, 1, "and exactly one /stack fetch")

        // Both callers receive the SAME single flight's outcome.
        XCTAssertEqual(outcomes[0], outcomes[1])
        try cache.clear()
    }

    // MARK: - ISC-141: one coalesced flight -> at most one adopt-worthy outcome

    func testCoalescedFlightProducesAtMostOneUpdatedOutcome() async throws {
        let stack = makeStack(versionInt: 9)
        let net = CountingNetwork(version: stack.version, stack: stack)
        let cache = try makeEmptyCache()
        let service = StackService(api: net, cache: cache, tokenStore: KeychainStore())

        // Three concurrent callers on one flight.
        async let a = service.refresh(trigger: .userInitiated)
        async let b = service.refresh(trigger: .userInitiated)
        async let c = service.refresh(trigger: .userInitiated)
        let outcomes = await [a, b, c]

        // Exactly one flight fetched, so exactly one *distinct* fetch happened —
        // there is at most one adopt-worthy `.updated` per coalesced flight.
        let fetches = await net.counts.fetches
        XCTAssertEqual(fetches, 1, "a coalesced flight fetches once => at most one adopt-worthy stack")

        // Every coalesced caller sees the same `.updated` value; adopting it N
        // times is idempotent at the version cursor, but the *flight* produced
        // exactly one stack.
        for outcome in outcomes {
            guard case .updated(let s) = outcome else {
                return XCTFail("expected .updated, got \(outcome)")
            }
            XCTAssertEqual(s.version, stack.version)
        }
        try cache.clear()
    }

    // MARK: - ISC-140: automatic throttle vs user-initiated bypass

    func testAutomaticTriggerThrottlesWithin30s() async throws {
        let stack = makeStack(versionInt: 3)
        // No probe delay — each flight completes before the next call.
        let net = CountingNetwork(version: stack.version, stack: stack, probeDelayNanos: 0)
        let cache = try makeEmptyCache()
        let service = StackService(api: net, cache: cache, tokenStore: KeychainStore())

        let base = Date(timeIntervalSince1970: 1_000_000)
        // First automatic refresh reaches the network.
        let first = await service.refresh(trigger: .automatic, now: base)
        XCTAssertEqual(first, .updated(stack))

        // Second automatic refresh 10s later is throttled (<30s).
        let throttled = await service.refresh(trigger: .automatic, now: base.addingTimeInterval(10))
        XCTAssertEqual(throttled, .throttled)

        // Probe count did not advance on the throttled call.
        let probesAfterThrottle = await net.counts.probes
        XCTAssertEqual(probesAfterThrottle, 1, "throttled automatic refresh must not touch the network")

        try cache.clear()
    }

    func testUserInitiatedBypassesThrottle() async throws {
        let stack = makeStack(versionInt: 4)
        let net = CountingNetwork(version: stack.version, stack: stack, probeDelayNanos: 0)
        let cache = try makeEmptyCache()
        let service = StackService(api: net, cache: cache, tokenStore: KeychainStore())

        let base = Date(timeIntervalSince1970: 2_000_000)
        _ = await service.refresh(trigger: .automatic, now: base)
        // A user-initiated refresh 1s later bypasses the throttle and hits the
        // net. The first refresh already cached this version, so the correct
        // outcome is `.unchanged` — the *proof of bypass* is the probe count,
        // not the outcome (a throttled call would leave the probe count at 1).
        let userOutcome = await service.refresh(trigger: .userInitiated, now: base.addingTimeInterval(1))
        XCTAssertEqual(userOutcome, .unchanged)
        XCTAssertNotEqual(userOutcome, .throttled, "user-initiated refresh must never throttle")

        let probes = await net.counts.probes
        XCTAssertEqual(probes, 2, "user-initiated refresh must bypass the 30s throttle and probe again")

        try cache.clear()
    }

    // MARK: - ISC-140: automatic refresh allowed after the interval elapses

    func testAutomaticAllowedAfterInterval() async throws {
        let stack = makeStack(versionInt: 5)
        let net = CountingNetwork(version: stack.version, stack: stack, probeDelayNanos: 0)
        let cache = try makeEmptyCache()
        let service = StackService(api: net, cache: cache, tokenStore: KeychainStore())

        let base = Date(timeIntervalSince1970: 3_000_000)
        _ = await service.refresh(trigger: .automatic, now: base)
        let later = await service.refresh(
            trigger: .automatic,
            now: base.addingTimeInterval(StackService.minAutomaticInterval + 1)
        )
        // After >=30s the automatic refresh is allowed through. It reaches the
        // network (probe count advances) and — because the first refresh cached
        // this version — correctly reports `.unchanged` rather than throttling.
        XCTAssertEqual(later, .unchanged)
        XCTAssertNotEqual(later, .throttled, "automatic refresh must NOT throttle once the interval elapses")

        let probes = await net.counts.probes
        XCTAssertEqual(probes, 2, "automatic refresh must be allowed once >=30s elapses")

        try cache.clear()
    }
}
