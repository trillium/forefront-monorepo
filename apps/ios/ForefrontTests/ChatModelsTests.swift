import XCTest
@testable import ForefrontModels

final class ChatModelsTests: XCTestCase {

    private func iso() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Message round-trip

    func testMessageRoundTrip() throws {
        let msg = Message(
            id: "m1",
            chatId: "ch1",
            role: .agent,
            kind: .reminder,
            body: "Do the thing",
            createdAt: Date(timeIntervalSince1970: 0),
            quickReplies: ["Done", "Later"],
            webCardURL: nil,
            reminder: ReminderInfo(dueAt: Date(timeIntervalSince1970: 3600)),
            clientMessageId: nil,
            status: .sent
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(msg)
        let round = try iso().decode(Message.self, from: data)
        // status is local-only and decodes to .sent; everything else round-trips.
        XCTAssertEqual(round.id, msg.id)
        XCTAssertEqual(round.role, .agent)
        XCTAssertEqual(round.kind, .reminder)
        XCTAssertEqual(round.quickReplies, ["Done", "Later"])
        XCTAssertEqual(round.reminder?.dueAt, Date(timeIntervalSince1970: 3600))
        XCTAssertEqual(round.status, .sent)
    }

    // MARK: - Forward-compat on role and kind

    func testUnknownRoleDecodesToSystem() throws {
        let raw = #"{"id":"m","chatId":"c","role":"moderator-from-future","kind":"text","body":"hi","createdAt":"2026-01-01T00:00:00Z"}"#
        let msg = try iso().decode(Message.self, from: Data(raw.utf8))
        XCTAssertEqual(msg.role, .system)
    }

    func testUnknownKindDecodesToText() throws {
        let raw = #"{"id":"m","chatId":"c","role":"agent","kind":"hologram","body":"hi","createdAt":"2026-01-01T00:00:00Z"}"#
        let msg = try iso().decode(Message.self, from: Data(raw.utf8))
        XCTAssertEqual(msg.kind, .text)
    }

    func testMissingKindDefaultsToText() throws {
        let raw = #"{"id":"m","chatId":"c","role":"user","body":"hi","createdAt":"2026-01-01T00:00:00Z"}"#
        let msg = try iso().decode(Message.self, from: Data(raw.utf8))
        XCTAssertEqual(msg.kind, .text)
    }

    // MARK: - Wire message is always .sent regardless of any status field

    func testDecodedServerMessageIsSent() throws {
        // Even if a stray `status` sneaks into the payload, decode ignores it.
        let raw = #"{"id":"m","chatId":"c","role":"user","kind":"text","body":"hi","createdAt":"2026-01-01T00:00:00Z","status":"failed"}"#
        let msg = try iso().decode(Message.self, from: Data(raw.utf8))
        XCTAssertEqual(msg.status, .sent, "a message decoded from the wire is delivered by definition")
    }

    // MARK: - OutgoingMessage

    func testOutgoingMessageEncodesIdempotencyKey() throws {
        let out = OutgoingMessage(clientMessageId: "abc-123", kind: .text, body: "Booked it")
        let data = try JSONEncoder().encode(out)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["clientMessageId"] as? String, "abc-123")
        XCTAssertEqual(obj["kind"] as? String, "text")
        XCTAssertEqual(obj["body"] as? String, "Booked it")
    }

    // MARK: - Fixtures

    func testChatsFixtureDecodes() throws {
        let url = Bundle.module.url(forResource: "chats", withExtension: "json", subdirectory: "Fixtures")!
        let list = try iso().decode(ChatList.self, from: Data(contentsOf: url))
        XCTAssertEqual(list.chats.count, 2)
        XCTAssertEqual(list.chats[0].id, "ch_reminders")
        XCTAssertEqual(list.chats[0].unreadCount, 2)
        XCTAssertEqual(list.chats[0].topic, "reminders")
        XCTAssertNil(list.chats[1].topic)
    }

    func testMessagesFixtureDecodes() throws {
        let url = Bundle.module.url(forResource: "messages", withExtension: "json", subdirectory: "Fixtures")!
        let page = try iso().decode(MessagePage.self, from: Data(contentsOf: url))
        XCTAssertEqual(page.messages.count, 3)
        XCTAssertEqual(page.nextCursor, "c_1002")

        let reminder = page.messages[1]
        XCTAssertEqual(reminder.kind, .reminder)
        XCTAssertEqual(reminder.quickReplies?.count, 3)
        XCTAssertNotNil(reminder.reminder?.dueAt)

        let webCard = page.messages[2]
        XCTAssertEqual(webCard.kind, .linkToWebCard)
        XCTAssertEqual(webCard.webCardURL?.absoluteString, "https://forefront.primary.tailnet-name.ts.net/forms/travel")
    }
}
