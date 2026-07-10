# Forefront Changelog

## 2026-07-09 — session 18769fc6

Files: Forefront/Debug/DebugInfoView.swift, Forefront/App/AppRoot.swift, Scripts/phone, package.json, Forefront/App/AppEnvironment.swift, Forefront/UI/Onboarding/OnboardingView.swift, Forefront/App/ForefrontAppDelegate.swift, Forefront/Storage/AppConfigStore.swift
## 2026-07-09 — session c5fa32b0

Files: Forefront/Resources/Info.plist, project.yml, Scripts/install-phone.sh, .gitignore, Forefront/Resources/Forefront.entitlements, Forefront/Queue/StackQueueModel.swift, Forefront/UI/CardStack/CardStackView.swift, ForefrontTests/StackQueueModelTests.swift, Forefront/Networking/StackService.swift, Forefront/Networking/DemoStackService.swift
## 2026-07-01 — Iteration 2: compile-first + refresh hardening + deck UX

- **The scaffold compiles for the first time.** F1 fixed missing module imports (not manifest deps — those were declared), the `.atomic` contextual-type error, and Sendable warnings; extracted `StackQueueModel` into a new `ForefrontQueue` SwiftPM target (its tests had never compiled — `#if canImport(SwiftUI)` gated them into referencing a nonexistent symbol on macOS). `swift test`: 45 green. `Scripts/check-ui-compile.sh` gives the UI/App layer an iOS-simulator type-check path.
- **F2:** `StackService` is now an actor with single-flight `refresh()` coalescing + 30s automatic-trigger throttle (`refresh(trigger:)`; user-initiated bypasses).
- **F3:** `MockURLProtocol` harness — 5xx retry-once fallback, 401 short-circuit, unchanged-version zero-writes, cache-before-adopt, priority-merge probes now deterministic unit tests (converted from device-only DEFERRED-VERIFY).
- **F4:** foreground refresh on `scenePhase == .active` (throttled).
- **F5:** 401 surfaces a "Session expired" re-scan banner routing into the existing onboarding rescan; cached deck preserved.
- **F8:** deck position indicator ("N of M"), day-part masthead, offline staleness line ("as of HH:mm"), `.sensoryFeedback` haptic on advance, observable arrival tick, hit-testing audit (all overlays `.allowsHitTesting(false)`).
- **Cato audit (E4 gate, satisfied this iteration):** verdict `concerns` — 3 major test-depth findings applied: ISC-146 demoted to DEFERRED-VERIFY (tautological ordering test), ISC-151.1 split (250ms deferred-advance × adopt race untested), throttle wall-clock gap recorded.
- **Recorded for next slot:** F6 undo swipe (ISC-158..161), F7 App Review demo mode (ISC-162..168 — reviewers can't join the tailnet; submission blocker), F9 futures (WidgetKit widget, snapshot peeks, swipe-down defer, BGAppRefreshTask, endpoint health).
- ISA: 169 ISCs, progress 148/169.

## 2026-06-30 — Scaffold drop

- Project layout established: `Forefront/{App,Models,Networking,Storage,UI/{CardStack,Onboarding,WebView},Util,Resources}`, `ForefrontTests/`, `Docs/`.
- `ISA.md` (project ISA) authored with 132 ISCs across 14 domains.
- `Package.swift` exposes Models / Storage / Networking as library targets for `swift test`.
- `.gitignore` covers Xcode user-state and build-product noise.
- `README.md` documents the "open in Xcode" first-time steps and the App Store 4.2 narrative.
- Source files for Models (D2), Networking (D3), Storage (D4), Card-stack UI (D5), WebView wrapper (D6), Onboarding (D7), Push (D8), App entry (D9) all scaffolded.
- Tests for Models, StackQueueModel, EndpointRotator, CacheStore + JSON fixtures.
- Docs: `BACKEND_CONTRACT.md` mirrors §4 of the spec; `BUILD_PLAN.md` lists M1..M8 milestones; `DECISIONS.md` records the eleven scaffold-time architectural calls.
- Initial commit lands on `main`.

Pending (post-scaffold, runtime verification):
- Compile in Xcode and resolve any iOS SDK-only syntax slip (deferred from this codeless environment).
- Run on simulator with a stub backend; complete the `[DEFERRED-VERIFY]` ISCs (31, 53, 60, 65, 71, 87, 90, 96).
- Backend `/push/register` endpoint name TBD — placeholder in `PushRegistrar.swift` flagged with `ISC-90`.
