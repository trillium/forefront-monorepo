import Foundation
import Observation
import ForefrontModels

/// The queue model is the heart of the §5 behavior rules.
///
/// Invariants:
///   - `active` is sacred. Nothing outside `advance()` ever replaces it.
///   - `merge(stack:)` replaces the queue but leaves `active` alone.
///   - `flush(replacement:)` clears the queue but leaves `active` alone.
///   - `prependUrgent(_:)` inserts a card at queue index 0; `active` unchanged.
///   - All mutations happen on the main actor; UI never sees a partial mutation.
@MainActor
@Observable
public final class StackQueueModel {
    public private(set) var active: Card?
    public private(set) var queue: [Card]
    public private(set) var version: StackVersion?

    public init(active: Card? = nil, queue: [Card] = [], version: StackVersion? = nil) {
        self.active = active
        self.queue = queue
        self.version = version
    }

    /// Pop next card off the queue and promote it to active.
    /// If the queue is empty, `active` becomes nil only after the swipe (§5 rule 6).
    public func advance() {
        if queue.isEmpty {
            active = nil
            return
        }
        active = queue.removeFirst()
    }

    /// Replace queue with the stack's tail (or full deck if no active card),
    /// leaving `active` untouched. Called when a fresh fetch arrives while the
    /// app is open (§5 rule 4). Cards already-active are filtered out.
    public func merge(stack: CardStack) {
        version = stack.version
        if active == nil {
            // First-ever load (or after exhausting the deck).
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
