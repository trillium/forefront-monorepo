# Forefront Backend Contract

> The client (this repo) consumes the contract below. The backend lives in its own repo. This document is the source of truth for what the client expects.

## 1. QR onboarding payload

JSON encoded into a QR code. Scanned once at first launch (or after a re-scan in Settings).

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

- `version` (int, required) — payload schema version. Client refuses unknown versions.
- `endpoints` (array of URL strings, required, ≥1 entry) — ordered, primary first.
- `authToken` (string, required, non-empty) — bearer token, long-lived by design.
- `push` (object, optional) — APNs hints. Client tolerates absence; topic defaults to the bundle id.

## 2. `GET /stack/last-updated`

Cheap probe. Called on every app open and on every silent push.

**Request:**
```
GET /stack/last-updated
Authorization: Bearer <token>
Accept: application/json
```

**Response 200:**
```json
{ "version": 42 }
```

- `version` may be an integer, an ISO-8601 string, or an opaque etag — the client decodes all three via `StackVersion` and only does equality comparison. Backend SHOULD pick one and stick with it.

**Errors:**
- `401` — token invalid / revoked. Client surfaces an "auth expired, please re-scan" state and refuses to call `/stack`.
- `5xx` — client treats as transient, falls through to the next endpoint, then falls back to cache.

## 3. `GET /stack`

Full ordered deck. Called only when `/stack/last-updated` returned a different `version` than the client's cached one.

**Request:**
```
GET /stack
Authorization: Bearer <token>
Accept: application/json
```

**Response 200:**
```json
{
  "version": 42,
  "cards": [
    {
      "id": "c_abc123",
      "url": "https://forefront.primary.tailnet-name.ts.net/cards/abc123",
      "title": "Morning briefing",
      "priority": 0,
      "createdAt": "2026-06-30T07:01:12Z",
      "updatedAt": "2026-06-30T07:01:12Z",
      "ttl": 3600,
      "type": "web"
    }
  ]
}
```

- `cards` is **ordered**, index 0 = front-of-deck, lowest priority value = highest priority.
- The backend is authoritative on order. The client respects it and does not re-sort.
- `ttl` (seconds, optional) — client may evict a cached card whose `updatedAt + ttl < now`.
- `type` (optional) — `"web"` is the only currently-supported renderer; unknown values render as `web` (forward-compat).
- An empty `cards: []` is a **flush** — client clears its queue but keeps the active card visible until the user swipes.

## 4. Silent APNs push

Minimal payload, `content-available: 1`. Fires the client into the same last-updated → fetch flow that runs on launch.

```json
{
  "aps": {
    "content-available": 1
  },
  "version": 42
}
```

- The optional top-level `version` is a hint. The client ignores it for decision-making and re-runs `/stack/last-updated` as the authority.
- Push MUST NOT carry an `alert`, `badge`, or `sound`.
- Push is **best-effort**. The client's launch-time poll is the source of truth.

## 5. Device-token registration (TBD endpoint name)

After APNs grants a device token, the client POSTs it to the backend so the backend can target the right device. **Endpoint name TBD by backend team.** Client stub assumes:

```
POST /push/register
Authorization: Bearer <token>
Content-Type: application/json

{ "deviceToken": "<hex-encoded APNs token>" }
```

Client tolerates a 200 or 204. Anything else: silent fail, retry on next launch.

## 6. Reachability assumptions

- All endpoint URLs resolve only on the **Tailscale tailnet**. The user is expected to have the Tailscale app installed and connected; the README states this.
- The client never auto-retries a failed fetch more often than every 30 s while in foreground.
- A `401` from any endpoint flushes the bearer token from Keychain and forces re-onboarding.

## 7. What the client does NOT consume

- Raw HTML over the API (cards point to URLs; pages are rendered from the server directly in WebView).
- Server-pushed deltas; the version cursor is full-snapshot only.
- Multi-card payloads of any non-`web` type in v1.
