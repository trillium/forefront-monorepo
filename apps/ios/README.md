# Forefront

Native iOS card-stack reader for an AI-curated, self-hosted page feed. The backend decides what the user should see and the order; this app is the eye.

## Architecture (one paragraph)

The backend exposes `/stack/last-updated` (cheap version probe) and `/stack` (the ordered deck). The client polls on launch, fetches only when the version changed, caches the result on disk, and renders each card as a `WKWebView` of its `url`. New cards arriving via fetch or silent APNs push slide into the back of the queue and never replace the card the user is currently looking at. Endpoints are tried in order with fallback. Auth is a long-lived Bearer token scanned in via QR and stored in Keychain.

## Layout

```
forefront/
├── Forefront/
│   ├── App/             # @main entry, AppRoot, AppEnvironment, AppDelegate
│   ├── Models/          # Card, CardStack, QRPayload, StackVersion, Endpoint
│   ├── Networking/      # APIClient, EndpointRotator, StackService, PushRegistrar
│   ├── Storage/         # KeychainStore, CacheStore, AppConfigStore
│   ├── UI/
│   │   ├── CardStack/   # CardStackView, CardView, StackQueueModel
│   │   ├── Onboarding/  # QRScanView, QRScannerController, OnboardingView
│   │   └── WebView/     # WebCardView, WebViewRepresentable
│   ├── Util/            # Logger, retry helpers
│   └── Resources/       # Info.plist template, entitlements template
├── ForefrontTests/      # XCTest suites + JSON fixtures
├── Docs/                # BACKEND_CONTRACT, BUILD_PLAN, DECISIONS
├── Package.swift        # library targets (Models / Storage / Networking) for swift test
├── ISA.md               # ideal-state articulation — project's source of truth
└── README.md
```

## Open in Xcode (first-time setup)

The scaffold ships as a Swift source tree, not a pre-baked `.xcodeproj` (Apple's `pbxproj` format is brittle to hand-edit). Wrap it in an Xcode App target once:

1. `xed ~/code/forefront` (opens the folder in Xcode).
2. **File → New → Project → iOS → App.**
   - Product name: `Forefront`
   - Bundle identifier: `com.trilliumsmith.forefront`
   - Interface: SwiftUI, Language: Swift, Minimum deployment: **iOS 17.0**.
3. **Delete** the auto-generated `ContentView.swift` and `ForefrontApp.swift`.
4. **Drag** `Forefront/` (the source folder) into the project navigator. "Create groups", target = the new app.
5. Set the app's `Info.plist` to `Forefront/Resources/Info.plist` (or merge keys).
6. Set the app's entitlements file to `Forefront/Resources/Forefront.entitlements`.
7. **Signing & Capabilities → +Capability → Push Notifications**.
8. **Signing & Capabilities → Background Modes → Remote notifications**.
9. Build (⌘B). Run on an iPhone connected to the same Tailscale tailnet as the backend.

## Prerequisites for the user (App Store narrative)

- The device must be **signed in to the same Tailscale tailnet** that hosts the backend, with the Tailscale app installed and connected. Card URLs only resolve inside the tailnet.
- A **QR code from the backend** containing the endpoint list + auth token. Without it the app shows an onboarding screen with a scan button.

## Why this is not just a web wrapper (App Store Guideline 4.2)

- **QR onboarding** is a native flow (camera + Keychain + AVFoundation), not something a web wrapper does.
- **Native swipeable card-stack** with gesture-driven advance, zIndex layering, and a queue model that protects the active card.
- **Offline cache** of the full deck — viewable with no connection.
- **Silent push** + background refresh hookup.
- **Endpoint fallback rotation** transparent to the user.
- These are the four native surfaces; App Review submission notes should call them out.

## Tests

```bash
cd ~/code/forefront
swift test    # runs ForefrontTests; covers Models, StackQueueModel, EndpointRotator, CacheStore
```

The UI layer is not covered by `swift test` (it imports `SwiftUI` and `WebKit`); UI tests run under Xcode against an iOS simulator.

## Source of truth

`ISA.md` at the repo root is the project's ideal-state articulation: problem, vision, constraints, criteria (132 ISCs), test strategy, features, decisions, changelog, verification. Iterate the project by iterating that file.
