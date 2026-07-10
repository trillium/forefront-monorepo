import Foundation
import ForefrontModels

/// Chat endpoints on `APIClient`, reusing the same `EndpointRotator` fallback,
/// Bearer auth, 5xx-retry, and typed-error surface as the deck endpoints
/// (contract §8–§10). Kept in a separate file so the deck client stays focused.
public extension APIClient {

    /// `GET /chats` — the inbox. Backend order is authoritative.
    func fetchChats() async throws -> ChatList {
        try await rotator.withFallback { base in
            let url = base.appendingPathComponent("chats")
            let data = try await self.get(url)
            do {
                return try self.decoder.decode(ChatList.self, from: data)
            } catch {
                throw ForefrontNetworkError.decodingFailed(String(describing: error))
            }
        }
    }

    /// `GET /chats/{id}/messages?since=<cursor>` — incremental. `since` is opaque;
    /// omitted on first fetch to get the most recent page.
    func fetchMessages(chatId: String, since cursor: String?) async throws -> MessagePage {
        try await rotator.withFallback { base in
            var comps = URLComponents(
                url: base.appendingPathComponent("chats/\(chatId)/messages"),
                resolvingAgainstBaseURL: false
            )
            if let cursor, !cursor.isEmpty {
                comps?.queryItems = [URLQueryItem(name: "since", value: cursor)]
            }
            guard let url = comps?.url else {
                throw ForefrontNetworkError.transport("Could not build messages URL for chat \(chatId)")
            }
            let data = try await self.get(url)
            do {
                return try self.decoder.decode(MessagePage.self, from: data)
            } catch {
                throw ForefrontNetworkError.decodingFailed(String(describing: error))
            }
        }
    }

    /// `POST /chats/{id}/messages` — idempotent send. The backend dedups on
    /// `(chatId, clientMessageId)`, so a retry with the same body can never
    /// duplicate server-side. Returns the canonical server message.
    func sendMessage(chatId: String, outgoing: OutgoingMessage) async throws -> Message {
        try await rotator.withFallback { base in
            let url = base.appendingPathComponent("chats/\(chatId)/messages")
            var req = try await self.authedRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            req.httpBody = try encoder.encode(outgoing)
            let data = try await self.perform(req)
            do {
                return try self.decoder.decode(Message.self, from: data)
            } catch {
                throw ForefrontNetworkError.decodingFailed(String(describing: error))
            }
        }
    }
}
