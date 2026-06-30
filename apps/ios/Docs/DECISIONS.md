# Forefront Decisions

> Architectural calls made at scaffold time. Each decision names what was chosen, the alternative considered, and the rationale. Mirrors the `## Decisions` section of `ISA.md` — that section is the source of truth; this file is a presentation copy for browsing.

| # | Decision | Alternative | Why |
| --- | --- | --- | --- |
| D-01 | **Minimum iOS = 17.0** | iOS 18.0 (native SwiftUI `WebView`) | iOS 17 installed-base reach is material as of mid-2026. One `UIViewRepresentable` wrapper is cheap. |
| D-02 | **`WKWebView` via `UIViewRepresentable`** | Native SwiftUI `WebView` (iOS 18+) | Direct consequence of D-01. Single wrapper file, well-trodden pattern, App-Review safe. |
| D-03 | **Build a custom card-stack** | Adopt a SwiftUI card-stack library | The queue/flush/prepend semantics are subtle (active card is sacred). A library wrapper would obscure them. Adopt later only as a layout helper if gesture math gets gnarly. |
| D-04 | **AVFoundation for QR scanning** | `VisionKit` `DataScannerViewController` (iOS 16+) | AVFoundation works iOS 10+, has zero new entitlement asks, and the QR-only scope doesn't justify VisionKit's larger surface. |
| D-05 | **Isolated `WKWebsiteDataStore` per card** | Single shared data store | Default to isolation; cross-card session sharing only if a future card explicitly requires it. Lowers blast radius of a misbehaving card. |
| D-06 | **Forward Bearer token as `Authorization` on initial WebView nav** | Cookie-based session handoff | Backend pages need to know who's viewing them; forwarding the token avoids a second handshake. Documented in `BACKEND_CONTRACT.md` so the backend can validate. |
| D-07 | **Cache under `Application Support/forefront/`** | `Documents/` | `Documents/` would back up to iCloud and surface in Files.app — wrong for a transient deck cache. |
| D-08 | **Source-tree scaffold, no committed `.xcodeproj`** | Generate `pbxproj` by hand | `pbxproj` is fragile to hand-edit. Package-style source layout + README "open in Xcode" steps preserve buildability without committing brittle project state. |
| D-09 | **Compile verification deferred to first Xcode open** | Try to drive `xcodebuild` from this environment | Xcode toolchain not available here. Scaffold is grep-verifiable; runtime-only ISCs are tagged `[DEFERRED-VERIFY]` and listed in `BUILD_PLAN.md`. |
| D-10 | **`@Observable` (Observation framework), not Combine `@Published`** | Combine + `ObservableObject` | iOS 17 ships Observation; new code uses it. Removes a Combine dependency surface. |
| D-11 | **Long-lived token in Keychain (`kSecAttrAccessibleAfterFirstUnlock`)** | Short-lived token with refresh flow | The spec mandates long-lived. Mitigation: never log, easy re-scan, scope minimally server-side. |
