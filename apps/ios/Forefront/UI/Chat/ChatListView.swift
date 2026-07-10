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
                Text(chat.lastMessageAt, style: .relative)
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
}
#endif
