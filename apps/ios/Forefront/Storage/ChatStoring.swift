import Foundation
import ForefrontModels

/// Read/write seam for chat persistence. Consumers (`ChatService`, the UI's
/// `ChatEnvironment`) depend on this protocol, never on the concrete
/// `SQLiteChatStore`, so the storage engine can swap — a GRDB-backed store, or a
/// test fake — without any consumer change (see DECISIONS.md D-13).
///
/// The store owns four responsibilities the single-blob `CacheStore` cannot:
///   1. **Append + query-by-thread** — messages accrete; the deck is snapshot.
///   2. **Ordering** — messages read back oldest→newest deterministically.
///   3. **Unread counts** — per-thread, driven by a per-thread last-read marker.
///   4. **Offline outbox** — client-authored messages persist as `.sending`
///      until a POST acknowledges them, surviving app relaunch.
///
/// All methods are synchronous and `throws`. `SQLiteChatStore` serializes them on
/// an internal queue, so the protocol is `Sendable` and safe to call from an
/// actor or the main actor alike.
public protocol ChatStoring: Sendable {
    // MARK: Chats (inbox)

    /// Insert-or-replace a batch of chats (from `GET /chats`). Ordering on read
    /// is by `lastMessageAt` descending — backend order is advisory, but the
    /// store gives a stable, self-consistent order even across partial updates.
    func upsertChats(_ chats: [Chat]) throws

    /// All chats, most-recently-active first, with `unreadCount` recomputed from
    /// locally-stored messages vs. the per-chat last-read marker (so a badge
    /// reflects what the client actually holds, never under-counting).
    func loadChats() throws -> [Chat]

    // MARK: Messages

    /// Insert-or-replace messages for a thread. Dedup key is the server `id`;
    /// a repeated message (same `id`) overwrites rather than duplicating. A
    /// server message carrying a `clientMessageId` that matches an outbox row
    /// reconciles that optimistic row (see `reconcileSent`).
    func upsertMessages(_ messages: [Message]) throws

    /// Messages for a thread, oldest→newest. Includes outbox rows (status
    /// `.sending`/`.failed`) interleaved by `createdAt` so the UI shows an
    /// optimistic bubble immediately.
    func loadMessages(chatId: String) throws -> [Message]

    // MARK: Unread

    /// Mark a thread read up to `Date` (defaults to now). Zeroes its unread count.
    func markRead(chatId: String, upTo: Date) throws

    /// Unread count for one thread: messages with role != `.user` created after
    /// the thread's last-read marker.
    func unreadCount(chatId: String) throws -> Int

    // MARK: Cursor (incremental fetch)

    /// The opaque `since` cursor last received for a thread, or nil if none.
    func cursor(chatId: String) throws -> String?

    /// Persist the opaque `nextCursor` for a thread after a successful fetch.
    func setCursor(chatId: String, cursor: String) throws

    // MARK: Outbox

    /// Enqueue a client-authored message optimistically. Stored with status
    /// `.sending` and its `clientMessageId` as the idempotency + reconcile key.
    /// Returns the row as persisted (so the UI can render it immediately).
    func enqueueOutbox(_ message: Message) throws

    /// All outbox rows awaiting send (status `.sending` or `.failed`), oldest
    /// first — the drain order.
    func pendingOutbox() throws -> [Message]

    /// Mark an outbox row failed (a send attempt errored). It stays in the outbox
    /// for the next drain; the `clientMessageId` is unchanged so a retry can
    /// never produce a duplicate server-side.
    func markOutboxFailed(clientMessageId: String) throws

    /// Reconcile an acknowledged send: the server echoed a canonical message.
    /// Removes the optimistic outbox row (matched by `clientMessageId`) and
    /// inserts the canonical server message (status `.sent`) in its place.
    func reconcileSent(clientMessageId: String, serverMessage: Message) throws
}
