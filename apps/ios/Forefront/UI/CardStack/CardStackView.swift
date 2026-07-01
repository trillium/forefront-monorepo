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
            }
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
