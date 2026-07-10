#if canImport(SwiftUI)
import SwiftUI
import UIKit
import Combine
import ForefrontModels
import ForefrontQueue

/// Decides onboarding-vs-app based on Keychain token presence. When authed the
/// app is a tab bar: **Deck** (the reader) and **Chats** (the two-way agent
/// channel). The two coexist (scope §1 / D-14).
public struct AppRoot: View {
    @Environment(\.forefrontEnvironment) private var env
    @Environment(\.forefrontChatEnvironment) private var chatEnv
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasToken: Bool = false
    @State private var didFirstRefresh = false
    @State private var selectedTab: RootTab = .deck

    public init() {}

    public var body: some View {
        Group {
            if hasToken {
                MainTabView(selectedTab: $selectedTab)
                    .environment(\.forefrontBearerToken, env.bearerToken)
            } else {
                OnboardingView(
                    onComplete: {
                        hasToken = true
                        Task {
                            env.rebuildNetworking()
                            await env.performRefresh(trigger: .automatic)
                        }
                    }
                )
            }
        }
        .task {
            hasToken = (env.bearerToken?.isEmpty == false)
            if hasToken && !didFirstRefresh {
                didFirstRefresh = true
                await env.performRefresh(trigger: .automatic)
            }
        }
        // ISC-148: a scenePhase transition to .active fires a throttled refresh.
        // .automatic means F2's 30s guard suppresses rapid re-foregrounds; the
        // outcome routes through queue.adopt(...) — merge semantics only, so the
        // active card is never replaced by a foreground refresh (ISC-151).
        //
        // A foreground also drains the chat outbox: messages composed off-tailnet
        // send on reconnect.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, hasToken else { return }
            Task { await env.performRefresh(trigger: .automatic) }
            Task { await chatEnv.drainOutbox() }
        }
        // A deep-link from an actionable reminder push selects the Chats tab.
        .onReceive(NotificationCenter.default.publisher(for: .forefrontOpenChat)) { note in
            guard hasToken else { return }
            selectedTab = .chats
            if let chatId = note.userInfo?["chatId"] as? String {
                Task { await chatEnv.openThread(chatId) }
            }
        }
    }
}

/// The two top-level surfaces.
public enum RootTab: Hashable, Sendable {
    case deck
    case chats
}

/// Broadcast when a notification tap should route into a chat. Posted by the
/// AppDelegate's notification handlers; observed by `AppRoot` (deep-link, §11).
public extension Notification.Name {
    static let forefrontOpenChat = Notification.Name("forefront.openChat")
}

/// Deck | Chats tab bar. The Chats tab carries an unread badge driven by the
/// chat environment's total unread.
public struct MainTabView: View {
    @Environment(\.forefrontChatEnvironment) private var chatEnv
    @Binding var selectedTab: RootTab

    public var body: some View {
        TabView(selection: $selectedTab) {
            DeckScreen()
                .tabItem { Label("Deck", systemImage: "rectangle.stack") }
                .tag(RootTab.deck)

            ChatListView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .tag(RootTab.chats)
                .badge(chatEnv.totalUnread)
        }
        .task {
            // Warm the inbox so the badge is correct before the user opens Chats.
            await chatEnv.loadInbox()
        }
    }
}

/// The deck screen: card stack + offline banner + settings entry.
public struct DeckScreen: View {
    @Environment(\.forefrontEnvironment) private var env
    @State private var showingSettings = false
    @State private var showingReauth = false
    @State private var now = Date()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // ISC-153: header bar — day-part greeting + live count on the left,
            // last-refreshed + settings on the right. Kept in normal layout flow
            // ABOVE the deck so it never overlaps the active card. Count is the
            // queue's remainingCount so it ticks as cards are swiped (ISC-156).
            HStack(alignment: .top) {
                MastheadView(cardCount: env.queue.remainingCount)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    if let lastRefreshed = env.lastRefreshed {
                        Text(relativeTime(from: lastRefreshed, to: now))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button { showingSettings = true } label: {
                        Image(systemName: "gear")
                            .padding(8)
                            .background(.thinMaterial, in: Circle())
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            // F5: a 401 surfaces a VISIBLE re-scan prompt instead of a silent
            // offline state (ISC-149). Routes into the rescan flow (OnboardingView)
            // and preserves the cached deck (ISC-150).
            if env.needsReauth {
                ReauthBanner(onRescan: { showingReauth = true })
                    .padding(.top, 4)
            }

            // The deck fills the space below the header. The cached deck stays
            // rendered and swipeable behind the offline banner (ISC-150).
            ZStack(alignment: .bottom) {
                CardStackView(model: env.queue)
                    .ignoresSafeArea(edges: .horizontal)
                if env.isOffline {
                    // ISC-154: pass the last-refreshed time so the banner can show
                    // an "as of HH:mm" staleness line.
                    OfflineBanner(lastRefreshed: env.lastRefreshed)
                }
            }
        }
        // Deck navigation flanking the Deck|Chats tab bar: cards are interactive
        // (scroll/links), so card-to-card movement is by these buttons, not a
        // swipe. Previous = undo (back), Next = advance.
        .overlay(alignment: .bottom) {
            HStack {
                deckNavButton(system: "chevron.backward", disabled: env.queue.history.isEmpty) {
                    withAnimation(.easeInOut(duration: 0.22)) { env.queue.undo() }
                }
                Spacer()
                deckNavButton(system: "chevron.forward", disabled: env.queue.active == nil) {
                    withAnimation(.easeInOut(duration: 0.22)) { env.queue.advance() }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingReauth) {
            // The existing rescan flow: scan a fresh QR, write the new token +
            // endpoints, rebuild networking, refresh. On success the 401 state
            // clears. The on-disk cache is never touched here.
            OnboardingView(onComplete: {
                showingReauth = false
                env.clearReauth()
                env.rebuildNetworking()
                Task { await env.performRefresh(trigger: .userInitiated) }
            })
        }
        .refreshable {
            // Pull-to-refresh is user-initiated — bypasses the 30s throttle.
            await env.performRefresh(trigger: .userInitiated)
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                now = Date()
            }
        }
    }

    private func relativeTime(from past: Date, to present: Date) -> String {
        let interval = present.timeIntervalSince(past)
        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }

    /// A circular deck-navigation button (Previous / Next), dimmed when disabled.
    @ViewBuilder
    private func deckNavButton(
        system: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.title3.weight(.semibold))
                .frame(width: 50, height: 50)
                .background(.thinMaterial, in: Circle())
        }
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }
}

/// F5: shown on the deck when a refresh returns `.unauthorized`. Visible, not
/// silent. Only its button intercepts touches — the deck behind it stays
/// swipeable (ISC-150).
public struct ReauthBanner: View {
    public let onRescan: () -> Void
    public init(onRescan: @escaping () -> Void) { self.onRescan = onRescan }

    public var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                Text("Session expired — rescan the QR from your server")
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
            }
            Button(action: onRescan) {
                Label("Rescan QR", systemImage: "qrcode.viewfinder")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal)
        .padding(.top, 4)
    }
}

/// Minimal settings: re-scan QR (rotates token) + clear cache.
public struct SettingsView: View {
    @Environment(\.forefrontEnvironment) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var rescan = false
    @State private var didClear = false
    @State private var didCopyDebug = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section("Server") {
                    Button("Rescan QR (rotate token)") {
                        EventLog.shared.info("ui", "User started QR re-scan")
                        rescan = true
                    }
                }
                Section("Cache") {
                    Button("Clear cached deck") {
                        try? env.cache.clear()
                        EventLog.shared.info("cache", "User cleared cached deck")
                        didClear = true
                    }
                    .foregroundStyle(.red)
                }
                if didClear {
                    Text("Cache cleared.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Debug") {
                    Button("Copy debug state") {
                        UIPasteboard.general.string = debugStateDump()
                        didCopyDebug = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            didCopyDebug = false
                        }
                    }
                    if didCopyDebug {
                        Text("Debug state + event log copied.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                EventLogSection()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $rescan) {
                OnboardingView(onComplete: {
                    rescan = false
                    env.rebuildNetworking()
                    Task { await env.performRefresh() }
                })
            }
        }
        .presentationDetents([.large])
    }

    /// The full copyable diagnostic: current state snapshot + the whole event
    /// log. This is what "Copy debug state" now yields — enough to reconstruct
    /// what happened, not just where things ended up.
    private func debugStateDump() -> String {
        let last = env.lastRefreshed.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "never"
        let tokenState: String
        if let token = env.bearerToken, !token.isEmpty {
            tokenState = "present (\(token.count) chars)"
        } else {
            tokenState = "(none)"
        }
        return """
        === Forefront Debug State ===
        Endpoint: \(env.rotator.primary.absoluteString)
        Endpoints configured: \(env.rotator.count)
        Token: \(tokenState)
        Offline: \(env.isOffline ? "YES" : "NO")
        Needs Reauth: \(env.needsReauth ? "YES" : "NO")
        Last refreshed: \(last)
        Cards in deck: \(env.queue.remainingCount)

        === Event Log (oldest → newest) ===
        \(EventLog.shared.formatted())
        """
    }
}

/// Live, in-app view of the diagnostic breadcrumb trail. Polls the shared
/// `EventLog` on a 1s timer while Settings is open so new events surface without
/// leaving the screen — the record of "what the app did", including the failures
/// that never reached the server.
private struct EventLogSection: View {
    @State private var events: [LogEvent] = EventLog.shared.snapshot()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            if events.isEmpty {
                Text("No events recorded yet.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(event.message)
                                .font(.footnote.weight(.medium))
                            Spacer()
                            Text(event.time, style: .time)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if let detail = event.detail {
                            Text("\(event.category) — \(detail)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(event.category)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(color(for: event.level).opacity(0.10))
                }
            }
        } header: {
            HStack {
                Text("Recent Events")
                Spacer()
                Button("Clear") {
                    EventLog.shared.clear()
                    events = []
                }
                .font(.caption)
            }
        }
        .onReceive(ticker) { _ in events = EventLog.shared.snapshot() }
    }

    private func color(for level: LogEvent.Level) -> Color {
        switch level {
        case .info: return .blue
        case .success: return .green
        case .warn: return .orange
        case .error: return .red
        }
    }
}
#endif
