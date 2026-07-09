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

    func testRestartReplaysExhaustedDeckFromTop() {
        let model = StackQueueModel(
            active: makeCard("a"),
            queue: [makeCard("b"), makeCard("c")]
        )
        model.advance() // a -> b
        model.advance() // b -> c
        model.advance() // c -> nil (exhausted)
        XCTAssertNil(model.active)
        XCTAssertTrue(model.queue.isEmpty)
        XCTAssertEqual(model.history.count, 3)

        model.restart()

        XCTAssertEqual(model.active?.id, "a")
        XCTAssertEqual(model.queue.map(\.id), ["b", "c"])
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertEqual(model.deckPosition, 1)
        XCTAssertEqual(model.deckTotal, 3)
    }

    func testRestartMidDeckRewindsToTop() {
        let model = StackQueueModel(
            active: makeCard("a"),
            queue: [makeCard("b"), makeCard("c")]
        )
        model.advance() // a -> b (a in history, c still queued)

        model.restart()

        // Order preserved: swiped (a), then active (b), then queued (c).
        XCTAssertEqual(model.active?.id, "a")
        XCTAssertEqual(model.queue.map(\.id), ["b", "c"])
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertEqual(model.deckPosition, 1)
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

    // MARK: - ISC-152: deck position indicator ("N of M")

    func testDeckPositionAndTotalOnFreshLoad() {
        let model = StackQueueModel()
        model.merge(stack: CardStack(version: StackVersion(integer: 1), cards: [
            makeCard("a", priority: 0),
            makeCard("b", priority: 1),
            makeCard("c", priority: 2)
        ]))
        // First card of a 3-card deck: "1 of 3".
        XCTAssertEqual(model.deckPosition, 1)
        XCTAssertEqual(model.deckTotal, 3)
        XCTAssertEqual(model.seenThisGeneration, 0)
    }

    func testDeckPositionAdvancesWhileTotalHolds() {
        let model = StackQueueModel()
        model.merge(stack: CardStack(version: StackVersion(integer: 1), cards: [
            makeCard("a", priority: 0),
            makeCard("b", priority: 1),
            makeCard("c", priority: 2)
        ]))
        model.advance()            // now on card b
        XCTAssertEqual(model.deckPosition, 2, "position ticks to 2 after one swipe")
        XCTAssertEqual(model.deckTotal, 3, "total holds at 3 across advances within a generation")
        model.advance()            // now on card c
        XCTAssertEqual(model.deckPosition, 3)
        XCTAssertEqual(model.deckTotal, 3)
    }

    func testDeckPositionZeroWhenExhausted() {
        let model = StackQueueModel(active: makeCard("only"), queue: [])
        model.advance()            // deck exhausted → active nil
        XCTAssertNil(model.active)
        XCTAssertEqual(model.deckPosition, 0, "no active card → position 0 (indicator hides)")
    }

    func testNewVersionResetsGeneration() {
        let model = StackQueueModel()
        model.merge(stack: CardStack(version: StackVersion(integer: 1), cards: [
            makeCard("a"), makeCard("b"), makeCard("c")
        ]))
        model.advance()            // seen = 1
        model.advance()            // seen = 2
        XCTAssertEqual(model.seenThisGeneration, 2)
        // A NEW version arrives — fresh generation, counter resets.
        model.adopt(CardStack(version: StackVersion(integer: 2), cards: [
            makeCard("c", priority: 0),   // active carried forward
            makeCard("d", priority: 1),
            makeCard("e", priority: 2)
        ]))
        XCTAssertEqual(model.seenThisGeneration, 0, "a new version starts a fresh generation")
        XCTAssertEqual(model.active?.id, "c", "active card is still sacred across the version bump")
        XCTAssertEqual(model.deckPosition, 1, "position restarts at 1 for the new deck")
        XCTAssertEqual(model.deckTotal, 3)
    }

    func testSameVersionRemergeDoesNotRewindGeneration() {
        let model = StackQueueModel()
        let v1 = StackVersion(integer: 1)
        model.merge(stack: CardStack(version: v1, cards: [
            makeCard("a"), makeCard("b"), makeCard("c")
        ]))
        model.advance()            // seen = 1, active = b
        // Same version re-merges (idempotent refresh) must not rewind the counter.
        model.merge(stack: CardStack(version: v1, cards: [
            makeCard("a"), makeCard("b"), makeCard("c")
        ]))
        XCTAssertEqual(model.seenThisGeneration, 1, "same-version re-merge preserves the seen-counter")
        XCTAssertEqual(model.active?.id, "b", "active preserved across same-version re-merge")
    }

    // MARK: - ISC-156: arrival tick — new cards grow the deck without touching active

    func testMergeGrowsDeckCountWhileActivePreserved() {
        let model = StackQueueModel(active: makeCard("held"), queue: [makeCard("q1")])
        // Before: active + 1 queued = total 2 remaining.
        let totalBefore = model.deckTotal
        let activeBefore = model.active?.id
        XCTAssertEqual(model.remainingCount, 2)

        // New cards arrive via merge (same version, e.g. a queue-growth update).
        model.merge(stack: CardStack(version: model.version ?? StackVersion(integer: 1), cards: [
            makeCard("held", priority: 5),   // active reappears — must be filtered out
            makeCard("q1", priority: 1),
            makeCard("new1", priority: 2),
            makeCard("new2", priority: 3)
        ]))

        XCTAssertEqual(model.active?.id, activeBefore, "arrival tick must not touch active (sacred invariant)")
        XCTAssertGreaterThan(model.deckTotal, totalBefore, "deck total ticks up when new cards arrive")
        XCTAssertEqual(model.queue.map(\.id), ["q1", "new1", "new2"], "queue grows with the arriving cards, active excluded")
        XCTAssertEqual(model.remainingCount, 4)
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

    // MARK: - F6: Undo swipe (ISC-158..161)

    func testUndoRestoresPreviousActive() {
        let model = StackQueueModel(
            active: makeCard("a"),
            queue: [makeCard("b"), makeCard("c")]
        )
        model.advance()   // a → history, b becomes active
        XCTAssertEqual(model.active?.id, "b")
        XCTAssertEqual(model.history.map(\.id), ["a"])
        model.undo()
        XCTAssertEqual(model.active?.id, "a", "undo must restore the previous active")
        XCTAssertEqual(model.queue.first?.id, "b", "displaced active returns to queue front")
        XCTAssertEqual(model.history.count, 0)
        XCTAssertEqual(model.seenThisGeneration, 0)
    }

    func testUndoDeduplicatesQueueById() {
        // If the card being displaced is already in the queue (shouldn't happen normally
        // but defensive: dedup ensures no duplicate by id after undo).
        let model = StackQueueModel(
            active: makeCard("a"),
            queue: [makeCard("b"), makeCard("c")]
        )
        model.advance()  // a → history, b is active
        // Manually pollute queue with b (simulating an edge case)
        model.advance()  // b → history, c is active
        model.undo()     // b should come back to front, c returns; c must not duplicate
        XCTAssertEqual(model.queue.filter { $0.id == "c" }.count, 1, "undo must not duplicate the displaced card in queue")
    }

    func testVersionChangesClearHistory() {
        let model = StackQueueModel()
        model.merge(stack: CardStack(version: StackVersion(integer: 1), cards: [
            makeCard("a"), makeCard("b")
        ]))
        model.advance()
        XCTAssertEqual(model.history.count, 1)
        // New version arrives — history must be wiped (ISC-160)
        model.adopt(CardStack(version: StackVersion(integer: 2), cards: [
            makeCard("b"), makeCard("c")
        ]))
        XCTAssertEqual(model.history.count, 0, "undo history must be cleared on version change")
    }
}
