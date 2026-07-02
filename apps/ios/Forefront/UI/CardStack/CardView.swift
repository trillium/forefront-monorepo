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
///
/// ISC-154: when a `lastRefreshed` time is known, a staleness line ("as of 9:12")
/// is shown beneath the offline text so the user knows how old the cached deck is.
public struct OfflineBanner: View {
    /// The time the cached deck was last successfully refreshed. `nil` hides the
    /// staleness line (e.g. a first run that never reached the server).
    public let lastRefreshed: Date?

    public init(lastRefreshed: Date? = nil) {
        self.lastRefreshed = lastRefreshed
    }

    /// Short local time-of-day, e.g. "9:12 AM" — hour+minute only. Formatted at
    /// render time so it honors the device's locale + 12/24h preference.
    private var asOfText: String? {
        guard let lastRefreshed else { return nil }
        return lastRefreshed.formatted(date: .omitted, time: .shortened)
    }

    public var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "wifi.exclamationmark")
                Text("Offline — showing cached deck")
            }
            .font(.footnote)
            // ISC-154: staleness line — how old is this cached deck?
            if let asOfText {
                Text("as of \(asOfText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .padding(.bottom, 24)
        // ISC-97 / ISC-157: indicator does not block input.
        .allowsHitTesting(false)
    }
}
#endif
