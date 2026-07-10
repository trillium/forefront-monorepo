# QR Onboarding

Forefront onboards in a single scan. The backend dashboard renders a QR code; the
iOS app scans it once at first launch (or again after a re-scan in Settings). No
typing, no account, no password — the QR carries everything the app needs to reach
your tailnet backend.

## The QR payload

The QR code encodes a small JSON object (contract §1):

```json
{
  "version": 1,
  "endpoints": [
    "https://forefront.primary.tailnet-name.ts.net",
    "https://forefront.fallback-1.tailnet-name.ts.net"
  ],
  "authToken": "<long-lived bearer>",
  "push": {
    "topic": "com.trilliumsmith.forefront"
  }
}
```

Field by field:

- **`version`** (int, required) — the payload schema version. The client **refuses
  unknown versions**, so a future breaking change can't be mis-parsed by an old app.
- **`endpoints`** (array of URL strings, required, ≥1) — the ordered backend URL
  list, **primary first**. The app rotates through these on transient failure. All
  URLs resolve only on the Tailscale tailnet.
- **`authToken`** (string, required, non-empty) — the bearer token, **long-lived by
  design**. Sent as `Authorization: Bearer <token>` on every request.
- **`push`** (object, optional) — APNs hints. The client tolerates its absence; the
  `topic` defaults to the app's bundle id when omitted.

## First-launch scan

On first launch the app presents a scanner:

1. You open the backend dashboard (`http://localhost:9238/`) which renders the
   onboarding QR.
2. The app scans it and validates the payload — it checks `version`, requires at
   least one endpoint, and requires a non-empty `authToken`.
3. On success it stores:
   - **`authToken` → Keychain.** The bearer never touches plain preferences; it
     lives in the secure enclave-backed Keychain.
   - **`endpoints` → app storage.** The ordered list drives endpoint fallback.
   - **`push.topic`** (if present) → used when registering for APNs.
4. The app immediately runs its first `GET /stack/last-updated` → `GET /stack` and
   shows the deck.

## What gets stored

| Item | Where | Why |
| ---- | ----- | --- |
| `authToken` | **Keychain** | Secure, persists across launches, flushed on `401` |
| `endpoints` | App storage | Ordered fallback list, primary first |
| `push.topic` | App storage | APNs registration topic (defaults to bundle id) |

## Re-scan flow (Settings)

The bearer is long-lived but not immortal. Two paths trigger a re-scan:

- **Manual** — Settings offers a "re-scan" action to point the app at a new backend
  or refresh a rotated token. Scanning a new QR overwrites the stored endpoints and
  Keychain token.
- **Forced by `401`** — a `401` from **any** endpoint means the token is invalid or
  revoked. The app flushes the bearer from the Keychain, refuses to call `/stack`,
  and surfaces an **"auth expired, please re-scan"** state that routes you back to
  the scanner. This is the same re-onboarding entry point as the manual path.

Because onboarding is idempotent — a fresh scan simply replaces the stored
credentials — re-scanning is always safe and never leaves the app in a half-configured
state.

See the [API Contract](/backend/contract) §1–6 for the full onboarding and
reachability rules.
