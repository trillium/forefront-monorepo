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
                        .offset(x: dragOffset.width)
                        .rotationEffect(.degrees(Double(dragOffset.width) / 30))
                        .zIndex(Double(peekDepth + 1))
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    dragOffset = value.translation
                                }
                                .onEnded { value in
                                    let threshold = geo.size.width * advanceThreshold
                                    if abs(value.translation.width) > threshold {
                                        withAnimation(.easeOut(duration: 0.25)) {
                                            dragOffset = CGSize(
                                                width: value.translation.width > 0 ? geo.size.width * 1.5 : -geo.size.width * 1.5,
                                                height: 0
                                            )
                                        }
                                        Task { @MainActor in
                                            try? await Task.sleep(nanoseconds: 250_000_000)
                                            model.advance()
                                            dragOffset = .zero
                                        }
                                    } else {
                                        withAnimation(.spring(response: 0.3)) {
                                            dragOffset = .zero
                                        }
                                    }
                                }
                        )
                        .transition(.identity)
                } else if model.queue.isEmpty {
                    EmptyDeckView()
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
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(masthead.greeting)
                    .font(.title2.weight(.semibold))
                Text(masthead.cardCountText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        // ISC-157: decorative header — does not intercept touches.
        .allowsHitTesting(false)
    }
}

struct EmptyDeckView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.checkmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("You're all caught up.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
#endif
