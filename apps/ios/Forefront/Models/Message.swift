import Foundation

/// Who authored a message. Unknown values decode to `.system` (forward-compat),
/// so a future role the backend adds never breaks decoding.
public enum MessageRole: String, Codable, Sendable, Hashable {
    case user
    case agent
    case system

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MessageRole(rawValue: raw) ?? .system
    }
}

/// The rendering shape of a message. Unknown values decode to `.text`
/// (forward-compat) — `body` is always present, so `.text` is always renderable.
public enum MessageKind: String, Codable, Sendable, Hashable {
    /// Plain text.
    case text
    /// A question the agent poses; usually carries `quickReplies`.
    case question
    /// A prompt to open a form/page in the existing WebView card surface.
    case linkToWebCard
    /// A due-dated nag. Backend owns cadence; the client only renders + routes.
    case reminder

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MessageKind(rawValue: raw) ?? .text
    }
}

/// Delivery status of a message the CLIENT authored. Server-originated messages
/// are always `.sent`. This field is local-only — it is not part of the wire
/// format and is never decoded from the server (the server echoes a canonical
/// message which the client marks `.sent`).
public enum MessageStatus: String, Codable, Sendable, Hashable {
    /// In the outbox, POST in flight or queued for the next drain.
    case sending
    /// Acknowledged by the server (has a canonical server `id`).
    case sent
    /// A send attempt failed; will be retried on the next drain (same
    /// `clientMessageId`, so a retry can never duplicate).
    case failed
}

/// Advisory reminder metadata. `dueAt` is display-only — the client never
/// schedules against it (cadence is backend-owned, contract §9/§12).
public struct ReminderInfo: Codable, Sendable, Hashable {
    public let dueAt: Date?

    public init(dueAt: Date? = nil) {
        self.dueAt = dueAt
    }
}

/// A single chat message. Server messages arrive via `GET /chats/{id}/messages`;
/// client messages are authored locally, stored in the outbox, and POSTed.
///
/// Same `Codable`/`Sendable` value-type style as `Card`. Decoding tolerates
/// unknown `role`/`kind` (forward-compat) and absent optionals.
public struct Message: Codable, Identifiable, Hashable, Sendable {
    /// Server-canonical id once acknowledged. For an un-sent client message this
    /// is the `clientMessageId` (a UUID string) so the row is `Identifiable`
    /// before the server assigns one; it is reconciled to the server id on ack.
    public let id: String
    public let chatId: String
    public let role: MessageRole
    public let kind: MessageKind
    public let body: String
    public let createdAt: Date
    /// Present on `.question`/`.reminder`; rendered as tap-to-send buttons.
    public let quickReplies: [String]?
    /// Present on `.linkToWebCard`; opens the WebView card surface.
    public let webCardURL: URL?
    /// Present on `.reminder`; display-only due date.
    public let reminder: ReminderInfo?
    /// Client-generated idempotency key. Set for client-authored messages;
    /// echoed by the server so the optimistic local row can be reconciled.
    /// Absent (nil) for purely server-originated messages.
    public let clientMessageId: String?
    /// Local-only delivery status. Never decoded from the wire — defaults to
    /// `.sent` when a message is decoded from the server.
    public var status: MessageStatus

    private enum CodingKeys: String, CodingKey {
        case id, chatId, role, kind, body, createdAt
        case quickReplies, webCardURL, reminder, clientMessageId
        // `status` is intentionally omitted — local-only, not wire.
    }

    public init(
        id: String,
        chatId: String,
        role: MessageRole,
        kind: MessageKind = .text,
        body: String,
        createdAt: Date,
        quickReplies: [String]? = nil,
        webCardURL: URL? = nil,
        reminder: ReminderInfo? = nil,
        clientMessageId: String? = nil,
        status: MessageStatus = .sent
    ) {
        self.id = id
        self.chatId = chatId
        self.role = role
        self.kind = kind
        self.body = body
        self.createdAt = createdAt
        self.quickReplies = quickReplies
        self.webCardURL = webCardURL
        self.reminder = reminder
        self.clientMessageId = clientMessageId
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.chatId = try c.decode(String.self, forKey: .chatId)
        self.role = try c.decode(MessageRole.self, forKey: .role)
        // kind may be absent on some payloads; default to .text.
        self.kind = try c.decodeIfPresent(MessageKind.self, forKey: .kind) ?? .text
        self.body = try c.decode(String.self, forKey: .body)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.quickReplies = try c.decodeIfPresent([String].self, forKey: .quickReplies)
        self.webCardURL = try c.decodeIfPresent(URL.self, forKey: .webCardURL)
        self.reminder = try c.decodeIfPresent(ReminderInfo.self, forKey: .reminder)
        self.clientMessageId = try c.decodeIfPresent(String.self, forKey: .clientMessageId)
        // A message arriving over the wire is, by definition, delivered.
        self.status = .sent
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(chatId, forKey: .chatId)
        try c.encode(role, forKey: .role)
        try c.encode(kind, forKey: .kind)
        try c.encode(body, forKey: .body)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(quickReplies, forKey: .quickReplies)
        try c.encodeIfPresent(webCardURL, forKey: .webCardURL)
        try c.encodeIfPresent(reminder, forKey: .reminder)
        try c.encodeIfPresent(clientMessageId, forKey: .clientMessageId)
    }
}

/// The `GET /chats/{id}/messages?since=<cursor>` response envelope. Messages are
/// ordered oldest→newest within the page. `nextCursor` is opaque — pass it as
/// `since` on the next fetch; the client never parses it.
public struct MessagePage: Codable, Sendable, Equatable {
    public let messages: [Message]
    public let nextCursor: String?

    public init(messages: [Message], nextCursor: String? = nil) {
        self.messages = messages
        self.nextCursor = nextCursor
    }
}

/// The body of a `POST /chats/{id}/messages` send. `clientMessageId` is the
/// idempotency key the backend dedups on (contract §10).
public struct OutgoingMessage: Codable, Sendable, Hashable {
    public let clientMessageId: String
    public let kind: MessageKind
    public let body: String

    public init(clientMessageId: String, kind: MessageKind = .text, body: String) {
        self.clientMessageId = clientMessageId
        self.kind = kind
        self.body = body
    }
}
