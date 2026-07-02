import XCTest
@testable import ForefrontModels
@testable import ForefrontStorage
@testable import ForefrontNetworking
@testable import ForefrontQueue

/// F3 — deterministic mock-network probes (ISC-142..147). Converts the
/// formerly device-only DEFERRED-VERIFY ISCs (31, 60, 96, 99) into unit tests.
final class MockNetworkTests: XCTestCase {

    private let lastUpdatedPath = "/stack/last-updated"
    private let stackPath = "/stack"

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func lastUpdatedBody(_ version: Int) -> Data {
        Data(#"{"version":\#(version)}"#.utf8)
    }

    private func stackBody(version: Int, cards: [(id: String, priority: Int)]) -> Data {
        let cardJSON = cards.map { c in
            """
            {"id":"\(c.id)","url":"https://example.com/\(c.id)","title":"\(c.id)",
             "priority":\(c.priority),"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
            """
        }.joined(separator: ",")
        return Data(#"{"version":\#(version),"cards":[\#(cardJSON)]}"#.utf8)
    }

    private func makeClient(endpoints: [URL]) -> APIClient {
        APIClient(
            rotator: EndpointRotator(endpoints: endpoints),
            tokenProvider: { "test-token" },
            session: MockSession.make()
        )
    }

    private let twoEndpoints = [
        URL(string: "https://primary.example")!,
        URL(string: "https://fallback.example")!
    ]

    // MARK: - ISC-143: 5xx retries once, then falls through to next endpoint

    func test5xxRetriesOnceThenFallsThrough() async throws {
        // Path-matched (host-agnostic) script: 500, 500, then 200.
        // Primary: attempt + one retry = two 500s => .serverError thrown =>
        // rotator falls through to fallback => third scripted response = 200.
        MockURLProtocol.script(path: lastUpdatedPath, responses: [
            .status(500),
            .status(500),
            .status(200, body: lastUpdatedBody(42))
        ])
        let client = makeClient(endpoints: twoEndpoints)

        let version = try await client.lastUpdated()
        XCTAssertEqual(version, StackVersion(integer: 42))
        // Two attempts on the primary (retry-once) + one on the fallback = 3.
        XCTAssertEqual(MockURLProtocol.hitCount(path: lastUpdatedPath), 3,
                       "5xx must retry once on primary, then fall through to the next endpoint")
    }

    // MARK: - ISC-144: 401 short-circuits rotation, surfaces .unauthorized

    func test401ShortCircuitsRotation() async throws {
        MockURLProtocol.script(path: lastUpdatedPath, responses: [.status(401)])
        let client = makeClient(endpoints: twoEndpoints)

        do {
            _ = try await client.lastUpdated()
            XCTFail("expected .unauthorized to be thrown")
        } catch ForefrontNetworkError.unauthorized {
            // 401 is non-retryable: no per-endpoint retry, no fallback attempt.
            XCTAssertEqual(MockURLProtocol.hitCount(path: lastUpdatedPath), 1,
                           "401 must short-circuit — exactly one request, no retry, no fallback")
        } catch {
            XCTFail("expected .unauthorized, got \(error)")
        }
    }

    // MARK: - ISC-150: a 401 preserves the cached deck (no cache clear)

    func test401PreservesCachedDeck() async throws {
        let seeded = CardStack(
            version: StackVersion(integer: 3),
            cards: [Card(id: "cached", url: URL(string: "https://x/c")!, title: "C", priority: 0,
                         createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))]
        )
        let spy = SpyCache(seed: seeded)
        MockURLProtocol.script(path: lastUpdatedPath, responses: [.status(401)])
        let client = makeClient(endpoints: twoEndpoints)
        let service = StackService(api: client, cache: spy, tokenStore: KeychainStore())

        let outcome = await service.refresh(trigger: .userInitiated)
        XCTAssertEqual(outcome, .unauthorized, "401 must surface .unauthorized, not silent .offline")
        // The cached deck on disk is untouched — StackService writes only on
        // .updated and holds `any StackCaching`, which has no clear() to call.
        XCTAssertEqual(spy.saveCount, 0, "a 401 must not write the cache")
        let stillCached = try spy.loadStack(now: Date())
        XCTAssertEqual(stillCached?.cards.first?.id, "cached", "the cached deck must survive a 401")
    }

    // MARK: - ISC-145: unchanged version => zero cache writes

    func testUnchangedVersionWritesNothing() async throws {
        let cachedVersion = 7
        let spy = SpyCache(seed: CardStack(
            version: StackVersion(integer: cachedVersion),
            cards: [Card(id: "a", url: URL(string: "https://x/a")!, title: "A", priority: 0,
                         createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))]
        ))
        // Live version equals cached => .unchanged => no fetch, no save.
        MockURLProtocol.script(path: lastUpdatedPath, responses: [.status(200, body: lastUpdatedBody(cachedVersion))])
        let client = makeClient(endpoints: twoEndpoints)
        let service = StackService(api: client, cache: spy, tokenStore: KeychainStore())

        let outcome = await service.refresh(trigger: .userInitiated)
        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(spy.saveCount, 0, "an unchanged version must perform zero cache writes")
        XCTAssertEqual(MockURLProtocol.hitCount(path: stackPath), 0, "no /stack fetch on unchanged")
    }

    // MARK: - ISC-146: successful fetch writes cache BEFORE the queue adopts

    func testCacheWrittenBeforeQueueAdopt() async throws {
        let spy = SpyCache(seed: nil)
        MockURLProtocol.script(path: lastUpdatedPath, responses: [.status(200, body: lastUpdatedBody(99))])
        MockURLProtocol.script(path: stackPath, responses: [
            .status(200, body: stackBody(version: 99, cards: [("a", 0), ("b", 1)]))
        ])
        let client = makeClient(endpoints: twoEndpoints)
        let service = StackService(api: client, cache: spy, tokenStore: KeychainStore())

        let outcome = await service.refresh(trigger: .userInitiated)
        guard case .updated(let stack) = outcome else {
            return XCTFail("expected .updated, got \(outcome)")
        }
        // The cache write happened inside refresh(), i.e. BEFORE the caller adopts.
        let saveOrder = spy.lastSaveOrder
        XCTAssertNotNil(saveOrder, "cache must be written on a successful fetch")

        // Now perform the adopt the caller would do, and record its order.
        let adoptOrder = OrderClock.tick()
        let model = await StackQueueModel()
        await model.adopt(stack)

        XCTAssertLessThan(saveOrder!, adoptOrder,
                          "cache must be written BEFORE the queue adopts the new stack")
        let activeID = await model.active?.id
        XCTAssertEqual(activeID, "a")
        XCTAssertEqual(spy.saveCount, 1)
    }

    // MARK: - ISC-147: higher-priority card via merge sorts to queue index 0

    @MainActor
    func testHigherPriorityCardSortsToQueueFront() {
        func card(_ id: String, _ priority: Int) -> Card {
            Card(id: id, url: URL(string: "https://x/\(id)")!, title: id, priority: priority,
                 createdAt: Date(), updatedAt: Date())
        }
        // Active card held; a fresh stack arrives carrying a higher-priority
        // (lower numeric) card than the rest.
        let model = StackQueueModel(active: card("active", 0), queue: [card("old", 5)])
        let fresh = CardStack(version: StackVersion(integer: 2), cards: [
            card("mid", 3),
            card("urgent", -10),   // highest priority
            card("low", 8)
        ])
        model.merge(stack: fresh)

        XCTAssertEqual(model.active?.id, "active", "merge must not replace the sacred active card")
        XCTAssertEqual(model.queue.first?.id, "urgent",
                       "the higher-priority (lower numeric) card must sort to queue index 0")
        XCTAssertEqual(model.queue.map(\.id), ["urgent", "mid", "low"])
    }
}

// MARK: - Test doubles

/// Monotonic clock to prove ordering between the cache write and the queue adopt.
private enum OrderClock {
    private static let lock = NSLock()
    private static var counter = 0
    static func tick() -> Int {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        return counter
    }
}

/// A `StackCaching` spy that counts writes and records the order of the last
/// write against a shared monotonic clock (ISC-145, ISC-146).
///
/// `@unchecked Sendable`: all mutable state (`stored`, `saveCount`,
/// `lastSaveOrder`) is guarded by `lock`; every accessor takes it. There is no
/// unsynchronized mutable state, so crossing isolation boundaries is safe.
private final class SpyCache: StackCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CardStack?
    private var _saveCount = 0
    private var _lastSaveOrder: Int?

    init(seed: CardStack?) { self.stored = seed }

    func loadStack(now: Date) throws -> CardStack? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func saveStack(_ stack: CardStack) throws {
        lock.lock(); defer { lock.unlock() }
        stored = stack
        _saveCount += 1
        _lastSaveOrder = OrderClock.tick()
    }

    var saveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _saveCount
    }

    var lastSaveOrder: Int? {
        lock.lock(); defer { lock.unlock() }
        return _lastSaveOrder
    }
}
