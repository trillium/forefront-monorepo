import XCTest
@testable import ForefrontModels
@testable import ForefrontQueue

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

    // MARK: - ISC-151: no foreground refresh path can replace `active`

    /// `adopt(_:)` is the single mutation the foreground refresh path
    /// (`AppEnvironment.performRefresh(trigger:.automatic)`) calls on a `.updated`
    /// outcome. This proves that call — for every shape of incoming stack —
    /// preserves the held `active` card. Merge semantics only.
    func testForegroundAdoptNeverReplacesActive() {
        // (1) Fresh stack that DOES contain the active card.
        let model1 = StackQueueModel(active: makeCard("held"), queue: [makeCard("q1")])
        model1.adopt(CardStack(version: StackVersion(integer: 10), cards: [
            makeCard("held", priority: 9),
            makeCard("new", priority: 0)
        ]))
        XCTAssertEqual(model1.active?.id, "held", "adopt must not replace the active card even if it reappears in the stack")
        XCTAssertFalse(model1.queue.contains { $0.id == "held" }, "active card must not be duplicated into the queue")

        // (2) Fresh stack that does NOT contain the active card.
        let model2 = StackQueueModel(active: makeCard("held"), queue: [makeCard("q1")])
        model2.adopt(CardStack(version: StackVersion(integer: 11), cards: [
            makeCard("x", priority: 0),
            makeCard("y", priority: 1)
        ]))
        XCTAssertEqual(model2.active?.id, "held", "adopt of an unrelated stack must not replace active")
        XCTAssertEqual(model2.queue.map(\.id), ["x", "y"])

        // (3) A flush (empty cards) — active still stands until the user swipes.
        let model3 = StackQueueModel(active: makeCard("held"), queue: [makeCard("q1")])
        model3.adopt(CardStack(version: StackVersion(integer: 12), cards: []))
        XCTAssertEqual(model3.active?.id, "held", "a flush must not replace active")
        XCTAssertEqual(model3.queue.count, 0)
    }
}
