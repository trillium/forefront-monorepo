import Foundation

/// A single chat thread — one conversation between the human and the AI agent.
/// Authoritative source: the backend `GET /chats` endpoint. Unlike a `Card`, the
/// client DOES author into a chat (it sends `Message`s), but the thread metadata
/// below is backend-owned; the client only renders it and tracks unread locally.
public struct Chat: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// Timestamp of the newest message; drives inbox ordering + relative time.
    public let lastMessageAt: Date
    /// Backend's unread tally. The client also tracks unread locally; the inbox
    /// shows `max(local, server)` so a badge never under-counts (see contract §8).
    public let unreadCount: Int
    /// Short preview line for the inbox row. Optional.
    public let lastMessagePreview: String?
    /// Coarse routing tag (`reminders`, `questions`, …). Advisory only.
    public let topic: String?

    public init(
        id: String,
        title: String,
        lastMessageAt: Date,
        unreadCount: Int = 0,
        lastMessagePreview: String? = nil,
        topic: String? = nil
    ) {
        self.id = id
        self.title = title
        self.lastMessageAt = lastMessageAt
        self.unreadCount = unreadCount
        self.lastMessagePreview = lastMessagePreview
        self.topic = topic
    }
}

/// The `GET /chats` response envelope. Backend order is authoritative — the
/// client does not re-sort.
public struct ChatList: Codable, Sendable, Equatable {
    public let chats: [Chat]

    public init(chats: [Chat]) {
        self.chats = chats
    }
}
