#if canImport(SwiftUI)
import SwiftUI
import ForefrontModels

/// A single card: WebView body + title overlay + offline-aware loading state.
public struct CardView: View {
    public let card: Card
    @Environment(\.colorScheme) private var colorScheme

    public init(card: Card) {
        self.card = card
    }

    public var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(colorScheme == .dark ? Color.black : Color.white)
                .shadow(color: .black.opacity(0.15), radius: 16, x: 0, y: 6)

            WebCardView(url: card.url)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            titleOverlay
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 24)
    }

    private var titleOverlay: some View {
        HStack {
            Text(card.title)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
    }
}

/// Visible only when we're rendering from cache without a confirmed live connection.
public struct OfflineBanner: View {
    public init() {}
    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.exclamationmark")
            Text("Offline — showing cached deck")
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .padding(.bottom, 24)
        // ISC-97: indicator does not block input.
        .allowsHitTesting(false)
    }
}
#endif
