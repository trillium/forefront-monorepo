# Forefront Changelog

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
