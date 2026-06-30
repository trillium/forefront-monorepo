#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import SwiftUI
import WebKit

/// UIViewRepresentable wrapper around WKWebView. Per-card isolated data store.
/// No JS → native bridge in v1 (ISC-74). No file URL access (ISC-73).
public struct WebViewRepresentable: UIViewRepresentable {
    public let url: URL
    public let bearerToken: String?
    public let onError: (String) -> Void

    public init(url: URL, bearerToken: String?, onError: @escaping (String) -> Void) {
        self.url = url
        self.bearerToken = bearerToken
        self.onError = onError
    }

    public func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // ISC-69: per-card isolated data store. Cards do not share cookies.
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // No script message handlers — ISC-74.
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsLinkPreview = false
        // ISC-73: do NOT enable arbitrary file URL access. The default is false.
        var request = URLRequest(url: url)
        if let bearerToken, !bearerToken.isEmpty {
            // ISC-72.
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        webView.load(request)
        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {
        // The card identity drives view recreation — if `url` changes, the
        // representable is recreated rather than re-loaded, by design.
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onError: onError)
    }

    public final class Coordinator: NSObject, WKNavigationDelegate {
        let onError: (String) -> Void
        init(onError: @escaping (String) -> Void) { self.onError = onError }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handle(error)
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handle(error)
        }

        private func handle(_ error: Error) {
            let nsError = error as NSError
            // ISC-71: surface host-unreachable / timeout to the overlay.
            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorCannotConnectToHost
                || nsError.code == NSURLErrorTimedOut
                || nsError.code == NSURLErrorCannotFindHost
                || nsError.code == NSURLErrorNotConnectedToInternet {
                onError(nsError.localizedDescription)
            } else {
                onError(nsError.localizedDescription)
            }
        }
    }
}
#endif
