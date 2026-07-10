import Foundation
import ForefrontModels
import ForefrontStorage

/// The chat network surface `ChatService` orchestrates. A protocol seam so tests
/// inject a `MockURLProtocol`-backed `APIClient` or a counting fake without
/// touching real endpoints — exactly like `StackNetworking`. `APIClient` (via
/// `APIClient+Chat`) is the production conformer.
public protocol ChatNetworking: Sendable {
    func fetchChats() async throws -> ChatList
    func fetchMessages(chatId: String, since cursor: String?) async throws -> MessagePage
    func sendMessage(chatId: String, outgoing: OutgoingMessage) async throws -> Message
}

extension APIClient: ChatNetworking {}

/// Protocol seam so `ChatEnvironment` can substitute a `DemoChatService` for App
/// Review (reviewers can't join the tailnet) without touching real endpoints —
/// mirrors `StackRefreshing`. `ChatService` is the production conformer.
public protocol ChatSyncing: Sendable {
    /// Pull the inbox and persist it. Returns the freshly-loaded chats.
    func syncChats() async -> ChatSyncOutcome
    /// Pull new messages for one thread (since its stored cursor), persist them,
    /// advance the cursor. Returns the thread's full message list after merge.
    func syncMessages(chatId: String) async -> MessageSyncOutcome
    /// Enqueue a user message optimistically, then attempt to drain the outbox.
    /// The optimistic row is returned immediately via the store; the outcome
    /// reflects the drain attempt.
    func send(chatId: String, body: String, now: Date) async -> SendOutcome
    /// Attempt to flush every pending outbox message (reconnect / foreground /
    /// manual retry). Idempotent — reuses each row's `clientMessageId`.
    func drainOutbox() async -> DrainOutcome
}

/// Result of an inbox sync. Never throws — a network failure degrades to
/// `.offline` with whatever the store already holds (doctrine: the UI never
/// blocks on the network, mirroring `RefreshOutcome`).
public enum ChatSyncOutcome: Sendable, Equatable {
    case updated([Chat])
    case offline([Chat])
    case unauthorized
}

/// Result of a per-thread message sync.
public enum MessageSyncOutcome: Sendable, Equatable {
    case updated([Message])
    case offline([Message])
    case unauthorized
}

/// Result of a `send`. The optimistic row is always persisted first, so even on
/// failure the UI shows the message with a `.sending`/`.failed` badge.
public enum SendOutcome: Sendable, Equatable {
    /// Server acknowledged; the optimistic row was reconciled to `Message`.
    case sent(Message)
    /// Enqueued but the send failed; it stays in the outbox for the next drain.
    case queued(clientMessageId: String)
    case unauthorized
}

/// Result of an outbox drain.
public enum DrainOutcome: Sendable, Equatable {
    /// How many messages the drain acknowledged, and how many remain pending.
    case drained(sent: Int, remaining: Int)
    case unauthorized
}

/// Orchestrates chat sync + send + outbox drain over a `ChatNetworking` client
/// and a `ChatStoring` store. An `actor` so all store mutation and cursor
/// bookkeeping serialize, mirroring `StackService`.
///
/// Doctrine (mirrors `StackService`): the public methods do NOT throw. Every
/// failure has a representable outcome. A `401` clears the token and surfaces
/// `.unauthorized`, which the UI routes into re-onboarding.
public actor ChatService: ChatSyncing {
    private let net: any ChatNetworking
    private let store: any ChatStoring
    private let tokenStore: any TokenStoring

    public init(net: any ChatNetworking, store: any ChatStoring, tokenStore: any TokenStoring) {
        self.net = net
        self.store = store
        self.tokenStore = tokenStore
    }

    // MARK: - Inbox

    public func syncChats() async -> ChatSyncOutcome {
        EventLog.shared.info("chat", "Syncing inbox")
        do {
            let list = try await net.fetchChats()
            try store.upsertChats(list.chats)
            let chats = (try? store.loadChats()) ?? list.chats
            EventLog.shared.success("chat", "Inbox synced", detail: "\(chats.count) chats")
            return .updated(chats)
        } catch ForefrontNetworkError.unauthorized {
            EventLog.shared.warn("chat", "Inbox sync rejected (401) — re-scan needed")
            try? tokenStore.deleteToken()
            return .unauthorized
        } catch {
            EventLog.shared.error("chat", "Inbox sync failed", detail: StackService.describe(error))
            let cached = (try? store.loadChats()) ?? []
            return .offline(cached)
        }
    }

    // MARK: - Thread messages

    public func syncMessages(chatId: String) async -> MessageSyncOutcome {
        let cursor = (try? store.cursor(chatId: chatId)) ?? nil
        EventLog.shared.info("chat", "Syncing messages", detail: chatId)
        do {
            let page = try await net.fetchMessages(chatId: chatId, since: cursor)
            if !page.messages.isEmpty {
                try store.upsertMessages(page.messages)
            }
            if let next = page.nextCursor, !next.isEmpty {
                try store.setCursor(chatId: chatId, cursor: next)
            }
            let merged = (try? store.loadMessages(chatId: chatId)) ?? page.messages
            EventLog.shared.success("chat", "Messages synced", detail: "\(page.messages.count) new")
            return .updated(merged)
        } catch ForefrontNetworkError.unauthorized {
            EventLog.shared.warn("chat", "Message sync rejected (401)")
            try? tokenStore.deleteToken()
            return .unauthorized
        } catch {
            EventLog.shared.error("chat", "Message sync failed", detail: StackService.describe(error))
            let cached = (try? store.loadMessages(chatId: chatId)) ?? []
            return .offline(cached)
        }
    }

    // MARK: - Send + outbox

    public func send(chatId: String, body: String, now: Date = Date()) async -> SendOutcome {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Nothing to send; report as queued-nothing so the UI is a no-op.
            return .queued(clientMessageId: "")
        }
        let clientMessageId = UUID().uuidString
        // Optimistic row: id == clientMessageId until the server assigns one.
        let optimistic = Message(
            id: clientMessageId,
            chatId: chatId,
            role: .user,
            kind: .text,
            body: trimmed,
            createdAt: now,
            clientMessageId: clientMessageId,
            status: .sending
        )
        // Persist first so the bubble shows even if the send fails / app dies.
        try? store.enqueueOutbox(optimistic)

        let outgoing = OutgoingMessage(clientMessageId: clientMessageId, kind: .text, body: trimmed)
        do {
            let server = try await net.sendMessage(chatId: chatId, outgoing: outgoing)
            try? store.reconcileSent(clientMessageId: clientMessageId, serverMessage: server)
            EventLog.shared.success("chat", "Message sent", detail: chatId)
            return .sent(server)
        } catch ForefrontNetworkError.unauthorized {
            // Leave the optimistic row in the outbox; it will drain after re-auth.
            try? store.markOutboxFailed(clientMessageId: clientMessageId)
            try? tokenStore.deleteToken()
            EventLog.shared.warn("chat", "Send rejected (401) — queued for retry")
            return .unauthorized
        } catch {
            try? store.markOutboxFailed(clientMessageId: clientMessageId)
            EventLog.shared.warn("chat", "Send failed — queued", detail: StackService.describe(error))
            return .queued(clientMessageId: clientMessageId)
        }
    }

    public func drainOutbox() async -> DrainOutcome {
        let pending = (try? store.pendingOutbox()) ?? []
        guard !pending.isEmpty else { return .drained(sent: 0, remaining: 0) }
        EventLog.shared.info("chat", "Draining outbox", detail: "\(pending.count) pending")

        var sentCount = 0
        for message in pending {
            guard let cid = message.clientMessageId else { continue }
            let outgoing = OutgoingMessage(clientMessageId: cid, kind: .text, body: message.body)
            do {
                let server = try await net.sendMessage(chatId: message.chatId, outgoing: outgoing)
                try? store.reconcileSent(clientMessageId: cid, serverMessage: server)
                sentCount += 1
            } catch ForefrontNetworkError.unauthorized {
                try? store.markOutboxFailed(clientMessageId: cid)
                try? tokenStore.deleteToken()
                EventLog.shared.warn("chat", "Outbox drain hit 401 — stopping")
                // Stop draining; the rest stay pending for after re-auth.
                let remaining = ((try? store.pendingOutbox()) ?? []).count
                _ = remaining
                return .unauthorized
            } catch {
                // Leave it pending; a later drain retries with the same cid.
                try? store.markOutboxFailed(clientMessageId: cid)
                EventLog.shared.warn("chat", "Outbox message still failing", detail: StackService.describe(error))
            }
        }
        let remaining = ((try? store.pendingOutbox()) ?? []).count
        EventLog.shared.success("chat", "Outbox drained", detail: "\(sentCount) sent, \(remaining) remaining")
        return .drained(sent: sentCount, remaining: remaining)
    }
}
