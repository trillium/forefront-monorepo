# iOS App Overview

Forefront is a native iOS app that presents an AI-curated feed as a **swipeable
card stack**. Your assistant (the DA) assembles a personal "front page" and the
app renders it — a phone-native version of "the front page your assistant built
for you today."

## What it is

- A **card-stack viewer**: each card is a self-hosted web page rendered in a
  `WKWebView`. You swipe through the deck the assistant curated for you.
- The **backend decides the deck order** — the app is a faithful renderer, not a
  ranker. Index 0 is front-of-deck; the app never re-sorts.
- All content resolves on your **Tailscale tailnet**, so the feed is private to
  your own devices and never traverses the public internet.

## How it works

1. **QR onboarding** — on first launch you scan a QR code from the backend
   dashboard. It carries the endpoint list, a long-lived bearer token, and APNs
   hints. The token lands in the **Keychain**; endpoints are stored for fallback.
2. **Version-probe polling** — on every app open (and on every silent push) the
   app hits `GET /stack/last-updated`. Only when the version differs from the
   cached one does it fetch the full deck via `GET /stack`. Cheap probe, expensive
   fetch only when needed.
3. **Render** — each card's `url` is loaded into a `WKWebView`. The deck is cached
   for offline viewing; a card past its `updatedAt + ttl` may be evicted.
4. **Silent APNs** — a `content-available` push nudges the app to re-run the
   last-updated → fetch flow. The push is best-effort; the launch-time poll is the
   source of truth.

## Key features

- **Offline cache** — the last-fetched deck is persisted, so cards remain viewable
  without connectivity. An empty `cards: []` from the backend is a flush: the queue
  clears but the active card stays until you swipe.
- **Silent APNs refresh** — background pushes keep the deck fresh without a visible
  banner. No alert, badge, or sound on the silent class.
- **Endpoint fallback** — the app rotates through the ordered endpoint list on
  transient `5xx`/transport failures, then falls back to cache. Primary first.
- **Auth-expiry UX** — a `401` from any endpoint flushes the bearer token from the
  Keychain and surfaces an "auth expired, please re-scan" state that forces
  re-onboarding.
- **Deck UX pack** — position indicator, masthead, staleness cues, and haptics on
  swipe make the stack feel physical and readable.
- **30 s foreground throttle** — the app never auto-retries a failed fetch more
  often than every 30 s while in the foreground.

## Tech stack

- **Swift** + **SwiftUI** for the UI layer.
- **Swift Package Manager** for the module structure (a single-flight `StackService`
  actor owns the refresh state machine).
- **WKWebView** for card rendering.
- **Keychain** for the bearer token; **APNs** for silent + actionable push.

See the [API Contract](/backend/contract) for the exact request/response shapes the
app consumes, and [QR Setup](/onboarding/qr) for the onboarding payload.
