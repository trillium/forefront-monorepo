import XCTest
@testable import ForefrontModels
@testable import ForefrontStorage

final class SQLiteChatStoreTests: XCTestCase {

    private func makeStore() throws -> SQLiteChatStore {
        // In-memory: isolated per test, no filesystem bleed.
        try SQLiteChatStore(inMemory: true)
    }

    private func chat(_ id: String, unread: Int = 0, at: TimeInterval = 0) -> Chat {
        Chat(id: id, title: id.capitalized, lastMessageAt: Date(timeIntervalSince1970: at), unreadCount: unread)
    }

    private func makeMsg(
        _ id: String,
        chat: String = "ch1",
        role: MessageRole = .agent,
        kind: MessageKind = .text,
        body: String = "hi",
        at: TimeInterval = 0,
        clientId: String? = nil,
        status: MessageStatus = .sent
    ) -> Message {
        Message(id: id, chatId: chat, role: role, kind: kind, body: body,
                createdAt: Date(timeIntervalSince1970: at), clientMessageId: clientId, status: status)
    }

    // MARK: - Chats

    func testUpsertAndLoadChatsOrderedByRecency() throws {
        let store = try makeStore()
        try store.upsertChats([chat("a", at: 100), chat("b", at: 300), chat("c", at: 200)])
        let chats = try store.loadChats()
        XCTAssertEqual(chats.map(\.id), ["b", "c", "a"], "most-recently-active first")
    }

    func testUpsertChatReplacesMetadata() throws {
        let store = try makeStore()
        try store.upsertChats([chat("a", at: 100)])
        try store.upsertChats([Chat(id: "a", title: "Renamed", lastMessageAt: Date(timeIntervalSince1970: 400), unreadCount: 5)])
        let chats = try store.loadChats()
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats[0].title, "Renamed")
        XCTAssertEqual(chats[0].unreadCount, 5)
    }

    // MARK: - Messages: append + ordered query

    func testMessagesReadBackOldestFirst() throws {
        let store = try makeStore()
        try store.upsertChats([chat("ch1")])
        try store.upsertMessages([
            makeMsg("m3", body: "third", at: 300),
            makeMsg("m1", body: "first", at: 100),
            makeMsg("m2", body: "second", at: 200)
        ])
        let out = try store.loadMessages(chatId: "ch1")
        XCTAssertEqual(out.map(\.body), ["first", "second", "third"])
    }

    func testUpsertMessageDedupsOnServerId() throws {
        let store = try makeStore()
        try store.upsertMessages([makeMsg("m1", body: "v1", at: 100)])
        try store.upsertMessages([makeMsg("m1", body: "v2-edited", at: 100)])
        let out = try store.loadMessages(chatId: "ch1")
        XCTAssertEqual(out.count, 1, "same server id must not duplicate")
        XCTAssertEqual(out[0].body, "v2-edited")
    }

    func testRichFieldsRoundTrip() throws {
        let store = try makeStore()
        let reminder = Message(
            id: "r1", chatId: "ch1", role: .agent, kind: .reminder,
            body: "due soon", createdAt: Date(timeIntervalSince1970: 10),
            quickReplies: ["Done", "Snooze"],
            webCardURL: nil,
            reminder: ReminderInfo(dueAt: Date(timeIntervalSince1970: 9999))
        )
        let webCard = Message(
            id: "w1", chatId: "ch1", role: .agent, kind: .linkToWebCard,
            body: "open form", createdAt: Date(timeIntervalSince1970: 20),
            webCardURL: URL(string: "https://x.ts.net/form")!
        )
        try store.upsertMessages([reminder, webCard])
        let out = try store.loadMessages(chatId: "ch1")
        XCTAssertEqual(out[0].kind, .reminder)
        XCTAssertEqual(out[0].quickReplies, ["Done", "Snooze"])
        XCTAssertEqual(out[0].reminder?.dueAt, Date(timeIntervalSince1970: 9999))
        XCTAssertEqual(out[1].kind, .linkToWebCard)
        XCTAssertEqual(out[1].webCardURL?.absoluteString, "https://x.ts.net/form")
    }

    // MARK: - Unread

    func testUnreadCountsAgentMessagesAfterLastRead() throws {
        let store = try makeStore()
        try store.upsertChats([chat("ch1", at: 500)])
        try store.upsertMessages([
            makeMsg("m1", role: .agent, at: 100),
            makeMsg("m2", role: .user, at: 200),   // user's own — never unread
            makeMsg("m3", role: .agent, at: 300),
            makeMsg("m4", role: .agent, at: 400)
        ])
        // Nothing read yet → 3 agent messages unread.
        XCTAssertEqual(try store.unreadCount(chatId: "ch1"), 3)

        // Read up to t=300 → only m4 (t=400) remains unread.
        try store.markRead(chatId: "ch1", upTo: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(try store.unreadCount(chatId: "ch1"), 1)
    }

    func testLoadChatsUnreadNeverUnderCountsServer() throws {
        let store = try makeStore()
        // Server claims 9 unread; we hold only 1 agent message locally.
        try store.upsertChats([chat("ch1", unread: 9, at: 500)])
        try store.upsertMessages([makeMsg("m1", role: .agent, at: 100)])
        let chats = try store.loadChats()
        XCTAssertEqual(chats[0].unreadCount, 9, "show max(server, local)")
    }

    func testMarkReadZeroesUnread() throws {
        let store = try makeStore()
        try store.upsertChats([chat("ch1", unread: 4, at: 500)])
        try store.upsertMessages([makeMsg("m1", role: .agent, at: 100)])
        try store.markRead(chatId: "ch1", upTo: Date(timeIntervalSince1970: 1000))
        let chats = try store.loadChats()
        XCTAssertEqual(chats[0].unreadCount, 0, "markRead zeroes both server tally and local unread")
    }

    // MARK: - Cursor

    func testCursorPersistsPerChat() throws {
        let store = try makeStore()
        XCTAssertNil(try store.cursor(chatId: "ch1"))
        try store.setCursor(chatId: "ch1", cursor: "c_42")
        XCTAssertEqual(try store.cursor(chatId: "ch1"), "c_42")
        // Upserting the chat again must NOT clobber the cursor.
        try store.upsertChats([chat("ch1", at: 100)])
        XCTAssertEqual(try store.cursor(chatId: "ch1"), "c_42")
    }

    // MARK: - Outbox

    func testEnqueueAndDrainOutboxInOrder() throws {
        let store = try makeStore()
        try store.enqueueOutbox(makeMsg("o1", role: .user, at: 100, clientId: "cid-1", status: .sending))
        try store.enqueueOutbox(makeMsg("o2", role: .user, at: 200, clientId: "cid-2", status: .sending))
        let pending = try store.pendingOutbox()
        XCTAssertEqual(pending.map(\.clientMessageId), ["cid-1", "cid-2"])
    }

    func testMarkOutboxFailedKeepsRow() throws {
        let store = try makeStore()
        try store.enqueueOutbox(makeMsg("o1", role: .user, at: 100, clientId: "cid-1", status: .sending))
        try store.markOutboxFailed(clientMessageId: "cid-1")
        let pending = try store.pendingOutbox()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].status, .failed, "failed rows stay in the outbox for the next drain")
    }

    func testReconcileSentReplacesOptimisticRow() throws {
        let store = try makeStore()
        try store.upsertChats([chat("ch1", at: 100)])
        // Optimistic local row: id == clientMessageId before the server acks.
        try store.enqueueOutbox(Message(
            id: "cid-1", chatId: "ch1", role: .user, kind: .text, body: "Booked it",
            createdAt: Date(timeIntervalSince1970: 100), clientMessageId: "cid-1", status: .sending
        ))
        XCTAssertEqual(try store.pendingOutbox().count, 1)

        // Server echoes a canonical message with a real id.
        let canonical = Message(
            id: "m_server_1", chatId: "ch1", role: .user, kind: .text, body: "Booked it",
            createdAt: Date(timeIntervalSince1970: 101), clientMessageId: "cid-1", status: .sent
        )
        try store.reconcileSent(clientMessageId: "cid-1", serverMessage: canonical)

        XCTAssertTrue(try store.pendingOutbox().isEmpty, "optimistic row is gone once acknowledged")
        let msgs = try store.loadMessages(chatId: "ch1")
        XCTAssertEqual(msgs.count, 1, "exactly one row survives — the canonical one")
        XCTAssertEqual(msgs[0].id, "m_server_1")
        XCTAssertEqual(msgs[0].status, .sent)
    }

    func testUpsertMessageReconcilesOutboxByClientId() throws {
        // The other reconcile path: a server message arriving via upsertMessages
        // (a normal fetch) that carries a clientMessageId matching an outbox row
        // should drop the optimistic row.
        let store = try makeStore()
        try store.enqueueOutbox(Message(
            id: "cid-9", chatId: "ch1", role: .user, kind: .text, body: "hey",
            createdAt: Date(timeIntervalSince1970: 50), clientMessageId: "cid-9", status: .sending
        ))
        try store.upsertMessages([Message(
            id: "m_srv_9", chatId: "ch1", role: .user, kind: .text, body: "hey",
            createdAt: Date(timeIntervalSince1970: 51), clientMessageId: "cid-9", status: .sent
        )])
        let msgs = try store.loadMessages(chatId: "ch1")
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].id, "m_srv_9")
        XCTAssertTrue(try store.pendingOutbox().isEmpty)
    }

    // MARK: - Persistence across store instances (file-backed)

    func testFileBackedStorePersistsAcrossInstances() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("forefront-chat-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let store = try SQLiteChatStore(directory: dir)
            try store.upsertChats([chat("ch1", at: 100)])
            try store.upsertMessages([makeMsg("m1", body: "persisted", at: 100)])
        }
        // New instance on the same file sees the prior writes.
        let reopened = try SQLiteChatStore(directory: dir)
        XCTAssertEqual(try reopened.loadChats().count, 1)
        XCTAssertEqual(try reopened.loadMessages(chatId: "ch1").first?.body, "persisted")
    }
}
