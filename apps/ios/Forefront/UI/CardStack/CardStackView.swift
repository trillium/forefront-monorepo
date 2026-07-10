#if canImport(SwiftUI)
import SwiftUI
import ForefrontModels
import ForefrontQueue

/// The swipeable deck. ZStack of cards with `zIndex` decreasing from front to back.
/// A horizontal drag past the threshold advances to the next card.
public struct CardStackView: View {
    @Bindable public var model: StackQueueModel
    @State private var dragOffset: CGSize = .zero

    /// Fraction of screen width that counts as a "completed" swipe.
    private let advanceThreshold: CGFloat = 0.25
    /// How many cards behind the active one to render for the peek effect.
    private let peekDepth = 2

    public init(model: StackQueueModel) {
        self.model = model
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background peek cards (queue[0], queue[1]) — render bottom-up.
                ForEach(Array(model.queue.prefix(peekDepth).enumerated().reversed()), id: \.element.id) { pair in
                    let depth = pair.offset + 1
                    peekCard(card: pair.element, depth: depth)
                }

                // Active card on top.
                if let active = model.active {
                    CardView(card: active)
                        .overlay(alignment: .bottom) {
                            // ISC-152: "N of M" over the active card. Derived from
                            // the model's generation counter (deckPosition) and
                            // the live deck size (deckTotal). Purely decorative —
                            // never intercepts touch on the web content (ISC-157).
                            DeckPositionIndicator(
                                position: model.deckPosition,
                                total: model.deckTotal
                            )
                        }
                        // Track the finger in BOTH axes (not just x) and tilt as it
                        // moves — the physical "card in hand" feel.
                        .offset(dragOffset)
                        .rotationEffect(.degrees(Double(dragOffset.width) / 16))
                        .zIndex(Double(peekDepth + 1))
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    dragOffset = value.translation
                                }
                                .onEnded { value in
                                    // Tinder/Bumble feel: commit on DISTANCE *or* VELOCITY.
                                    // `predictedEndTranslation` projects where a flick would
                                    // land, so a fast short flick throws the card the same as
                                    // a slow long drag — a slow under-threshold drag just
                                    // rubber-bands back and stays put.
                                    let width = geo.size.width
                                    let distance = value.translation.width
                                    let projected = value.predictedEndTranslation.width
                                    let committed = abs(distance) > width * advanceThreshold
                                        || abs(projected) > width * 0.5
                                    if committed {
                                        let dir: CGFloat = distance > 0 ? 1 : -1
                                        // Fly off ALONG the finger's trajectory (keep the
                                        // vertical component), not dead-straight sideways.
                                        withAnimation(.easeOut(duration: 0.22)) {
                                            dragOffset = CGSize(
                                                width: dir * width * 1.6,
                                                height: value.translation.height
                                                    + value.predictedEndTranslation.height * 0.25
                                            )
                                        }
                                        Task { @MainActor in
                                            try? await Task.sleep(nanoseconds: 200_000_000)
                                            model.advance()
                                            dragOffset = .zero
                                        }
                                    } else {
                                        // Rubber-band back to rest — and stay there.
                                        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.72)) {
                                            dragOffset = .zero
                                        }
                                    }
                                }
                        )
                        .transition(.identity)
                } else if model.queue.isEmpty {
                    EmptyDeckView(
                        canReview: !model.history.isEmpty,
                        onReview: {
                            withAnimation(.spring(response: 0.35)) { model.restart() }
                        }
                    )
                }

                // ISC-158: undo button — visible when swipe history exists.
                if !model.history.isEmpty {
                    VStack {
                        Spacer()
                        HStack {
                            Button {
                                withAnimation(.spring(response: 0.3)) { model.undo() }
                            } label: {
                                Image(systemName: "arrow.uturn.backward.circle.fill")
                                    .font(.system(size: 36))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 24)
                                    .padding(.bottom, 40)
                            }
                            Spacer()
                        }
                    }
                    .zIndex(Double(peekDepth + 2))
                }
            }
            // ISC-155: fire haptic feedback on card advance. Uses the iOS 17
            // SwiftUI `.sensoryFeedback` API (preferred over UIImpactFeedback-
            // Generator). Triggered by `seenThisGeneration`, which increments
            // exactly once per committed advance — so a merge/arrival that grows
            // the deck does NOT buzz, only a real swipe does.
            .sensoryFeedback(.impact(weight: .light), trigger: model.seenThisGeneration)
        }
    }

    private func peekCard(card: Card, depth: Int) -> some View {
        // As the top card is dragged away, the NEAREST peek card (depth 1) rises
        // toward the active slot — the deck "comes forward" (Tinder feel). Deeper
        // cards hold their resting offset.
        let progress = depth == 1 ? min(abs(dragOffset.width) / 120, 1) : 0
        let scale = (1.0 - 0.05 * CGFloat(depth)) + 0.05 * progress
        let yOffset = 12 * CGFloat(depth) - 12 * progress
        return CardView(card: card)
            .scaleEffect(scale)
            .offset(y: yOffset)
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
