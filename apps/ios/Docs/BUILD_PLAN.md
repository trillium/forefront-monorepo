# Forefront Build Plan

Milestone order matches §8 of the spec, expanded into the per-file mapping the scaffold establishes.

| Milestone | Status | Files |
| --- | --- | --- |
| **M1 — Project scaffold** | **DONE** (2026-06-30) | `Package.swift`, `.gitignore`, `README.md`, `ISA.md`, dir tree, initial commit |
| **M2 — Data contracts (QR + Card + Stack)** | **DONE** (2026-06-30) | `Forefront/Models/Card.swift`, `CardStack.swift`, `StackVersion.swift`, `QRPayload.swift`, `Endpoint.swift` |
| **M3 — Networking: last-updated + fetch + Bearer + fallback** | **DONE** (scaffolded; runtime DEFERRED-VERIFY) | `Forefront/Networking/APIClient.swift`, `EndpointRotator.swift`, `StackService.swift`, `ForefrontNetworkError.swift` |
| **M4 — On-disk Codable cache + offline rendering path** | **DONE** (scaffolded) | `Forefront/Storage/CacheStore.swift`, `KeychainStore.swift`, `AppConfigStore.swift` |
| **M5 — Card-stack UI: swipe, zIndex, queue model, "queue for next swipe" rule** | **DONE** (scaffolded) | `Forefront/UI/CardStack/CardStackView.swift`, `CardView.swift`, `StackQueueModel.swift` |
| **M6 — Reorder / prepend-urgent / flush handling** | **DONE** (scaffolded; runtime DEFERRED-VERIFY) | `StackQueueModel.merge/flush/prependUrgent` methods |
| **M7 — Silent push registration + background refresh; launch poll as source of truth** | **DONE** (scaffolded; APNs cert + backend endpoint TBD) | `Forefront/Networking/PushRegistrar.swift`, `Forefront/App/ForefrontAppDelegate.swift`, `Forefront/Resources/Info.plist` (UIBackgroundModes) |
| **M8 — Polish: offline indicator, re-scan/rotate token, WebView session isolation, App Store readiness pass** | **PARTIAL** — offline indicator + re-scan + session isolation scaffolded; final App Review note pass + screenshot prep TODO | `OfflineBanner.swift`, `SettingsView.swift`, `WebViewRepresentable.swift`, `Docs/DECISIONS.md` |

## Post-scaffold work

The scaffold is verifiable by `grep`/`Read` in this turn. Runtime verification of the following ISCs is **deferred** to the first Xcode build:

- ISC-31 — 5xx retry-once behavior under a real failing endpoint
- ISC-53 — drag-gesture threshold tuning on a real device
- ISC-60 — higher-priority card promoted to queue index 0 via live fetch
- ISC-65 — adjacent-card preload behavior on real hardware
- ISC-71 — host-unreachable overlay under real `NSURLErrorCannotConnectToHost`
- ISC-87 — silent push handler completing within the 30 s background budget
- ISC-90 — `/push/register` payload accepted by the backend (endpoint name TBD)
- ISC-96 — fetch success clearing the offline indicator

Each is referenced in code with `// ISC-N` comments where relevant.

## Build hygiene rules

- One commit per milestone — `git log --oneline` should read like the table above.
- No untracked TODOs; every `// TODO` references an ISC id.
- The ISA's `progress: M/132` field tracks the number of passed ISCs and is updated as runtime verification completes.
