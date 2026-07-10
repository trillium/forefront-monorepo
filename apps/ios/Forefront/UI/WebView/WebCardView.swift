#if canImport(SwiftUI) && canImport(WebKit)
import SwiftUI

/// Single-card WebView wrapper. Each instance gets its own isolated data store
/// (ISC-69, ISC-70) and forwards the bearer token as `Authorization` on the
/// initial nav (ISC-72, D-06 in DECISIONS.md).
public struct WebCardView: View {
    public let url: URL
    @Environment(\.forefrontBearerToken) private var bearerToken: String?
    @State private var loadError: String?

    public init(url: URL) {
        self.url = url
    }

    public var body: some View {
        ZStack {
            WebViewRepresentable(url: url, bearerToken: bearerToken, onError: { msg in
                loadError = msg
            })
            // CRITICAL: tie the web view's identity to the URL. Without this,
            // SwiftUI reuses ONE WKWebView across every card (updateUIView is a
            // no-op), so all cards show whatever loaded first. `.id(url)` forces a
            // fresh, correctly-loaded web view per card (and its own isolated data
            // store — ISC-69).
            .id(url)
            if let loadError {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 32))
                    Text("Host unreachable")
                        .font(.headline)
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding()
            }
        }
    }
}

private struct ForefrontBearerTokenKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

public extension EnvironmentValues {
    /// Bearer token forwarded as `Authorization` on the WebView's initial nav.
    /// Set on `AppRoot` once the Keychain returns a value.
    var forefrontBearerToken: String? {
        get { self[ForefrontBearerTokenKey.self] }
        set { self[ForefrontBearerTokenKey.self] = newValue }
    }
}
#endif
