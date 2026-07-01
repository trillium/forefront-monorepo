#if canImport(SwiftUI)
import SwiftUI
import ForefrontQueue

/// Decides onboarding-vs-deck based on Keychain token presence.
public struct AppRoot: View {
    @Environment(\.forefrontEnvironment) private var env
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
                        await env.performRefresh()
                    }
                })
            }
        }
        .task {
            hasToken = (env.bearerToken?.isEmpty == false)
            if hasToken && !didFirstRefresh {
                didFirstRefresh = true
                await env.performRefresh()
            }
        }
    }
}

/// The deck screen: card stack + offline banner + settings entry.
public struct DeckScreen: View {
    @Environment(\.forefrontEnvironment) private var env
    @State private var showingSettings = false

    public init() {}

    public var body: some View {
        ZStack(alignment: .topTrailing) {
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
                Spacer()
                if env.isOffline {
                    OfflineBanner()
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .refreshable {
            await env.performRefresh()
        }
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
