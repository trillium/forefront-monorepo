#if canImport(SwiftUI)
import SwiftUI
import ForefrontModels

/// The inbox: a list of chat threads with unread badges, newest-active first.
/// Tapping a row pushes the thread. Pull-to-refresh re-syncs the inbox and
/// drains any queued outbox messages.
public struct ChatListView: View {
    @Environment(\.forefrontChatEnvironment) private var chatEnv

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if chatEnv.chats.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Chats")
            .toolbar {
                if chatEnv.isOffline {
                    ToolbarItem(placement: .topBarTrailing) {
                        Label("Offline", systemImage: "wifi.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            await chatEnv.loadInbox()
            await chatEnv.drainOutbox()
        }
    }

    private var list: some View {
        List(chatEnv.chats) { chat in
            NavigationLink {
                ChatThreadView(chatId: chat.id, title: chat.title)
            } label: {
                ChatRow(chat: chat)
            }
        }
        .listStyle(.plain)
        .refreshable {
            await chatEnv.loadInbox()
            await chatEnv.drainOutbox()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No chats yet")
                .font(.headline)
            Text("Your agent will reach out here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One inbox row: title, last-message preview, relative time, unread badge.
struct ChatRow: View {
    let chat: Chat

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(chat.title)
                    .font(.headline)
                if let preview = chat.lastMessagePreview {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                // A compact, single-unit relative time computed at render — NOT
                // SwiftUI's `.relative` style, which ticks every second ("19 min,
                // 52 sec") and is distracting in a list.
                Text(shortRelative(chat.lastMessageAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if chat.unreadCount > 0 {
                    Text("\(chat.unreadCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Compact relative time — one unit, no seconds: "now", "5m", "3h", "2d".
    private func shortRelative(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
}
#endif
