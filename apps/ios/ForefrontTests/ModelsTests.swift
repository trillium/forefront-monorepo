import XCTest
@testable import ForefrontModels

final class ModelsTests: XCTestCase {

    func testCardRoundTrip() throws {
        let url = URL(string: "https://example.com/cards/1")!
        let card = Card(
            id: "c1",
            url: url,
            title: "Hello",
            priority: 0,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            ttl: 60,
            type: .web
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(card)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let round = try dec.decode(Card.self, from: data)
        XCTAssertEqual(round, card)
    }

    func testCardTypeForwardCompat() throws {
        let raw = #"{"id":"c","url":"https://x","title":"t","priority":0,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","type":"newtype-from-future"}"#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let card = try dec.decode(Card.self, from: Data(raw.utf8))
        XCTAssertEqual(card.type, .unknown)
    }

    func testCardExpiration() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stale = Card(
            id: "c", url: URL(string: "https://x")!, title: "t", priority: 0,
            createdAt: now, updatedAt: now.addingTimeInterval(-3600), ttl: 1800
        )
        XCTAssertTrue(stale.isExpired(now: now))
        let fresh = Card(
            id: "c", url: URL(string: "https://x")!, title: "t", priority: 0,
            createdAt: now, updatedAt: now, ttl: 1800
        )
        XCTAssertFalse(fresh.isExpired(now: now))
    }

    func testStackVersionDecodesIntAndString() throws {
        let intVal = try JSONDecoder().decode(StackVersion.self, from: Data("42".utf8))
        XCTAssertEqual(intVal.description, "42")
        let stringVal = try JSONDecoder().decode(StackVersion.self, from: Data("\"2026-06-30T07:00:00Z\"".utf8))
        XCTAssertEqual(stringVal.description, "2026-06-30T07:00:00Z")
    }

    func testQRPayloadRejectsEmptyEndpoints() {
        let raw = #"{"version":1,"endpoints":[],"authToken":"x"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(QRPayload.self, from: Data(raw.utf8)))
    }

    func testQRPayloadRejectsEmptyToken() {
        let raw = #"{"version":1,"endpoints":["https://x"],"authToken":""}"#
        XCTAssertThrowsError(try JSONDecoder().decode(QRPayload.self, from: Data(raw.utf8)))
    }

    func testQRPayloadFixtureDecodes() throws {
        let url = Bundle.module.url(forResource: "qr_payload", withExtension: "json", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: url)
        let payload = try JSONDecoder().decode(QRPayload.self, from: data)
        XCTAssertEqual(payload.endpoints.count, 2)
        XCTAssertEqual(payload.authToken, "test-token-do-not-ship")
    }

    func testStackFixtureDecodes() throws {
        let url = Bundle.module.url(forResource: "stack", withExtension: "json", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let stack = try dec.decode(CardStack.self, from: data)
        XCTAssertEqual(stack.cards.count, 2)
        XCTAssertEqual(stack.cards[0].priority, 0)
    }

    func testQRPayloadDescriptionRedactsToken() throws {
        let payload = try QRPayload(
            version: 1,
            endpoints: [URL(string: "https://x")!],
            authToken: "super-secret-token-XYZ",
            push: nil
        )
        XCTAssertFalse(payload.description.contains("super-secret-token-XYZ"))
        XCTAssertTrue(payload.description.contains("<redacted>"))
    }
}
