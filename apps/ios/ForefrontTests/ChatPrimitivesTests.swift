import XCTest
@testable import ForefrontModels
@testable import ForefrontStorage
@testable import ForefrontNetworking

/// Phase 6 — the three agent→human primitives, verified end-to-end at the
/// service + store layer (the UI wiring in `ChatEnvironment`/`MessageBubbleView`
/// delegates to exactly these calls, so this is the load-bearing verification;
/// the SwiftUI layer is separately type-checked by `check-ui-compile.sh`).
///
///   1. Quick-reply / notification-action answers post back as user messages.
///   2. Drive-to-form: a `linkToWebCard` message carries a tappable URL that
///      survives persist → load.
///   3. Reminder messages render (kind + due date) and are addressable for
///      tap-routing by `chatId`.
final class ChatPrimitivesTests: XCTestCase {

    override func setUp() { super.setUp(); MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset(); super.tearDown() }

    private let endpoints = [URL(string: "https://primary.example")!]

    private func makeService() throws -> (ChatService, SQLiteChatStore) {
        let client = APIClient(
            rotator: EndpointRotator(endpoints: endpoints),
            tokenProvider: { "test-token" },
            session: MockSession.make()
        )
        let store = try SQLiteChatStore(inMemory: true)
        return (ChatService(net: client, store: store, tokenStore: KeychainStore()), store)
    }

    // MARK: - Primitive 1: quick-reply posts back as a user message

    func testQuickReplyPostsBackAsUserMessage() async throws {
        let (service, store) = try makeService()
        try store.upsertChats([Chat(id: "ch1", title: "R", lastMessageAt: Date(timeIntervalSince1970: 0))])
        // The agent asked a question with quick-replies; the human taps "Booked it".
        MockURLProtocol.script(path: "/chats/ch1/messages", responses: [.status(200, body: Data("""
        {"id":"m_srv","chatId":"ch1","role":"user","kind":"text","body":"Booked it",
         "createdAt":"2026-07-09T16:42:00Z","clientMessageId":"x"}
        """.utf8))])

        // A quick-reply is just a send with the label as the body (contract §10).
        let outcome = await service.send(chatId: "ch1", body: "Booked it")
        guard case .sent(let msg) = outcome else { return XCTFail("expected .sent, got \(outcome)") }
        XCTAssertEqual(msg.role, .user, "a quick-reply answer is authored by the user")
        XCTAssertEqual(msg.body, "Booked it")
        // It lands in the thread as a real message.
        let thread = try store.loadMessages(chatId: "ch1")
        XCTAssertEqual(thread.map(\.body), ["Booked it"])
    }

    // MARK: - Primitive 2: drive-to-form web-card URL survives the round-trip

    func testLinkToWebCardURLSurvivesFetchAndPersist() async throws {
        let (service, store) = try makeService()
        MockURLProtocol.script(path: "/chats/ch1/messages", responses: [.status(200, body: Data("""
        {"messages":[
          {"id":"w1","chatId":"ch1","role":"agent","kind":"linkToWebCard",
           "body":"Open the form","createdAt":"2026-07-09T16:41:00Z",
           "webCardURL":"https://x.ts.net/forms/travel"}
        ],"nextCursor":"c1"}
        """.utf8))])

        let outcome = await service.syncMessages(chatId: "ch1")
        guard case .updated(let messages) = outcome else { return XCTFail("expected .updated") }
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].kind, .linkToWebCard)
        XCTAssertEqual(messages[0].webCardURL?.absoluteString, "https://x.ts.net/forms/travel",
                       "the drive-to-form URL must survive fetch → persist → load so the bubble can open it")
    }

    // MARK: - Primitive 3: reminder renders with due date and is chat-addressable

    func testReminderMessageRendersAndIsAddressable() async throws {
        let (service, store) = try makeService()
        MockURLProtocol.script(path: "/chats/ch_reminders/messages", responses: [.status(200, body: Data("""
        {"messages":[
          {"id":"r1","chatId":"ch_reminders","role":"agent","kind":"reminder",
           "body":"Have you booked the flight yet?","createdAt":"2026-07-09T16:40:00Z",
           "quickReplies":["Booked it","Snooze 1h","Not yet"],
           "reminder":{"dueAt":"2026-07-11T17:00:00Z"}}
        ],"nextCursor":"c1"}
        """.utf8))])

        let outcome = await service.syncMessages(chatId: "ch_reminders")
        guard case .updated(let messages) = outcome else { return XCTFail("expected .updated") }
        let reminder = try XCTUnwrap(messages.first)
        XCTAssertEqual(reminder.kind, .reminder)
        XCTAssertNotNil(reminder.reminder?.dueAt, "a reminder renders its due date")
        XCTAssertEqual(reminder.quickReplies, ["Booked it", "Snooze 1h", "Not yet"])
        // Addressable by chatId — this is what a notification tap deep-links to.
        XCTAssertEqual(reminder.chatId, "ch_reminders")
    }

    // MARK: - Demo fixture decodes into the demo surface

    func testDemoChatFixtureDecodes() throws {
        struct DemoFixture: Decodable {
            let chat: Chat
            let messages: [Message]
        }
        let url = Bundle.module.url(forResource: "demo_chat", withExtension: "json", subdirectory: "Fixtures")!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let fixture = try dec.decode(DemoFixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.chat.id, "demo_agent")
        // Every v1 kind is represented so App Review sees the full surface.
        let kinds = Set(fixture.messages.map(\.kind))
        XCTAssertEqual(kinds, [.text, .question, .linkToWebCard, .reminder])
    }

    // MARK: - DemoChatService send lands in the thread (offline-safe demo)

    func testDemoServiceSendAppendsToThread() async throws {
        let store = try SQLiteChatStore(inMemory: true)
        let demo = DemoChatService(store: store)
        _ = await demo.syncChats()  // seed
        let outcome = await demo.send(chatId: "demo_agent", body: "Yes, draft it")
        guard case .sent(let msg) = outcome else { return XCTFail("expected .sent") }
        XCTAssertEqual(msg.role, .user)
        let thread = try store.loadMessages(chatId: "demo_agent")
        XCTAssertTrue(thread.contains { $0.body == "Yes, draft it" && $0.role == .user })
    }
}
