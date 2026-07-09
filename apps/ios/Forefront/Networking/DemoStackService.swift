import Foundation
import ForefrontModels

/// Serves a bundled fixture deck for App Review demo mode.
/// Zero network calls; never touches the real stack.json cache. (ISC-163, ISC-167)
public actor DemoStackService: StackRefreshing {
    private let deck: CardStack = {
        let cards: [Card] = [
            Card(
                id: "demo-1",
                url: URL(string: "https://example.com")!,
                title: "Example — Forefront Demo",
                priority: 0,
                createdAt: Date(),
                updatedAt: Date()
            ),
            Card(
                id: "demo-2",
                url: URL(string: "https://www.apple.com/developer/")!,
                title: "Apple Developer",
                priority: 1,
                createdAt: Date(),
                updatedAt: Date()
            ),
            Card(
                id: "demo-3",
                url: URL(string: "https://developer.apple.com/documentation/swiftui/")!,
                title: "SwiftUI Documentation",
                priority: 2,
                createdAt: Date(),
                updatedAt: Date()
            ),
        ]
        return CardStack(version: StackVersion(integer: 1), cards: cards)
    }()

    public init() {}

    public func refresh(trigger: RefreshTrigger, now: Date) async -> RefreshOutcome {
        // Always return the fixture deck; no network, no cache writes. (ISC-167)
        return .updated(deck)
    }
}
