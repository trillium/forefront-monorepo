import Foundation
import Observation
import ForefrontModels

/// The queue model is the heart of the §5 behavior rules.
///
/// Invariant: **user gestures own active; system events own the queue.** (ISC-161)
///   - `active` is never replaced by network events — only `advance()` and `undo()` touch it.
///   - `merge(stack:)` / `flush(replacement:)` / `adopt(_:)` replace the *queue* only.
///   - `prependUrgent(_:)` inserts a card at queue index 0; `active` unchanged.
///   - All mutations happen on the main actor; UI never sees a partial mutation.
@MainActor
@Observable
public final class StackQueueModel {
    public private(set) var active: Card?
    public private(set) var queue: [Card]
    public private(set) var version: StackVersion?

    /// ISC-158: cards the user has swiped past this generation, in swipe order.
    /// `advance()` pushes the card it is about to leave; `undo()` pops it back to
    /// `active`. Cleared on every version change (ISC-160) so undo can never
    /// resurrect a card from a stale deck generation.
    public private(set) var history: [Card] = []

    /// ISC-152: cards the user has already swiped past in the current deck
    /// generation. A "generation" begins on first load and on any `adopt()` /
    /// `merge()` / `flush()` that carries a *new* `version`. Reset to 0 there so
    /// the position indicator reads "1 of M" against a fresh deck.
    ///
    /// Not a UI concern on its own — kept here (pure logic, no SwiftUI import) so
    /// it is unit-testable and so the count is @Observable-driven: any mutation
    /// re-renders the indicator without the view polling (ISC-156).
    public private(set) var seenThisGeneration: Int = 0

    public init(active: Card? = nil, queue: [Card] = [], version: StackVersion? = nil) {
        self.active = active
        self.queue = queue
        self.version = version
    }

    /// The number of cards remaining to be viewed in the current generation:
    /// the active card (if any) plus everything still queued behind it.
    public var remainingCount: Int {
        (active == nil ? 0 : 1) + queue.count
    }

    /// ISC-152 — "N of M": the 1-based position of the active card within the
    /// current deck generation. `seenThisGeneration` cards are behind us, so the
    /// active card is the (seen + 1)th. Zero when there is no active card
    /// (exhausted deck) — callers should hide the indicator in that case.
    public var deckPosition: Int {
        active == nil ? 0 : seenThisGeneration + 1
    }

    /// ISC-152 — "N of M": the total deck size for the current generation:
    /// everything seen so far plus everything remaining. Grows when new cards
    /// arrive via `merge()` (ISC-156) and never shrinks below what the user has
    /// already seen.
    public var deckTotal: Int {
        seenThisGeneration + remainingCount
    }

    /// Pop next card off the queue and promote it to active.
    /// If the queue is empty, `active` becomes nil only after the swipe (§5 rule 6).
    public func advance() {
        // ISC-152: a swipe consumes the current active card only if there is one.
        // Count it as seen so the position indicator advances 1 → 2 → …
        // ISC-158: push the about-to-be-left card to history BEFORE the counter
        // increments, so `undo()` can restore it and rewind `seenThisGeneration`.
        if let current = active {
            history.append(current)
            seenThisGeneration += 1
        }
        if queue.isEmpty {
            active = nil
            return
        }
        active = queue.removeFirst()
    }

    /// ISC-159: reverse the last `advance()`. Pops the most-recently-swiped card
    /// off `history`, returns the current `active` to the front of the queue
    /// (deduplicated by id), then restores the popped card as `active`. Rewinds
    /// `seenThisGeneration` so the position indicator ticks back down. A no-op
    /// when there is nothing to undo.
    public func undo() {
        guard let previous = history.popLast() else { return }
        // Return the current active to the front of the queue, deduping by id so
        // the displaced card can never appear twice in the deck.
        if let current = active {
            queue.removeAll { $0.id == current.id }
            queue.insert(current, at: 0)
        }
        active = previous
        if seenThisGeneration > 0 {
            seenThisGeneration -= 1
        }
    }

    /// ISC-152: reset the seen-counter for a fresh deck generation. Called only
    /// when an incoming stack carries a version we have not already adopted, so a
    /// same-version re-merge (idempotent refresh) does not rewind the indicator.
    private func startGenerationIfNewVersion(_ incoming: StackVersion) {
        if version != incoming {
            seenThisGeneration = 0
            // ISC-160: a new deck generation invalidates undo history — a card
            // from the old deck must never be resurrectable into the new one.
            history = []
        }
    }

    /// Replace queue with the stack's tail (or full deck if no active card),
    /// leaving `active` untouched. Called when a fresh fetch arrives while the
    /// app is open (§5 rule 4). Cards already-active are filtered out.
    public func merge(stack: CardStack) {
        // ISC-152: a new version starts a fresh deck generation (reset the
        // seen-counter). Must run before we overwrite `version`.
        startGenerationIfNewVersion(stack.version)
        version = stack.version
        if active == nil {
            // First-ever load (or after exhausting the deck). Either way the
            // position genuinely restarts at 1, so this is always a fresh
            // generation regardless of version equality (ISC-152).
            seenThisGeneration = 0
            if let first = stack.cards.first {
                active = first
                queue = Array(stack.cards.dropFirst()).sorted { $0.priority < $1.priority }
            } else {
                queue = []
            }
            return
        }
        // Re-queue everything except the active card; re-sort by priority.
        let activeId = active?.id
        let rest = stack.cards.filter { $0.id != activeId }
        queue = rest.sorted { $0.priority < $1.priority }
    }

    /// Backend signalled a flush. Clear the queue; `active` remains until the
    /// user swipes (§5 rule 6).
    public func flush(replacement: CardStack) {
        // ISC-152: a new version starts a fresh deck generation.
        startGenerationIfNewVersion(replacement.version)
        version = replacement.version
        queue = replacement.cards.filter { $0.id != active?.id }
            .sorted { $0.priority < $1.priority }
    }

    /// Promote a single card to the front of the queue without touching `active`.
    public func prependUrgent(_ card: Card) {
        // Don't duplicate it if it's already in the queue.
        queue.removeAll { $0.id == card.id }
        queue.insert(card, at: 0)
    }

    /// Adopt a freshly-fetched stack. Decides between `merge` (normal update),
    /// `flush` (empty cards array), or first-load.
    public func adopt(_ stack: CardStack) {
        if stack.isFlush {
            flush(replacement: stack)
        } else {
            merge(stack: stack)
        }
    }

    /// For an unforeseen reorder: a higher-priority card (lower numeric value)
    /// gets promoted in the queue, but never replaces `active` (§5 rule 5).
    public func reorderQueueByPriority() {
        queue.sort { $0.priority < $1.priority }
    }
}
