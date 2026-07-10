#if canImport(SwiftUI)
import SwiftUI
import ForefrontModels

/// A single conversation: scrollable message list + composer. Quick-reply taps
/// post back as user messages; a link-to-web-card opens the existing WebView
/// surface in a sheet (drive-to-input). Auto-scrolls to the newest message.
public struct ChatThreadView: View {
    @Environment(\.forefrontChatEnvironment) private var chatEnv
    @Environment(\.forefrontBearerToken) private var bearerToken: String?

    public let chatId: String
    public let title: String

    @State private var composerText = ""
    @State private var webCardURL: URL?

    public init(chatId: String, title: String) {
        self.chatId = chatId
        self.title = title
    }

    public var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            ChatComposerView(text: $composerText) { body in
                Task { await chatEnv.send(body) }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: chatId) {
            await chatEnv.openThread(chatId)
        }
        .onDisappear {
            chatEnv.closeThread()
        }
        .sheet(item: $webCardURL) { url in
            NavigationStack {
                WebCardView(url: url)
                    .environment(\.forefrontBearerToken, bearerToken)
                    .navigationTitle("Form")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { webCardURL = nil }
                        }
                    }
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(chatEnv.activeThread) { message in
                        MessageBubbleView(
                            message: message,
                            onQuickReply: { label in
                                Task { await chatEnv.sendQuickReply(label) }
                            },
                            onOpenWebCard: { url in
                                webCardURL = url
                            }
                        )
                        .id(message.id)
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: chatEnv.activeThread.count) { _, _ in
                if let last = chatEnv.activeThread.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

// `URL` is made `Identifiable` (by its own string) so it can drive `.sheet(item:)`.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
#endif
