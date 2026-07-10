import XCTest
@testable import ForefrontModels

/// Decodes JSON captured from the LIVE backend (`forefront-backend` main —
/// `GET /chats` and `GET /chats/{id}/messages`) through the real client models.
/// This proves the iOS client can consume what the backend *actually* emits
/// (millisecond timestamps, every message kind, the seeded `ch_general` thread),
/// not just hand-authored fixtures. Regenerate `live_*.json` by curling the
/// running server.
final class LiveShapeTests: XCTestCase {
    private func iso() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func testLiveChatsDecode() throws {
        let url = Bundle.module.url(
            forResource: "live_chats", withExtension: "json", subdirectory: "Fixtures")!
        let list = try iso().decode(ChatList.self, from: Data(contentsOf: url))
        XCTAssertFalse(list.chats.isEmpty)
        // The backend always seeds a general "Agent" thread so the human can
        // always reach out — verify it survives the real→real decode.
        XCTAssertTrue(list.chats.contains { $0.id == "ch_general" })
    }

    func testLiveMessagesDecodeEveryKind() throws {
        let url = Bundle.module.url(
            forResource: "live_messages", withExtension: "json", subdirectory: "Fixtures")!
        let page = try iso().decode(MessagePage.self, from: Data(contentsOf: url))
        XCTAssertEqual(page.messages.count, 5)

        let kinds = Set(page.messages.map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.text, .question, .linkToWebCard, .reminder]))

        // Kind-specific optionals survive the real backend → real model trip.
        XCTAssertEqual(page.messages.first { $0.kind == .question }?.quickReplies, ["A", "B"])
        XCTAssertNotNil(page.messages.first { $0.kind == .linkToWebCard }?.webCardURL)
        XCTAssertNotNil(page.messages.first { $0.kind == .reminder }?.reminder?.dueAt)
        XCTAssertNotNil(page.nextCursor)
    }
}
