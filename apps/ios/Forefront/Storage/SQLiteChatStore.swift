import Foundation
import SQLite3
import ForefrontModels

/// Errors from the SQLite chat store. Each carries the SQLite message so a
/// failure is diagnosable, never a bare status code.
public enum ChatStoreError: Error, Equatable, Sendable {
    case open(String)
    case prepare(String)
    case step(String)
    case bind(String)
    case migration(String)
}

/// A thin `SQLite3`-backed `ChatStoring` implementation. No external dependency
/// — `SQLite3` ships with the platform on iOS and macOS, so this compiles for
/// both the app and the `swift test` host (DECISIONS.md D-13). A GRDB-backed
/// store can replace it behind the `ChatStoring` seam later.
///
/// **TODO(D-13):** swap for a GRDB-backed `ChatStoring` once GRDB is vetted
/// against `swift test`.
///
/// Concurrency: every public method routes through a single serial
/// `DispatchQueue`, so the raw `OpaquePointer` handle is only ever touched from
/// one thread. That makes the whole type safe to share across isolation domains,
/// hence `@unchecked Sendable` (the only mutable stored state — the sqlite
/// handle — is queue-confined).
public final class SQLiteChatStore: ChatStoring, @unchecked Sendable {

    private let db: OpaquePointer
    private let queue = DispatchQueue(label: "com.trilliumsmith.forefront.chatstore")

    // SQLite wants this transient-destructor pointer when binding Swift strings
    // so it copies the bytes rather than retaining our (soon-freed) buffer.
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// - Parameter directory: where `chat.sqlite` lives. Defaults to
    ///   `Application Support/forefront/` (same home as the deck cache, D-07).
    ///   Tests pass a temp dir. Pass `":memory:"` semantics via
    ///   `init(inMemory: true)` for fast, isolated unit tests.
    public convenience init(fileManager: FileManager = .default, directory: URL? = nil) throws {
        let supportDir: URL
        if let directory {
            supportDir = directory
        } else {
            supportDir = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("forefront", isDirectory: true)
        }
        if !fileManager.fileExists(atPath: supportDir.path) {
            try fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
        }
        let fileURL = supportDir.appendingPathComponent("chat.sqlite")
        try self.init(path: fileURL.path)
    }

    /// In-memory store for tests. Each instance is an isolated database that
    /// evaporates when the store is deallocated.
    public convenience init(inMemory: Bool) throws {
        try self.init(path: inMemory ? ":memory:" : "chat.sqlite")
    }

    /// Designated initializer. `path` is a filesystem path or `":memory:"`.
    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 rc=\(rc)"
            if let handle { sqlite3_close(handle) }
            throw ChatStoreError.open(msg)
        }
        self.db = handle
        // Durability + concurrency pragmas, then schema.
        do {
            try Self.exec(db, "PRAGMA journal_mode = WAL;")
            try Self.exec(db, "PRAGMA foreign_keys = ON;")
            try Self.migrate(db)
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema

    private static func migrate(_ db: OpaquePointer) throws {
        // One schema version; additive migrations would bump user_version.
        try exec(db, """
        CREATE TABLE IF NOT EXISTS chats (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            lastMessageAt REAL NOT NULL,
            serverUnread INTEGER NOT NULL DEFAULT 0,
            lastMessagePreview TEXT,
            topic TEXT,
            lastReadAt REAL NOT NULL DEFAULT 0,
            cursor TEXT
        );
        """)
        try exec(db, """
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY NOT NULL,
            chatId TEXT NOT NULL,
            role TEXT NOT NULL,
            kind TEXT NOT NULL,
            body TEXT NOT NULL,
            createdAt REAL NOT NULL,
            quickReplies TEXT,       -- JSON array or NULL
            webCardURL TEXT,
            reminderDueAt REAL,      -- NULL if not a reminder / no due date
            clientMessageId TEXT,
            status TEXT NOT NULL DEFAULT 'sent'
        );
        """)
        // Query-by-thread, ordered — the hot path.
        try exec(db, "CREATE INDEX IF NOT EXISTS idx_messages_chat_time ON messages(chatId, createdAt);")
        // Outbox drain + reconcile-by-key.
        try exec(db, "CREATE INDEX IF NOT EXISTS idx_messages_client_id ON messages(clientMessageId);")
        try exec(db, "CREATE INDEX IF NOT EXISTS idx_messages_status ON messages(status);")
    }

    // MARK: - ChatStoring: chats

    public func upsertChats(_ chats: [Chat]) throws {
        try queue.sync {
            try Self.exec(db, "BEGIN IMMEDIATE;")
            do {
                let sql = """
                INSERT INTO chats (id, title, lastMessageAt, serverUnread, lastMessagePreview, topic, lastReadAt, cursor)
                VALUES (?, ?, ?, ?, ?, ?, COALESCE((SELECT lastReadAt FROM chats WHERE id = ?), 0),
                                        (SELECT cursor FROM chats WHERE id = ?))
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    lastMessageAt = excluded.lastMessageAt,
                    serverUnread = excluded.serverUnread,
                    lastMessagePreview = excluded.lastMessagePreview,
                    topic = excluded.topic;
                """
                let stmt = try Statement(db, sql)
                defer { stmt.finalize() }
                for chat in chats {
                    stmt.reset()
                    try stmt.bindText(1, chat.id)
                    try stmt.bindText(2, chat.title)
                    stmt.bindDouble(3, chat.lastMessageAt.timeIntervalSince1970)
                    stmt.bindInt(4, Int32(chat.unreadCount))
                    try stmt.bindTextOrNull(5, chat.lastMessagePreview)
                    try stmt.bindTextOrNull(6, chat.topic)
                    try stmt.bindText(7, chat.id)  // for the lastReadAt subquery
                    try stmt.bindText(8, chat.id)  // for the cursor subquery
                    try stmt.stepDone()
                }
                try Self.exec(db, "COMMIT;")
            } catch {
                try? Self.exec(db, "ROLLBACK;")
                throw error
            }
        }
    }

    public func loadChats() throws -> [Chat] {
        try queue.sync {
            let sql = """
            SELECT c.id, c.title, c.lastMessageAt, c.serverUnread, c.lastMessagePreview, c.topic, c.lastReadAt,
                   (SELECT COUNT(*) FROM messages m
                     WHERE m.chatId = c.id AND m.role <> 'user' AND m.createdAt > c.lastReadAt) AS localUnread
            FROM chats c
            ORDER BY c.lastMessageAt DESC;
            """
            let stmt = try Statement(db, sql)
            defer { stmt.finalize() }
            var out: [Chat] = []
            while try stmt.step() {
                let serverUnread = Int(stmt.columnInt(3))
                let localUnread = Int(stmt.columnInt(7))
                out.append(Chat(
                    id: stmt.columnText(0),
                    title: stmt.columnText(1),
                    lastMessageAt: Date(timeIntervalSince1970: stmt.columnDouble(2)),
                    // Never under-count: show the larger of what the server
                    // claimed and what we can see locally (contract §8).
                    unreadCount: max(serverUnread, localUnread),
                    lastMessagePreview: stmt.columnTextOrNil(4),
                    topic: stmt.columnTextOrNil(5)
                ))
            }
            return out
        }
    }

    // MARK: - ChatStoring: messages

    public func upsertMessages(_ messages: [Message]) throws {
        guard !messages.isEmpty else { return }
        try queue.sync {
            try Self.exec(db, "BEGIN IMMEDIATE;")
            do {
                for message in messages {
                    // If this server message reconciles an outbox row (same
                    // clientMessageId), drop the optimistic row first so we don't
                    // keep both the optimistic and the canonical copy.
                    if let cid = message.clientMessageId {
                        let del = try Statement(db, "DELETE FROM messages WHERE clientMessageId = ? AND id <> ?;")
                        defer { del.finalize() }
                        try del.bindText(1, cid)
                        try del.bindText(2, message.id)
                        try del.stepDone()
                    }
                    try Self.insertMessage(db, message)
                }
                try Self.exec(db, "COMMIT;")
            } catch {
                try? Self.exec(db, "ROLLBACK;")
                throw error
            }
        }
    }

    public func loadMessages(chatId: String) throws -> [Message] {
        try queue.sync {
            let sql = """
            SELECT id, chatId, role, kind, body, createdAt, quickReplies, webCardURL, reminderDueAt, clientMessageId, status
            FROM messages WHERE chatId = ?
            ORDER BY createdAt ASC, id ASC;
            """
            let stmt = try Statement(db, sql)
            defer { stmt.finalize() }
            try stmt.bindText(1, chatId)
            var out: [Message] = []
            while try stmt.step() {
                out.append(Self.messageFromRow(stmt))
            }
            return out
        }
    }

    // MARK: - ChatStoring: unread

    public func markRead(chatId: String, upTo: Date = Date()) throws {
        try queue.sync {
            let stmt = try Statement(db, "UPDATE chats SET lastReadAt = ?, serverUnread = 0 WHERE id = ?;")
            defer { stmt.finalize() }
            stmt.bindDouble(1, upTo.timeIntervalSince1970)
            try stmt.bindText(2, chatId)
            try stmt.stepDone()
        }
    }

    public func unreadCount(chatId: String) throws -> Int {
        try queue.sync {
            let sql = """
            SELECT COUNT(*) FROM messages m
            JOIN chats c ON c.id = m.chatId
            WHERE m.chatId = ? AND m.role <> 'user' AND m.createdAt > c.lastReadAt;
            """
            let stmt = try Statement(db, sql)
            defer { stmt.finalize() }
            try stmt.bindText(1, chatId)
            guard try stmt.step() else { return 0 }
            return Int(stmt.columnInt(0))
        }
    }

    // MARK: - ChatStoring: cursor

    public func cursor(chatId: String) throws -> String? {
        try queue.sync {
            let stmt = try Statement(db, "SELECT cursor FROM chats WHERE id = ?;")
            defer { stmt.finalize() }
            try stmt.bindText(1, chatId)
            guard try stmt.step() else { return nil }
            return stmt.columnTextOrNil(0)
        }
    }

    public func setCursor(chatId: String, cursor: String) throws {
        try queue.sync {
            // A cursor may arrive for a thread whose /chats row hasn't loaded yet
            // (message fetch preceded inbox refresh). Upsert a shell row so the
            // cursor is never dropped.
            let stmt = try Statement(db, """
            INSERT INTO chats (id, title, lastMessageAt, cursor)
            VALUES (?, '', 0, ?)
            ON CONFLICT(id) DO UPDATE SET cursor = excluded.cursor;
            """)
            defer { stmt.finalize() }
            try stmt.bindText(1, chatId)
            try stmt.bindText(2, cursor)
            try stmt.stepDone()
        }
    }

    // MARK: - ChatStoring: outbox

    public func enqueueOutbox(_ message: Message) throws {
        try queue.sync {
            try Self.insertMessage(db, message)
        }
    }

    public func pendingOutbox() throws -> [Message] {
        try queue.sync {
            let sql = """
            SELECT id, chatId, role, kind, body, createdAt, quickReplies, webCardURL, reminderDueAt, clientMessageId, status
            FROM messages
            WHERE status IN ('sending', 'failed') AND clientMessageId IS NOT NULL
            ORDER BY createdAt ASC, id ASC;
            """
            let stmt = try Statement(db, sql)
            defer { stmt.finalize() }
            var out: [Message] = []
            while try stmt.step() {
                out.append(Self.messageFromRow(stmt))
            }
            return out
        }
    }

    public func markOutboxFailed(clientMessageId: String) throws {
        try queue.sync {
            let stmt = try Statement(db, "UPDATE messages SET status = 'failed' WHERE clientMessageId = ?;")
            defer { stmt.finalize() }
            try stmt.bindText(1, clientMessageId)
            try stmt.stepDone()
        }
    }

    public func reconcileSent(clientMessageId: String, serverMessage: Message) throws {
        try queue.sync {
            try Self.exec(db, "BEGIN IMMEDIATE;")
            do {
                // Drop the optimistic row(s) keyed by clientMessageId, then insert
                // the canonical server message. Guard against the canonical id
                // being deleted if it happened to equal the optimistic id.
                let del = try Statement(db, "DELETE FROM messages WHERE clientMessageId = ? AND id <> ?;")
                defer { del.finalize() }
                try del.bindText(1, clientMessageId)
                try del.bindText(2, serverMessage.id)
                try del.stepDone()

                // Force status .sent on the canonical row regardless of what the
                // caller passed.
                var canonical = serverMessage
                canonical.status = .sent
                try Self.insertMessage(db, canonical)
                try Self.exec(db, "COMMIT;")
            } catch {
                try? Self.exec(db, "ROLLBACK;")
                throw error
            }
        }
    }

    // MARK: - Row <-> Message

    /// INSERT OR REPLACE a message. Must be called inside `queue.sync`.
    private static func insertMessage(_ db: OpaquePointer, _ m: Message) throws {
        let sql = """
        INSERT OR REPLACE INTO messages
        (id, chatId, role, kind, body, createdAt, quickReplies, webCardURL, reminderDueAt, clientMessageId, status)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let stmt = try Statement(db, sql)
        defer { stmt.finalize() }
        try stmt.bindText(1, m.id)
        try stmt.bindText(2, m.chatId)
        try stmt.bindText(3, m.role.rawValue)
        try stmt.bindText(4, m.kind.rawValue)
        try stmt.bindText(5, m.body)
        stmt.bindDouble(6, m.createdAt.timeIntervalSince1970)
        try stmt.bindTextOrNull(7, encodeQuickReplies(m.quickReplies))
        try stmt.bindTextOrNull(8, m.webCardURL?.absoluteString)
        if let due = m.reminder?.dueAt {
            stmt.bindDouble(9, due.timeIntervalSince1970)
        } else {
            stmt.bindNull(9)
        }
        try stmt.bindTextOrNull(10, m.clientMessageId)
        try stmt.bindText(11, m.status.rawValue)
        try stmt.stepDone()
    }

    private static func messageFromRow(_ s: Statement) -> Message {
        let reminderDue: ReminderInfo? = s.columnIsNull(8)
            ? nil
            : ReminderInfo(dueAt: Date(timeIntervalSince1970: s.columnDouble(8)))
        // A reminder row with a NULL due date still needs a ReminderInfo when the
        // kind is .reminder so the UI branch is stable; but we only synthesize one
        // when there is an actual due date, mirroring the model's optionality.
        return Message(
            id: s.columnText(0),
            chatId: s.columnText(1),
            role: MessageRole(rawValue: s.columnText(2)) ?? .system,
            kind: MessageKind(rawValue: s.columnText(3)) ?? .text,
            body: s.columnText(4),
            createdAt: Date(timeIntervalSince1970: s.columnDouble(5)),
            quickReplies: decodeQuickReplies(s.columnTextOrNil(6)),
            webCardURL: s.columnTextOrNil(7).flatMap(URL.init(string:)),
            reminder: reminderDue,
            clientMessageId: s.columnTextOrNil(9),
            status: MessageStatus(rawValue: s.columnText(10)) ?? .sent
        )
    }

    private static func encodeQuickReplies(_ replies: [String]?) -> String? {
        guard let replies, !replies.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(replies) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeQuickReplies(_ json: String?) -> [String]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    // MARK: - Low-level exec

    /// Run a statement that returns no rows (DDL / pragma / BEGIN / COMMIT).
    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        guard rc == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "sqlite3_exec rc=\(rc)"
            sqlite3_free(errMsg)
            throw ChatStoreError.migration(msg)
        }
    }

    // MARK: - Statement wrapper

    /// A prepared-statement RAII-ish wrapper. Callers `finalize()` in a `defer`.
    /// Binding is 1-indexed (SQLite convention); column reads are 0-indexed.
    final class Statement {
        private let db: OpaquePointer
        private let handle: OpaquePointer

        init(_ db: OpaquePointer, _ sql: String) throws {
            self.db = db
            var stmt: OpaquePointer?
            let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard rc == SQLITE_OK, let stmt else {
                throw ChatStoreError.prepare(String(cString: sqlite3_errmsg(db)))
            }
            self.handle = stmt
        }

        func finalize() {
            sqlite3_finalize(handle)
        }

        func reset() {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
        }

        // MARK: bind (1-indexed)

        func bindText(_ index: Int32, _ value: String) throws {
            let rc = sqlite3_bind_text(handle, index, value, -1, SQLiteChatStore.SQLITE_TRANSIENT)
            guard rc == SQLITE_OK else { throw ChatStoreError.bind(String(cString: sqlite3_errmsg(db))) }
        }

        func bindTextOrNull(_ index: Int32, _ value: String?) throws {
            if let value { try bindText(index, value) } else { bindNull(index) }
        }

        func bindInt(_ index: Int32, _ value: Int32) {
            sqlite3_bind_int(handle, index, value)
        }

        func bindDouble(_ index: Int32, _ value: Double) {
            sqlite3_bind_double(handle, index, value)
        }

        func bindNull(_ index: Int32) {
            sqlite3_bind_null(handle, index)
        }

        // MARK: step

        /// Step once. Returns true if a row is available (`SQLITE_ROW`), false on
        /// `SQLITE_DONE`. Throws on any other status.
        @discardableResult
        func step() throws -> Bool {
            let rc = sqlite3_step(handle)
            switch rc {
            case SQLITE_ROW:  return true
            case SQLITE_DONE: return false
            default:
                throw ChatStoreError.step(String(cString: sqlite3_errmsg(db)))
            }
        }

        /// Step a write statement expected to yield no rows.
        func stepDone() throws {
            let produced = try step()
            if produced {
                // A write statement returned a row — unexpected but not fatal;
                // drain to DONE so the statement can be reset/reused.
                while try step() {}
            }
        }

        // MARK: column reads (0-indexed)

        func columnInt(_ index: Int32) -> Int64 {
            sqlite3_column_int64(handle, index)
        }

        func columnDouble(_ index: Int32) -> Double {
            sqlite3_column_double(handle, index)
        }

        func columnIsNull(_ index: Int32) -> Bool {
            sqlite3_column_type(handle, index) == SQLITE_NULL
        }

        func columnText(_ index: Int32) -> String {
            guard let cString = sqlite3_column_text(handle, index) else { return "" }
            return String(cString: cString)
        }

        func columnTextOrNil(_ index: Int32) -> String? {
            if columnIsNull(index) { return nil }
            guard let cString = sqlite3_column_text(handle, index) else { return nil }
            return String(cString: cString)
        }
    }
}
