#if canImport(SwiftUI)
import XCTest
@testable import ForefrontModels
// Note: StackQueueModel lives in the Xcode iOS app target (it imports SwiftUI's
// Observation framework). These tests are compiled by Xcode under the app target's
// test target rather than `swift test`. The file is retained here for that path.

@MainActor
final class StackQueueModelTests: XCTestCase {

    private func makeCard(_ id: String, priority: Int = 0) -> Card {
        Card(
            id: id,
            url: URL(string: "https://example.com/\(id)")!,
            title: id,
            priority: priority,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func testAdvancePopsQueue() {
        let model = StackQueueModel(
            active: makeCard("a"),
            queue: [makeCard("b"), makeCard("c")]
        )
        XCTAssertEqual(model.active?.id, "a")
        model.advance()
        XCTAssertEqual(model.active?.id, "b")
        XCTAssertEqual(model.queue.count, 1)
        model.advance()
        XCTAssertEqual(model.active?.id, "c")
        XCTAssertEqual(model.queue.count, 0)
        model.advance()
        XCTAssertNil(model.active)
    }

    func testMergePreservesActive() {
        let model = StackQueueModel(active: makeCard("a"), queue: [makeCard("b")])
        let fresh = CardStack(version: StackVersion(integer: 2), cards: [
            makeCard("x", priority: 0),
            makeCard("a", priority: 5),  // active is also in the fresh stack
            makeCard("y", priority: 1)
        ])
        model.merge(stack: fresh)
        XCTAssertEqual(model.active?.id, "a", "active card must be preserved across merge")
        XCTAssertEqual(model.queue.map(\.id), ["x", "y"])
    }

    func testFlushLeavesActive() {
        let model = StackQueueModel(active: makeCard("a"), queue: [makeCard("b")])
        model.flush(replacement: CardStack(version: StackVersion(integer: 3), cards: []))
        XCTAssertEqual(model.active?.id, "a")
        XCTAssertEqual(model.queue.count, 0)
    }

    func testPrependUrgent() {
        let model = StackQueueModel(active: makeCard("a"), queue: [makeCard("b"), makeCard("c")])
        model.prependUrgent(makeCard("urgent", priority: -1))
        XCTAssertEqual(model.active?.id, "a")
        XCTAssertEqual(model.queue.first?.id, "urgent")
    }

    func testPrependUrgentDeduplicates() {
        let model = StackQueueModel(active: makeCard("a"), queue: [makeCard("b"), makeCard("c")])
        model.prependUrgent(makeCard("b"))
        XCTAssertEqual(model.queue.filter { $0.id == "b" }.count, 1)
        XCTAssertEqual(model.queue.first?.id, "b")
    }
}
#endif
