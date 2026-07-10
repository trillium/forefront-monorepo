#if canImport(SwiftUI)
import SwiftUI
import ForefrontModels
import ForefrontQueue

/// The card deck: a stack of cards with the active one on top. Cards are FULLY
/// interactive (scroll + follow links); card-to-card navigation is via the deck
/// screen's Next/Previous controls — NOT a swipe, which would fight the card's
/// own scrolling. `zIndex` decreases front→back for the peek effect.
public struct CardStackView: View {
    @Bindable public var model: StackQueueModel

    /// How many cards behind the active one to render for the peek effect.
    private let peekDepth = 2

    public init(model: StackQueueModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            // Background peek cards (queue[0], queue[1]) — render bottom-up.
            ForEach(Array(model.queue.prefix(peekDepth).enumerated().reversed()), id: \.element.id) { pair in
                let depth = pair.offset + 1
                peekCard(card: pair.element, depth: depth)
            }

            // Active card on top — interactive. `.id(active.id)` ties it to the
            // card so a Next/Previous tap cross-fades to a fresh card (and reloads
            // its page). The card owns all touch, so nothing here intercepts it.
            if let active = model.active {
                CardView(card: active)
                    .overlay(alignment: .bottom) {
                        // ISC-152: "N of M" over the active card, from the model's
                        // generation counter + live deck size. Decorative — never
                        // intercepts touch on the web content (ISC-157).
                        DeckPositionIndicator(
                            position: model.deckPosition,
                            total: model.deckTotal
                        )
                    }
                    .zIndex(Double(peekDepth + 1))
                    .id(active.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else if model.queue.isEmpty {
                EmptyDeckView(
                    canReview: !model.history.isEmpty,
                    onReview: {
                        withAnimation(.spring(response: 0.35)) { model.restart() }
                    }
                )
            }
        }
        // ISC-155: haptic on a committed advance (from a Next tap). Triggered by
        // `seenThisGeneration`, which increments exactly once per advance — a
        // merge/arrival that grows the deck does NOT buzz.
        .sensoryFeedback(.impact(weight: .light), trigger: model.seenThisGeneration)
    }

    private func peekCard(card: Card, depth: Int) -> some View {
        CardView(card: card)
            .scaleEffect(1.0 - 0.05 * CGFloat(depth))
            .offset(y: 12 * CGFloat(depth))
            .zIndex(Double(peekDepth - depth))
            .allowsHitTesting(false)
    }
}

/// ISC-152: the "N of M" deck-position pill shown over the active card. Hidden
/// when there is no active card (`position == 0`) or a degenerate total. Styled
/// to match OfflineBanner / titleOverlay (thin material, capsule, footnote).
///
/// ISC-157: decorative only — `.allowsHitTesting(false)` so it can never
/// intercept a tap or drag destined for the web content beneath it.
struct DeckPositionIndicator: View {
    let position: Int
    let total: Int

    var body: some View {
        Group {
            if position > 0 && total > 0 {
                Text("\(position) of \(total)")
                    .font(.footnote.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 40)
            }
        }
        .allowsHitTesting(false)
    }
}

/// ISC-153: the masthead above the deck — a day-part greeting plus the live
/// remaining-card count, e.g. "Tuesday morning — 6 cards".
///
/// Day-part and weekday come from `Masthead` (pure logic in the Queue target);
/// the count is the deck's remaining count so it ticks live as cards are swiped
/// or arrive. Decorative header — never intercepts touches (ISC-157).
public struct MastheadView: View {
    let cardCount: Int
    /// Injectable for previews / tests; defaults to now.
    var date: Date = Date()

    public init(cardCount: Int, date: Date = Date()) {
        self.cardCount = cardCount
        self.date = date
    }

    private var masthead: Masthead {
        Masthead(date: date, cardCount: cardCount)
    }

    public var body: some View {
        // Hugs its content so the parent header can place the settings control
        // beside it without the greeting wrapping or the gear overlapping.
        VStack(alignment: .leading, spacing: 2) {
            Text(masthead.greeting)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(masthead.cardCountText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        // ISC-157: decorative header — does not intercept touches.
        .allowsHitTesting(false)
    }
}

struct EmptyDeckView: View {
    /// True when there are swiped cards to replay — gates the review button.
    var canReview: Bool = false
    /// Replays the deck from the top (StackQueueModel.restart()).
    var onReview: () -> Void = {}

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack.badge.checkmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("You're all caught up.")
                .font(.title3)
                .foregroundStyle(.secondary)
            if canReview {
                Button(action: onReview) {
                    Label("Review previous cards", systemImage: "arrow.counterclockwise")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding()
    }
}
#endif
