import Foundation

/// The full ordered deck. Index 0 is the front (most important).
public struct CardStack: Codable, Sendable, Equatable {
    public let version: StackVersion
    public let cards: [Card]

    public init(version: StackVersion, cards: [Card]) {
        self.version = version
        self.cards = cards
    }

    /// A flush is signalled by an empty `cards` array. The client clears its
    /// queue but keeps the active card visible until the user swipes.
    public var isFlush: Bool { cards.isEmpty }
}
