#if canImport(SwiftUI)
import SwiftUI
import ForefrontQueue

/// Decides onboarding-vs-deck based on Keychain token presence.
public struct AppRoot: View {
    @Environment(\.forefrontEnvironment) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasToken: Bool = false
    @State private var didFirstRefresh = false

    public init() {}

    public var body: some View {
        Group {
            if hasToken {
                DeckScreen()
                    .environment(\.forefrontBearerToken, env.bearerToken)
            } else {
                OnboardingView(onComplete: {
                    hasToken = true
                    Task {
                        env.rebuildNetworking()
                        await env.performRefresh(trigger: .automatic)
                    }
                })
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
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, hasToken else { return }
            Task { await env.performRefresh(trigger: .automatic) }
        }
    }
}

/// The deck screen: card stack + offline banner + settings entry.
public struct DeckScreen: View {
    @Environment(\.forefrontEnvironment) private var env
    @State private var showingSettings = false
    @State private var showingReauth = false

    public init() {}

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            // The cached deck stays rendered and swipeable behind every overlay,
            // including the re-scan prompt (ISC-150).
            CardStackView(model: env.queue)
                .ignoresSafeArea(edges: .horizontal)

            VStack {
                HStack {
                    Spacer()
                    Button { showingSettings = true } label: {
                        Image(systemName: "gear")
                            .padding(8)
                            .background(.thinMaterial, in: Circle())
                    }
                    .padding()
                }
                // F5: a 401 surfaces a VISIBLE re-scan prompt instead of a silent
                // offline state (ISC-149). It routes into the existing rescan
                // flow (OnboardingView) and preserves the cached deck (ISC-150).
                if env.needsReauth {
                    ReauthBanner(onRescan: { showingReauth = true })
                }
                Spacer()
                if env.isOffline {
                    OfflineBanner()
                }
            }
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

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section("Server") {
                    Button("Rescan QR (rotate token)") {
                        rescan = true
                    }
                }
                Section("Cache") {
                    Button("Clear cached deck") {
                        try? env.cache.clear()
                        didClear = true
                    }
                    .foregroundStyle(.red)
                }
                if didClear {
                    Text("Cache cleared.").font(.footnote).foregroundStyle(.secondary)
                }
            }
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
    }
}
#endif
