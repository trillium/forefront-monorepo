#if canImport(SwiftUI)
import Foundation
import SwiftUI
import Observation
import ForefrontModels
import ForefrontStorage
import ForefrontNetworking

/// Observable chat state for the SwiftUI layer — the chat analogue of
/// `AppEnvironment`. One instance per app launch, injected into the environment.
/// Holds the chat store + service and the currently-loaded inbox / thread so the
/// views re-render via Observation (D-10) without polling.
///
/// Doctrine parity with `AppEnvironment`: no method throws to the view; every
/// failure degrades to a representable state (`isOffline`, `needsReauth`).
@MainActor
@Observable
public final class ChatEnvironment {
    public let store: any ChatStoring
    public private(set) var service: any ChatSyncing

    /// The inbox, most-recently-active first.
    public private(set) var chats: [Chat] = []
    /// Messages for the currently-open thread, oldest→newest.
    public private(set) var activeThread: [Message] = []
    /// The chat id whose thread is loaded into `activeThread`, if any.
    public private(set) var openChatId: String?

    public private(set) var isOffline: Bool = false
    /// Set when a chat call returns `.unauthorized`. The host app routes this into
    /// the same re-scan flow the deck uses; chat does not own onboarding UI.
    public var needsReauth: Bool = false

    /// Production initializer. Builds a `SQLiteChatStore` + `ChatService` from the
    /// app's existing `APIClient`. If the store can't open, falls back to an
    /// in-memory store so the app degrades to a session-only chat rather than
    /// crashing — chat is additive, not load-bearing for the deck.
    public init(api: APIClient, tokenStore: any TokenStoring) {
        let store: any ChatStoring
        do {
            store = try SQLiteChatStore()
        } catch {
            EventLog.shared.error("chat", "Chat store failed to open — using in-memory", detail: "\(error)")
            // In-memory can still fail only pathologically; if it does, the force
            // is acceptable because we have no persistence path left and chat is
            // opt-in from the tab bar.
            store = (try? SQLiteChatStore(inMemory: true)) ?? Self.mustOpenInMemory()
        }
        self.store = store
        self.service = ChatService(net: api, store: store, tokenStore: tokenStore)
    }

    /// Test / demo initializer with an injected service + store.
    public init(service: any ChatSyncing, store: any ChatStoring) {
        self.service = service
        self.store = store
    }

    private static func mustOpenInMemory() -> any ChatStoring {
        do { return try SQLiteChatStore(inMemory: true) }
        catch { preconditionFailure("SQLite in-memory store must open: \(error)") }
    }

    /// Swap the service (e.g. after a QR re-scan rebuilds networking, or to enter
    /// demo mode). Mirrors `AppEnvironment.rebuildNetworking`.
    public func rebind(service: any ChatSyncing) {
        self.service = service
    }

    // MARK: - Inbox

    public func loadInbox() async {
        let outcome = await service.syncChats()
        switch outcome {
        case .updated(let chats):
            isOffline = false
            self.chats = chats
        case .offline(let chats):
            isOffline = true
            self.chats = chats
        case .unauthorized:
            needsReauth = true
        }
    }

    // MARK: - Thread

    /// Open a thread: load its persisted messages immediately (optimistic), then
    /// sync new ones and mark it read.
    public func openThread(_ chatId: String) async {
        openChatId = chatId
        // Immediate: whatever we already hold, so the UI never shows a blank.
        activeThread = (try? store.loadMessages(chatId: chatId)) ?? []
        let outcome = await service.syncMessages(chatId: chatId)
        switch outcome {
        case .updated(let messages):
            isOffline = false
            activeThread = messages
        case .offline(let messages):
            isOffline = true
            activeThread = messages
        case .unauthorized:
            needsReauth = true
        }
        markReadAndRefreshBadges(chatId: chatId)
    }

    public func closeThread() {
        openChatId = nil
        activeThread = []
    }

    // MARK: - Send

    /// Send a message in the open thread. Optimistically appends the bubble, then
    /// reconciles with the server outcome.
    public func send(_ body: String) async {
        guard let chatId = openChatId else { return }
        let outcome = await service.send(chatId: chatId, body: body, now: Date())
        switch outcome {
        case .sent:
            isOffline = false
            activeThread = (try? store.loadMessages(chatId: chatId)) ?? activeThread
        case .queued:
            // The optimistic row persisted with a .failed badge; a queued send
            // means the network is (at least momentarily) unreachable.
            isOffline = true
            activeThread = (try? store.loadMessages(chatId: chatId)) ?? activeThread
        case .unauthorized:
            needsReauth = true
        }
    }

    /// A quick-reply tap posts its label as a normal user message (contract §10).
    public func sendQuickReply(_ label: String) async {
        await send(label)
    }

    // MARK: - Outbox drain

    /// Flush the outbox (call on reconnect / foreground). Refreshes the open
    /// thread afterward so reconciled rows appear.
    public func drainOutbox() async {
        let outcome = await service.drainOutbox()
        if case .unauthorized = outcome { needsReauth = true }
        if let chatId = openChatId {
            activeThread = (try? store.loadMessages(chatId: chatId)) ?? activeThread
        }
        await loadInbox()
    }

    // MARK: - Helpers

    private func markReadAndRefreshBadges(chatId: String) {
        try? store.markRead(chatId: chatId, upTo: Date())
        // Recompute inbox badges from the store so the tab badge updates.
        self.chats = (try? store.loadChats()) ?? self.chats
    }

    /// Total unread across all chats — drives the Chats tab-bar badge.
    public var totalUnread: Int {
        chats.reduce(0) { $0 + $1.unreadCount }
    }
}

private struct ChatEnvironmentKey: EnvironmentKey {
    @MainActor static var defaultValue: ChatEnvironment { ChatEnvironment.shared }
}

public extension ChatEnvironment {
    /// Built lazily from the deck's shared `AppEnvironment` API client.
    @MainActor static let shared = ChatEnvironment(
        api: AppEnvironment.shared.api,
        tokenStore: AppEnvironment.shared.keychain
    )
}

public extension EnvironmentValues {
    var forefrontChatEnvironment: ChatEnvironment {
        get { self[ChatEnvironmentKey.self] }
        set { self[ChatEnvironmentKey.self] = newValue }
    }
}
#endif
