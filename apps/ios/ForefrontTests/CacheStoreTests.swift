import XCTest
@testable import ForefrontModels
@testable import ForefrontStorage

final class CacheStoreTests: XCTestCase {

    func testRoundTrip() throws {
        let store = try CacheStore()
        try store.clear()
        let now = Date()
        let stack = CardStack(
            version: StackVersion(integer: 1),
            cards: [
                Card(id: "a", url: URL(string: "https://x/a")!, title: "A", priority: 0, createdAt: now, updatedAt: now)
            ]
        )
        try store.saveStack(stack)
        let loaded = try store.loadStack()
        XCTAssertEqual(loaded?.cards.count, 1)
        XCTAssertEqual(loaded?.cards.first?.id, "a")
    }

    func testExpiredCardEvictedOnLoad() throws {
        let store = try CacheStore()
        try store.clear()
        let oldUpdated = Date(timeIntervalSinceNow: -7200)  // 2h ago
        let stack = CardStack(
            version: StackVersion(integer: 1),
            cards: [
                Card(id: "expired", url: URL(string: "https://x/e")!, title: "E", priority: 0,
                     createdAt: oldUpdated, updatedAt: oldUpdated, ttl: 60),
                Card(id: "fresh", url: URL(string: "https://x/f")!, title: "F", priority: 1,
                     createdAt: Date(), updatedAt: Date())
            ]
        )
        try store.saveStack(stack)
        let loaded = try store.loadStack()!
        XCTAssertEqual(loaded.cards.count, 1)
        XCTAssertEqual(loaded.cards.first?.id, "fresh")
    }

    func testClearRemovesFile() throws {
        let store = try CacheStore()
        let stack = CardStack(version: StackVersion(integer: 1), cards: [])
        try store.saveStack(stack)
        try store.clear()
        let loaded = try store.loadStack()
        XCTAssertNil(loaded)
    }

    // MARK: - ISC-154: last-refreshed timestamp (offline staleness line)

    func testLastRefreshedNilBeforeAnySave() throws {
        // Isolated temp dir so no prior cache file bleeds in.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("forefront-test-\(UUID().uuidString)", isDirectory: true)
        let store = try CacheStore(directory: dir)
        XCTAssertNil(store.lastRefreshed(), "no cache file yet → no last-refreshed time")
    }

    func testLastRefreshedReflectsSaveTime() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("forefront-test-\(UUID().uuidString)", isDirectory: true)
        let store = try CacheStore(directory: dir)
        let before = Date()
        try store.saveStack(CardStack(version: StackVersion(integer: 1), cards: []))
        let after = Date()
        let refreshed = try XCTUnwrap(store.lastRefreshed(), "a save must produce a last-refreshed time")
        // mtime should fall within the save window (allow small fs granularity slack).
        XCTAssertGreaterThanOrEqual(refreshed.timeIntervalSince1970, before.timeIntervalSince1970 - 2)
        XCTAssertLessThanOrEqual(refreshed.timeIntervalSince1970, after.timeIntervalSince1970 + 2)
    }
}
