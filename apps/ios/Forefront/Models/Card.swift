import Foundation

/// A single AI-curated card. Authoritative source: the backend `/stack` endpoint.
/// The client never authors a Card; it only renders one.
public struct Card: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let title: String
    /// Lower = higher priority. Backend authoritative.
    public let priority: Int
    public let createdAt: Date
    public let updatedAt: Date
    /// Optional cache-eviction hint. Seconds from `updatedAt`.
    public let ttl: TimeInterval?
    /// Rendering hint. Unknown decodes to `.unknown` and renders as `.web` (forward-compat).
    public let type: CardType?

    public init(
        id: String,
        url: URL,
        title: String,
        priority: Int,
        createdAt: Date,
        updatedAt: Date,
        ttl: TimeInterval? = nil,
        type: CardType? = .web
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.priority = priority
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.ttl = ttl
        self.type = type
    }

    /// True iff `updatedAt + ttl` is in the past.
    public func isExpired(now: Date = Date()) -> Bool {
        guard let ttl else { return false }
        return updatedAt.addingTimeInterval(ttl) < now
    }
}

/// Rendering hint for a card. Unknown values decode to `.unknown` (forward-compat).
public enum CardType: String, Codable, Sendable {
    case web
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CardType(rawValue: raw) ?? .unknown
    }
}
