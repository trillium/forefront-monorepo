import Foundation
import ForefrontModels
import ForefrontStorage

/// A `ChatSyncing` conformer that serves a canned conversation for App Review —
/// reviewers cannot join the tailnet, so the real endpoints are unreachable in
/// review. Mirrors the deck's demo-mode seam (`DemoStackService`). Writes through
/// a real `ChatStoring` so the UI behaves identically to production; only the
/// "network" is faked.
///
/// The fixture exercises every v1 message kind so a reviewer sees the full
/// surface: a plain text exchange, an agent question with quick-replies, a
/// link-to-web-card (drive-to-form), and a reminder.
public actor DemoChatService: ChatSyncing {
    private let store: any ChatStoring
    private var seeded = false

    public init(store: any ChatStoring) {
        self.store = store
    }

    private static let demoChatId = "demo_agent"

    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        let base = Date()
        let chat = Chat(
            id: Self.demoChatId,
            title: "Your Agent",
            lastMessageAt: base,
            unreadCount: 1,
            lastMessagePreview: "Have you booked the flight yet?",
            topic: "reminders"
        )
        try? store.upsertChats([chat])
        let messages: [Message] = [
            Message(id: "demo_1", chatId: Self.demoChatId, role: .agent, kind: .text,
                    body: "Morning! Here's your day at a glance.",
                    createdAt: base.addingTimeInterval(-3600)),
            Message(id: "demo_2", chatId: Self.demoChatId, role: .user, kind: .text,
                    body: "Thanks — what's urgent?",
                    createdAt: base.addingTimeInterval(-3500)),
            Message(id: "demo_3", chatId: Self.demoChatId, role: .agent, kind: .question,
                    body: "Do you want me to draft the follow-up email?",
                    createdAt: base.addingTimeInterval(-3400),
                    quickReplies: ["Yes, draft it", "Not now"]),
            Message(id: "demo_4", chatId: Self.demoChatId, role: .agent, kind: .linkToWebCard,
                    body: "Fill in your travel details and I'll book it:",
                    createdAt: base.addingTimeInterval(-1800),
                    webCardURL: URL(string: "https://forefront.demo.local/forms/travel")),
            Message(id: "demo_5", chatId: Self.demoChatId, role: .agent, kind: .reminder,
                    body: "Have you booked the flight yet? It's due by Friday.",
                    createdAt: base,
                    quickReplies: ["Booked it", "Snooze 1h", "Not yet"],
                    reminder: ReminderInfo(dueAt: base.addingTimeInterval(48 * 3600)))
        ]
        try? store.upsertMessages(messages)
    }

    public func syncChats() async -> ChatSyncOutcome {
        seedIfNeeded()
        return .updated((try? store.loadChats()) ?? [])
    }

    public func syncMessages(chatId: String) async -> MessageSyncOutcome {
        seedIfNeeded()
        return .updated((try? store.loadMessages(chatId: chatId)) ?? [])
    }

    public func send(chatId: String, body: String, now: Date = Date()) async -> SendOutcome {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .queued(clientMessageId: "") }
        let cid = UUID().uuidString
        // In demo mode a "send" instantly succeeds against local storage.
        let sent = Message(
            id: "demo_sent_\(cid)", chatId: chatId, role: .user, kind: .text,
            body: trimmed, createdAt: now, clientMessageId: cid, status: .sent
        )
        try? store.upsertMessages([sent])
        return .sent(sent)
    }

    public func drainOutbox() async -> DrainOutcome {
        .drained(sent: 0, remaining: 0)
    }
}
