---
project: forefront
task: scaffold-forefront-ios-card-stack-viewer
slug: forefront
effort: E4
phase: observe
progress: 0/132
mode: build
started: 2026-06-30
updated: 2026-06-30
---

# Forefront — Project ISA

## Problem

The user has many self-hosted, AI-curated pages (dashboards, briefings, notes) on a Tailscale network. There is no phone-native surface that fetches the *current most-important page first*, lets the user swipe past it, and never makes them wait on the network. Existing options (Safari bookmarks, RSS, generic webview wrappers) require the user to do the prioritization that the backend already does.

## Vision

Open the app on the lock screen. The single most important card the backend chose is already on screen, web page rendered, no spinner. Swipe → next card. New work that arrived in the last minute slides quietly into the back of the deck — never yanking the active card. With no signal, yesterday's deck still works. Re-onboard a new server by aiming the camera at a QR. The phone feels like a *front page assembled by your assistant*, not a browser.

## Out of Scope

- Reader-mode parsing, content extraction, or local re-rendering of the page (we render the web page as the backend served it)
- Authoring/editing cards on the device (the backend owns the stack)
- Cross-device sync of swipe history or read-state (the backend can model that server-side if it wants)
- A general-purpose browser surface: no address bar, no tabs, no bookmarks, no history UI
- An Android port, a PWA, a watchOS companion, or a macOS Catalyst target in this scaffold
- Payment, subscription, or in-app-purchase flow in v1
- Any server logic — this repo is the client only; the backend is its own project
- Any storage of card payload body content separate from the URL reference

## Principles

- **Backend is the brain; client is the eye.** All prioritization lives server-side. The app is a faithful viewer.
- **Cache-first.** The UI never blocks on the network. A cached deck always beats a spinner.
- **Last-write-wins at the version cursor.** A single `version` field is the source of sync truth; we never reconcile partial deltas client-side.
- **Token is a credential, not config.** Anything signed-in goes through Keychain. UserDefaults is for unsigned preferences only.
- **One source for "which endpoint is live."** The endpoint rotator owns the current cursor; everything else asks it.
- **Active card is sacred.** Nothing — push, fetch, reorder, flush — replaces the card the user is currently looking at. Updates take effect on the next swipe.
- **Native value is the App Store hedge.** QR onboarding, queueing, offline cache, swipe semantics are the parts a web wrapper cannot trivially replicate.
- **Deterministic before clever.** Plain `URLSession` + `Codable` + `async/await` before any reactive-network abstraction.

## Constraints

- **Language:** Swift 5.9+ (Swift 6 mode opt-in OK; not mandated).
- **UI framework:** SwiftUI for app surface; UIKit only inside `UIViewRepresentable` wrappers (WebView, QR scanner).
- **Minimum deployment target:** iOS 17.0. (Decision: the native SwiftUI `WebView` introduced in iOS 18 is *not* used — we wrap `WKWebView` via `UIViewRepresentable` so iOS 17 stays supported. Revisit once iOS 17 falls below ~5 % installed-base.)
- **Networking:** `URLSession` with `async/await`. No Alamofire, no Combine-only paths, no third-party HTTP libs.
- **State:** SwiftUI Observation framework (`@Observable`, `@Bindable`, `@Environment`). No Combine `@Published` for new code.
- **Secrets:** Bearer token + endpoint list → iOS Keychain (`kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlock`). Never `UserDefaults`, never plist, never logged.
- **Cache:** Codable JSON on disk under `Application Support/forefront/`. SwiftData is a future option but is NOT used in the scaffold — too much migration risk for v1.
- **Concurrency:** All network calls run off-main via Swift Concurrency. UI mutations hop back to `@MainActor`.
- **Distribution:** Build must support both ad-hoc/TestFlight personal distribution AND App Store submission. No private SPI, no entitlements that App Review rejects.
- **No npm/Node tooling** anywhere in the client.
- **No third-party card-stack library** in the scaffold — the queueing/flush semantics are subtle enough that a library wrapper would obscure them. A library *may* be adopted later as a pure layout helper.

## Goal

A buildable iOS app project at `~/code/forefront/`, organized so an iOS developer can open Xcode, point it at the source tree, and have a working swipeable card-stack viewer that: (1) onboards via QR-scan; (2) authenticates every request with a Keychain-stored Bearer token; (3) polls `/stack/last-updated` on launch and fetches `/stack` only on version change; (4) renders each card as a `WKWebView` of its `url`; (5) queues new cards behind the active one; (6) falls back through endpoints in order on network failure; (7) renders the cached stack offline; (8) accepts silent APNs pushes as a best-effort refresh trigger.

## Criteria

> ISC count: 132. Tier floor E4 = 128 (met). All anti-criteria and antecedents are interleaved by domain. Each ISC is a single binary tool probe.

### Domain A — Project layout & build (D1: scaffold)

- [ ] ISC-1: `~/code/forefront/` exists and is a git repository (`Read .git/HEAD`)
- [ ] ISC-2: `Package.swift` exists at repo root and declares the package name `Forefront` (`Read Package.swift`)
- [ ] ISC-3: `Package.swift` declares Swift tools version ≥ 5.9 (`Grep "swift-tools-version" Package.swift`)
- [ ] ISC-4: `Package.swift` declares iOS 17 as platform deployment target (`Grep ".iOS(.v17)" Package.swift`)
- [ ] ISC-5: Source directory `Forefront/` exists with subfolders `App/`, `Models/`, `Networking/`, `Storage/`, `UI/CardStack/`, `UI/Onboarding/`, `UI/WebView/`, `Util/`, `Resources/` (`Bash find`)
- [ ] ISC-6: Tests directory `ForefrontTests/` exists (`Bash test -d`)
- [ ] ISC-7: Docs directory `Docs/` exists and contains `BACKEND_CONTRACT.md`, `BUILD_PLAN.md`, `DECISIONS.md` (`Bash test`)
- [ ] ISC-8: `.gitignore` excludes `.build/`, `.swiftpm/`, `DerivedData/`, `*.xcuserstate`, `xcuserdata/` (`Grep`)
- [ ] ISC-9: `README.md` at repo root names the project, summarizes architecture, and lists the "open in Xcode" steps (`Read README.md`)
- [ ] ISC-10: `ISA.md` (this file) lives at repo root and has all twelve required sections (`Grep`)
- [ ] ISC-11: Initial git commit landed on `main` (`Bash git log --oneline`)
- [ ] ISC-12: Anti: no `node_modules/`, `package.json`, or `bun.lockb` files anywhere in the repo (`Bash find`)

### Domain B — Models (D2: typed contracts)

- [ ] ISC-13: `Models/Card.swift` defines a `Card` struct conforming to `Codable, Identifiable, Hashable` with fields `id: String, url: URL, title: String, priority: Int, createdAt: Date, updatedAt: Date, ttl: TimeInterval?, type: CardType?` (`Grep`)
- [ ] ISC-14: `Models/Card.swift` defines a `CardType` enum with `case web` and `case unknown` and conforms to `Codable` with an unknown-case fallback (`Grep "case unknown" Card.swift`)
- [ ] ISC-15: `Models/CardStack.swift` defines a `CardStack` struct conforming to `Codable` with `version: StackVersion` and `cards: [Card]` (`Grep`)
- [ ] ISC-16: `Models/StackVersion.swift` defines a `StackVersion` type that round-trips both integer and ISO-8601 string payloads via a single decoder (`Grep`)
- [ ] ISC-17: `Models/QRPayload.swift` defines a `QRPayload` struct with `version: Int, endpoints: [URL], authToken: String, push: PushHint?` (`Grep`)
- [ ] ISC-18: `Models/QRPayload.swift` rejects a payload whose `endpoints` is empty (decoder throws) (`Grep "endpoints.isEmpty"`)
- [ ] ISC-19: `Models/QRPayload.swift` rejects a payload whose `authToken` is the empty string (`Grep "authToken.isEmpty"`)
- [ ] ISC-20: `Models/Endpoint.swift` defines an `Endpoint` value type wrapping a `URL` and a numeric priority (rotator position) (`Grep`)
- [ ] ISC-21: Anti: no model conforms to `NSObject` or inherits from a UIKit class (`Bash grep -RE "NSObject|UIKit"`)
- [ ] ISC-22: Anti: no model leaks `authToken` into its `CustomStringConvertible` / `description` (`Grep`)

### Domain C — Networking (D3: API client + endpoint rotation)

- [ ] ISC-23: `Networking/APIClient.swift` exposes `func lastUpdated() async throws -> StackVersion` (`Grep`)
- [ ] ISC-24: `Networking/APIClient.swift` exposes `func fetchStack() async throws -> CardStack` (`Grep`)
- [ ] ISC-25: Every outbound request carries `Authorization: Bearer <token>` (`Grep "Bearer"`)
- [ ] ISC-26: `Networking/EndpointRotator.swift` iterates the configured `endpoints` array in order on each call (`Grep`)
- [ ] ISC-27: Rotator persists the index of the last endpoint that succeeded for the session (`Grep "lastSuccessIndex"`)
- [ ] ISC-28: Rotator stops iterating and rethrows once every endpoint has failed within one fetch attempt (`Grep`)
- [ ] ISC-29: Network errors are surfaced as a typed `ForefrontNetworkError` enum, not generic `Error` (`Grep "enum ForefrontNetworkError"`)
- [ ] ISC-30: HTTP 401 from `/stack/last-updated` or `/stack` raises `ForefrontNetworkError.unauthorized` (`Grep "case unauthorized"`)
- [ ] ISC-31: HTTP 5xx is retried at most once per endpoint before falling through to the next (`Grep`)
- [ ] ISC-32: Anti: no network call runs on the main thread (every public API is `async` and the URLSession config sets `.default`) (`Grep`)
- [ ] ISC-33: Anti: the API client does not log the bearer token nor write it to file via `print` / `os_log` substitution (`Grep "authToken"`)
- [ ] ISC-34: `Networking/StackService.swift` orchestrates `lastUpdated()` → compare to cached version → conditionally call `fetchStack()` (`Grep`)
- [ ] ISC-35: `StackService` exposes `func refresh() async -> RefreshOutcome` returning `.unchanged | .updated(CardStack) | .offline(cached: CardStack)` (`Grep`)
- [ ] ISC-36: `StackService.refresh()` does NOT throw — failure paths degrade to `.offline(cached:)` (`Grep "throws" StackService.swift`)
- [ ] ISC-37: A unit test in `ForefrontTests/` decodes a sample `CardStack` JSON fixture (`Read`)
- [ ] ISC-38: A unit test in `ForefrontTests/` decodes a sample `QRPayload` JSON fixture (`Read`)

### Domain D — Storage (D4: Keychain + on-disk cache)

- [ ] ISC-39: `Storage/KeychainStore.swift` defines `func storeToken(_ token: String) throws` and `func loadToken() throws -> String?` (`Grep`)
- [ ] ISC-40: Keychain access uses `kSecAttrAccessibleAfterFirstUnlock` (`Grep "kSecAttrAccessibleAfterFirstUnlock"`)
- [ ] ISC-41: KeychainStore namespaces its service to `com.trilliumsmith.forefront` (`Grep`)
- [ ] ISC-42: Anti: the bearer token is never written to `UserDefaults` (`Bash grep -R "UserDefaults" Forefront/ | grep -i token` returns nothing)
- [ ] ISC-43: `Storage/CacheStore.swift` exposes `func loadStack() throws -> CardStack?` and `func saveStack(_ stack: CardStack) throws` (`Grep`)
- [ ] ISC-44: CacheStore writes to `Application Support/forefront/stack.json` via `FileManager` (`Grep "Application Support"`)
- [ ] ISC-45: CacheStore creates the directory if missing (`Grep "createDirectory"`)
- [ ] ISC-46: CacheStore writes atomically (`Data.WritingOptions.atomic` or `replaceItemAt`) (`Grep`)
- [ ] ISC-47: CacheStore evicts a card whose `ttl + updatedAt` is in the past on load (`Grep "ttl"`)
- [ ] ISC-48: `Storage/AppConfigStore.swift` persists the ordered `endpoints` list and the QR `version` (`Grep`)
- [ ] ISC-49: AppConfigStore is the only writer of the endpoint list outside of QR re-scan flow (`Grep`)
- [ ] ISC-50: Anti: nothing in `Storage/` writes to `Documents/` (so iCloud sync cannot pick up the cache) (`Bash grep`)

### Domain E — Card-stack UI & queue semantics (D5: swipeable deck)

- [ ] ISC-51: `UI/CardStack/CardStackView.swift` is a SwiftUI `View` taking a `StackQueueModel` as an `@Bindable` input (`Grep`)
- [ ] ISC-52: The deck renders cards in a `ZStack` with `zIndex` decreasing from front to back (`Grep "zIndex"`)
- [ ] ISC-53: A horizontal `DragGesture` advances to the next card when the drag exceeds a screen-fraction threshold (`Grep "DragGesture"`)
- [ ] ISC-54: The active card never re-renders mid-drag from an external state change (`Grep "transaction"` or equivalent gate)
- [ ] ISC-55: `UI/CardStack/StackQueueModel.swift` declares `@Observable` and owns `active: Card?`, `queue: [Card]` (`Grep "@Observable"`)
- [ ] ISC-56: `StackQueueModel.advance()` pops the next card off `queue` and assigns it to `active` (`Grep "func advance"`)
- [ ] ISC-57: `StackQueueModel.merge(stack:)` replaces the queue without mutating `active` (`Grep "func merge"`)
- [ ] ISC-58: `StackQueueModel.flush(replacement:)` sets `queue` to the new stack but leaves `active` until next swipe (`Grep "func flush"`)
- [ ] ISC-59: `StackQueueModel.prependUrgent(_:)` inserts a card at queue index 0 without affecting `active` (`Grep "func prependUrgent"`)
- [ ] ISC-60: A card with a higher `priority` (lower numeric value) arriving via fetch is promoted to queue index 0 (`Grep`)
- [ ] ISC-61: Queue mutations happen on `@MainActor` (`Grep "@MainActor"`)
- [ ] ISC-62: Anti: a fetch-side reorder cannot replace the `active` reference (`Grep`)
- [ ] ISC-63: Anti: dropping a stack to length zero does not crash — `active` becomes nil only after the user swipes (`Grep`)
- [ ] ISC-64: `UI/CardStack/CardView.swift` hosts a single `WebCardView` and a title overlay (`Grep`)
- [ ] ISC-65: Cards in the queue (not active) preload at most the next 1 card's web content (`Grep`)
- [ ] ISC-66: A unit test in `ForefrontTests/` verifies `StackQueueModel.advance()` decrements `queue.count` (`Read`)

### Domain F — WebView integration (D6: WKWebView wrapper)

- [ ] ISC-67: `UI/WebView/WebCardView.swift` exposes a SwiftUI view taking a `URL` input (`Grep`)
- [ ] ISC-68: `UI/WebView/WebViewRepresentable.swift` conforms to `UIViewRepresentable` and creates a `WKWebView` (`Grep`)
- [ ] ISC-69: Each card gets its own isolated `WKWebsiteDataStore` (`Grep "nonPersistent\|websiteDataStore"`)
- [ ] ISC-70: Anti: card WebViews do NOT share cookies across cards by default (`Grep`)
- [ ] ISC-71: WebView surfaces a "host unreachable" overlay when navigation fails with `NSURLErrorCannotConnectToHost` or `NSURLErrorTimedOut` (`Grep`)
- [ ] ISC-72: WebView passes the Bearer token as `Authorization` header on the initial request (so card pages can validate the user) (`Grep`)
- [ ] ISC-73: Anti: WebView does not enable arbitrary file URL access (`Grep "allowFileAccessFromFileURLs"` returns nothing or `false`)
- [ ] ISC-74: Anti: WebView does not expose any `WKScriptMessageHandler` to the page (no JS → native bridge in v1) (`Grep`)

### Domain G — QR onboarding (D2 cont. + D7: onboarding flow)

- [ ] ISC-75: `UI/Onboarding/QRScanView.swift` is a SwiftUI view that wraps `QRScannerController` (`Grep`)
- [ ] ISC-76: `UI/Onboarding/QRScannerController.swift` uses `AVCaptureMetadataOutput` with `.qr` type (`Grep ".qr"`)
- [ ] ISC-77: Scanner halts capture on first successful decode (`Grep "stopRunning"`)
- [ ] ISC-78: A decoded payload is parsed via `QRPayload(json:)` and validation errors surface inline (`Grep`)
- [ ] ISC-79: On valid payload, token is written to Keychain and endpoints + version are written to AppConfigStore in one transaction (`Grep`)
- [ ] ISC-80: `UI/Onboarding/OnboardingView.swift` controls the scan → store → ready hand-off (`Grep`)
- [ ] ISC-81: A re-scan flow exists from the settings screen and overwrites existing token + endpoints (`Grep "rescan"`)
- [ ] ISC-82: Camera permission is requested with an `NSCameraUsageDescription` in `Info.plist` (`Grep "NSCameraUsageDescription"`)
- [ ] ISC-83: Anti: a denied camera permission does not crash — the view shows a settings deep-link (`Grep`)
- [ ] ISC-84: Anti: scanning the same QR twice does not double-write (idempotent) (`Grep`)

### Domain H — Push notifications & background refresh (D8: silent push)

- [ ] ISC-85: `Networking/PushRegistrar.swift` exposes `func register() async` that calls `UIApplication.shared.registerForRemoteNotifications()` (`Grep`)
- [ ] ISC-86: `App/ForefrontAppDelegate.swift` implements `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` (`Grep`)
- [ ] ISC-87: Silent push handler invokes `StackService.refresh()` and completes within iOS's 30s background budget (`Grep`)
- [ ] ISC-88: Silent push handler never blocks UI thread (`Grep "@MainActor"` only where required)
- [ ] ISC-89: `Info.plist` declares `UIBackgroundModes` array containing `remote-notification` (`Grep`)
- [ ] ISC-90: APNs device token is forwarded to the backend on the configured `/push/register` (or equivalent) endpoint — endpoint name TBD by backend contract; placeholder in code (`Grep "registerDeviceToken"`)
- [ ] ISC-91: Anti: launch-time poll runs unconditionally even if the most recent silent push said "no change" (i.e. push is best-effort, launch poll is authoritative) (`Grep`)
- [ ] ISC-92: Anti: push handler never surfaces a visible alert / banner (`alert: 0, badge: 0` semantics) (`Grep`)

### Domain I — Offline & resilience (D4 cont. + behavior rules §5)

- [ ] ISC-93: On launch, if `lastUpdated()` throws, app renders `CacheStore.loadStack()` and shows an offline indicator (`Grep`)
- [ ] ISC-94: Offline indicator is a SwiftUI `View` in the deck overlay layer (`Grep "OfflineBanner\|offlineIndicator"`)
- [ ] ISC-95: An empty cache + offline state shows a "first run needs server" empty-state, not a crash (`Grep`)
- [ ] ISC-96: A successful `fetchStack()` clears the offline indicator and writes cache before mutating the queue (`Grep`)
- [ ] ISC-97: Anti: the offline indicator does NOT block input — user can still swipe through the cached deck (`Grep`)
- [ ] ISC-98: Anti: the app never auto-retries a failed fetch more often than every 30 seconds while in foreground (`Grep`)
- [ ] ISC-99: Anti: a server returning a `version` equal to the cached version causes ZERO writes to disk (`Grep`)
- [ ] ISC-100: Anti: a flush (stack with `cards: []`) is honored — queue clears, active stays until swipe (`Grep`)

### Domain J — App entry, environment, settings (D9: assembled app)

- [ ] ISC-101: `App/ForefrontApp.swift` is the `@main` entry point with `WindowGroup { AppRoot() }` (`Grep "@main"`)
- [ ] ISC-102: `App/AppEnvironment.swift` constructs and shares `StackService`, `StackQueueModel`, `KeychainStore`, `CacheStore`, `AppConfigStore`, `PushRegistrar` via `@Environment` (`Grep`)
- [ ] ISC-103: `App/AppRoot.swift` decides onboarding-vs-deck based on `KeychainStore.loadToken() != nil` (`Grep`)
- [ ] ISC-104: A minimal Settings view exposes "rescan QR" and "clear cache" actions (`Grep "SettingsView"`)
- [ ] ISC-105: Anti: there is no "logout" button that wipes the Keychain without confirmation (`Grep`)

### Domain K — Distribution & App Store readiness (D10: dual-distribution gate)

- [ ] ISC-106: `Info.plist` template exists at `Forefront/Resources/Info.plist` with bundle identifier `com.trilliumsmith.forefront` and `CFBundleDisplayName` "Forefront" (`Grep`)
- [ ] ISC-107: `Forefront/Resources/Forefront.entitlements` declares `aps-environment` `development` (`Grep`)
- [ ] ISC-108: README lists the App Store 4.2 narrative (QR onboarding, native deck, offline cache, swipe semantics, silent push) (`Read`)
- [ ] ISC-109: Anti: no use of private SPI / `_` -prefixed symbols (`Bash grep -E "private SPI|@_silgen_name"` returns nothing)
- [ ] ISC-110: Anti: no use of `UIWebView` (deprecated, banned by App Review) (`Bash grep "UIWebView"` returns nothing)
- [ ] ISC-111: `Docs/BACKEND_CONTRACT.md` documents the QR payload schema, `/stack/last-updated`, `/stack`, and silent-push payload exactly as §4 of the spec describes (`Read`)
- [ ] ISC-112: `Docs/BUILD_PLAN.md` lists the eight milestones from §8 in order with file mappings (`Read`)
- [ ] ISC-113: `Docs/DECISIONS.md` records: min-iOS=17, WKWebView path, no card-stack library, isolated cookie jar per card, no UserDefaults for token, AVFoundation (not VisionKit) for QR (`Read`)

### Domain L — Tests & verification (D11)

- [ ] ISC-114: `ForefrontTests/ModelsTests.swift` exists and contains a `Card` round-trip test (`Read`)
- [ ] ISC-115: `ForefrontTests/StackQueueModelTests.swift` exists and covers `advance`, `merge`, `flush`, `prependUrgent` (`Read`)
- [ ] ISC-116: `ForefrontTests/EndpointRotatorTests.swift` exercises primary-success, primary-fail-fallback-success, all-fail (`Read`)
- [ ] ISC-117: `ForefrontTests/CacheStoreTests.swift` round-trips a `CardStack` through disk (`Read`)
- [ ] ISC-118: A `ForefrontTests/Fixtures/` directory contains sample `stack.json` and `qr_payload.json` (`Bash test`)

### Domain M — Anti-criteria (regression prevention)

- [ ] ISC-119: Anti: no `import SwiftUI` inside `Models/` (models are UI-agnostic) (`Bash grep -R "import SwiftUI" Forefront/Models/` returns nothing)
- [ ] ISC-120: Anti: no `print(` calls in production source (only `os.Logger`) (`Bash grep -R "print(" Forefront/ --include="*.swift" | grep -v Tests` returns nothing)
- [ ] ISC-121: Anti: no `fatalError(` in non-test code outside the `@main` boot path (`Bash grep`)
- [ ] ISC-122: Anti: no `// TODO` left unanchored — every TODO must reference an ISC id (`Bash grep "TODO" Forefront/ -R | grep -vE "ISC-[0-9]+"` returns nothing)
- [ ] ISC-123: Anti: no `force-unwrap` of an `Optional` returned from Keychain (`Bash grep "loadToken()!"` returns nothing)
- [ ] ISC-124: Anti: no `DispatchQueue.main.async` — UI hops go via `@MainActor` (`Bash grep "DispatchQueue.main"` returns nothing in non-test code)
- [ ] ISC-125: Anti: no synchronous `URLSession.shared.data(for:)` call without `try await` (`Bash grep`)
- [ ] ISC-126: Anti: no `if #available(iOS 18, *)` branch silently skipping behavior on iOS 17 (`Bash grep "if #available(iOS 18"` either returns nothing or has both branches implemented)
- [ ] ISC-127: Antecedent: the device is connected to the Tailscale tailnet that hosts the endpoints — documented as a user prerequisite in README (`Grep "Tailscale" README.md`)

### Domain N — Process & lifecycle

- [ ] ISC-128: Repo has at least one commit per shipped milestone (no "single mega-commit") (`Bash git log`)
- [ ] ISC-129: Each commit message names the milestone (M1..M8) and a one-line summary (`Bash git log --oneline`)
- [ ] ISC-130: A `CHANGELOG.md` at repo root logs the scaffold drop and what landed (`Read`)
- [ ] ISC-131: `Docs/BUILD_PLAN.md` marks milestones M1–M2 as DONE for this scaffold drop, M3–M8 as TODO with the per-milestone file list (`Grep "DONE\|TODO"`)
- [ ] ISC-132: Anti: the scaffold does NOT contain any `xcuserdata/` or `*.xcuserstate` artifacts (they are gitignored) (`Bash find`)

## Test Strategy

| isc range | type | check | threshold | tool |
| --- | --- | --- | --- | --- |
| ISC-1..12 | filesystem | files / dirs exist with expected fragments | exact match | `Read` / `Bash find` / `Grep` |
| ISC-13..22 | source-grep | type definitions present, anti-patterns absent | grep returns matches/none | `Grep` / `Bash grep -R` |
| ISC-23..38 | source-grep + unit-test | API surface present, unit tests in source tree | function signatures grep | `Grep` |
| ISC-39..50 | source-grep | keychain + cache APIs present, no UserDefaults leak | exact attribute string | `Grep` |
| ISC-51..66 | source-grep + unit-test | model + view shape | grep + test file present | `Grep` / `Read` |
| ISC-67..74 | source-grep | wrapper + isolation flags | grep returns expected line | `Grep` |
| ISC-75..84 | source-grep + plist | scanner + plist key present | grep + plist key found | `Grep` |
| ISC-85..92 | source-grep + plist | push handler + plist mode present | grep + plist key found | `Grep` |
| ISC-93..100 | source-grep | offline path + flush path present | grep returns expected branch | `Grep` |
| ISC-101..105 | source-grep | app entry assembled | grep returns @main + view tree | `Grep` |
| ISC-106..113 | filesystem | distribution artifacts + docs present | file present, content matches | `Read` |
| ISC-114..118 | filesystem | tests present + fixtures present | files exist | `Read` / `Bash test` |
| ISC-119..127 | source-grep | anti-pattern audit clean | grep returns nothing forbidden | `Bash grep -R` |
| ISC-128..132 | git + filesystem | commit history + ignore working | git log + find clean | `Bash git log` / `find` |

**Deferred verification:** ISCs 31, 53, 60, 65, 71, 87, 90, 96 — runtime behavior. Marked `[DEFERRED-VERIFY]` once code lands; live probe requires running the app on a real device or simulator with a backend. Follow-up task: open in Xcode, run on simulator, complete deferred verification pass.

## Features

| name | satisfies | depends_on | parallelizable |
| --- | --- | --- | --- |
| M1: Project scaffold | ISC-1..12 | — | no (foundation) |
| M2: Data contracts | ISC-13..22 | M1 | with M3 (Networking depends on Models) |
| M3: Networking + endpoint rotation | ISC-23..38 | M1, M2 | with M4 (different files) |
| M4: Storage layer (Keychain + cache) | ISC-39..50 | M1, M2 | with M3 |
| M5: Card-stack UI + queue model | ISC-51..66, ISC-93..100 | M2 | with M6, M7 |
| M6: QR onboarding flow | ISC-75..84 | M4 | with M5 |
| M7: WebView wrapper + isolation | ISC-67..74 | M5 | with M6 |
| M8: Silent push + background refresh | ISC-85..92 | M3, M4 | sequential after M3 |
| Distribution + readiness pass | ISC-106..113 | M1..M8 | last (gate) |
| Anti-pattern + lifecycle audit | ISC-119..132 | M1..M8 | last (gate) |
| Tests + fixtures | ISC-114..118 | M2..M5 | with M5..M8 |

## Decisions

- **2026-06-30 — Min iOS = 17.** Native SwiftUI `WebView` is iOS 18+. Targeting 17 keeps the active-user reach broad while only costing one `UIViewRepresentable` wrapper. Revisit when iOS 17 installed-base drops below ~5 %.
- **2026-06-30 — WKWebView via UIViewRepresentable.** Direct consequence of min-iOS=17. Single wrapper file, well-trodden pattern, App-Review safe.
- **2026-06-30 — No third-party card-stack library in scaffold.** The queue/flush/prepend semantics are subtle (active card sacred, fetch never replaces active). A library wrapper would obscure them. A library can be adopted later as a pure layout helper if the gesture math gets gnarly.
- **2026-06-30 — AVFoundation for QR (not VisionKit).** AVFoundation works iOS 10+, has zero new entitlement asks, and the QR-only scope doesn't justify VisionKit's larger surface. VisionKit is a future option if multi-format scanning lands.
- **2026-06-30 — Isolated WKWebsiteDataStore per card (anti-shared-cookie).** Default to isolation; cross-card session sharing only if a future card explicitly requires it. Lowers the blast radius of a misbehaving card.
- **2026-06-30 — Bearer token forwarded as `Authorization` on initial WebView nav.** Backend pages need to know who's viewing them; forwarding the token avoids a second handshake. Documented in BACKEND_CONTRACT.md so the backend can validate.
- **2026-06-30 — Cache lives under `Application Support/forefront/`, NOT `Documents/`.** Documents/ would back up to iCloud and surface in Files.app, which is wrong for a transient deck cache.
- **2026-06-30 — Code-only scaffold; no pre-baked `.xcodeproj`.** Apple's `pbxproj` format is fragile to hand-edit; the package-style source layout + README "open in Xcode" steps preserve buildability without committing brittle project state.
- **2026-06-30 — Compile verification deferred to first Xcode open.** I cannot drive xcodebuild from this environment; ISCs that require a successful build are tagged `[DEFERRED-VERIFY]` and resolved by Trillium's first Xcode open. The scaffold is grep-verifiable in this turn.
- **2026-06-30 — Show-your-math (delegation floor).** E4 soft floor is ≥2 delegations. This run uses Forge (Swift production) + Cato (audit) = 2; no Anvil because whole-project context is unnecessary for a greenfield client scaffold.
- **2026-06-30 — Advisor call deferred to VERIFY** (commitment-boundary timing of Verification Doctrine Rule 2: "after producing a durable deliverable, before setting `phase: complete`"). The first commitment is the directory layout, which is reversible.

## Changelog

- **2026-06-30 — Initial conjecture / refutation / learning.**
  - **conjectured:** A native SwiftUI `WebView` (iOS 18+) would let us drop the UIKit wrapper entirely and ship purer SwiftUI.
  - **refuted_by:** iOS 17 install base is still material as of mid-2026; dropping iOS 17 just to delete one 30-line representable trades user reach for code purity. Bad trade.
  - **learned:** When two iOS versions are both viable, the deciding question is "what does it cost to keep the older one?" Here the cost is 30 lines of well-understood UIViewRepresentable boilerplate. Cheap. Keep iOS 17.
  - **criterion_now:** ISC-4 fixed at iOS 17; ISC-68 explicitly chooses `WKWebView` via `UIViewRepresentable`.

## Verification

> Populated during VERIFY phase. Each ISC gets one line: `ISC-N: [probe type] — [one-line evidence]`.
