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
}
