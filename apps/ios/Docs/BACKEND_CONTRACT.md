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

---

# Chat feature (v1)

> The chat feature turns the one-way reader into a two-way channel with the AI agent. The **client now authors and sends messages** (this reverses the "client never authors" invariant that applied to cards; see `DECISIONS.md` D-12). Cards remain read-only; chat is the authoring surface. All endpoints below resolve on the tailnet exactly like the deck endpoints and reuse the same Bearer auth + `EndpointRotator` fallback.

## 8. `GET /chats`

The inbox — the list of the user's chat threads. Called on app open and after a chat-relevant push.

**Request:**
```
GET /chats
Authorization: Bearer <token>
Accept: application/json
```

**Response 200:**
```json
{
  "chats": [
    {
      "id": "ch_reminders",
      "title": "Reminders",
      "lastMessageAt": "2026-07-09T16:40:02Z",
      "unreadCount": 2,
      "lastMessagePreview": "Have you booked the flight yet?",
      "topic": "reminders"
    }
  ]
}
```

- `chats` is ordered by the backend, most-recently-active first. The client respects order and does not re-sort.
- `id` (string, required) — stable thread id.
- `title` (string, required) — human-readable thread name.
- `lastMessageAt` (ISO-8601 string, required) — timestamp of the newest message; drives inbox ordering + relative-time display.
- `unreadCount` (int, required, ≥0) — backend's unread tally. The client also tracks unread locally (messages arriving after the last local read); on conflict the client shows `max(local, server)` so a badge never under-counts.
- `lastMessagePreview` (string, optional) — short preview line for the inbox row.
- `topic` (string, optional) — coarse routing tag (`reminders`, `questions`, …). Advisory only.

## 9. `GET /chats/{id}/messages?since=<cursor>`

**Incremental** message fetch for one thread. Unlike `/stack` (full-snapshot), this is delta-based so a long thread is not re-downloaded every poll.

**Request:**
```
GET /chats/ch_reminders/messages?since=<cursor>
Authorization: Bearer <token>
Accept: application/json
```

- `since` (query, optional) — an opaque cursor the client last received. Omitted on first fetch → returns the most recent page (backend decides page size). The cursor is treated as opaque; the client never parses it.

**Response 200:**
```json
{
  "messages": [
    {
      "id": "m_1001",
      "chatId": "ch_reminders",
      "role": "agent",
      "kind": "reminder",
      "body": "Have you booked the flight yet? It's due by Friday.",
      "createdAt": "2026-07-09T16:40:02Z",
      "quickReplies": ["Booked it", "Snooze 1h", "Not yet"],
      "webCardURL": null,
      "reminder": { "dueAt": "2026-07-11T17:00:00Z" }
    },
    {
      "id": "m_1002",
      "chatId": "ch_reminders",
      "role": "agent",
      "kind": "linkToWebCard",
      "body": "Fill in your travel details:",
      "createdAt": "2026-07-09T16:41:00Z",
      "webCardURL": "https://forefront.primary.tailnet-name.ts.net/forms/travel"
    }
  ],
  "nextCursor": "c_1002"
}
```

- `messages` is ordered oldest→newest within the page.
- `id` (string, required) — stable server message id. The client dedups on this.
- `chatId` (string, required) — owning thread.
- `role` (string, required) — one of `user` | `agent` | `system`. Unknown values decode to `system` (forward-compat).
- `kind` (string, required) — one of `text` | `question` | `linkToWebCard` | `reminder`. Unknown values decode to `text` (forward-compat, always renderable).
- `body` (string, required) — the message text; rendered for every kind.
- `createdAt` (ISO-8601 string, required).
- `quickReplies` (array of strings, optional) — present on `question`/`reminder` kinds; rendered as tap-to-send buttons. Tapping one POSTs a `user`/`text` message whose body is the label (§10).
- `webCardURL` (URL string, optional) — present on `linkToWebCard`; opens the existing WebView card surface (drive-to-input). Must resolve on the tailnet.
- `reminder` (object, optional) — present on `reminder` kind; `dueAt` (ISO-8601) is advisory display text. **Reminder cadence is entirely backend-owned** — the client never schedules; it only renders reminder messages and routes notification taps.
- `nextCursor` (string, optional) — opaque; pass as `since` on the next fetch. Absent → caller keeps its previous cursor.

## 10. `POST /chats/{id}/messages`

Send a user-authored message. **Idempotent** — the flaky tailnet means the client retries; the backend MUST dedup on `clientMessageId`.

**Request:**
```
POST /chats/ch_reminders/messages
Authorization: Bearer <token>
Content-Type: application/json

{
  "clientMessageId": "b3d1c0e2-....",
  "kind": "text",
  "body": "Booked it"
}
```

- `clientMessageId` (string, required) — a client-generated UUID. The backend dedups on `(chatId, clientMessageId)`: a repeated POST with the same id returns the already-accepted message rather than creating a duplicate. This is the offline-outbox retry key.
- `kind` (string, required) — `text` in v1 (quick-reply taps also post as `text`).
- `body` (string, required, non-empty).

**Response 200 / 201:**
```json
{
  "id": "m_1003",
  "chatId": "ch_reminders",
  "role": "user",
  "kind": "text",
  "body": "Booked it",
  "createdAt": "2026-07-09T16:42:10Z",
  "clientMessageId": "b3d1c0e2-...."
}
```

- Echoes back the canonical server message. The client reconciles its optimistic local row (matched by `clientMessageId`) with the returned server `id` and flips status `sending → sent`.
- `401` — same as everywhere: flush token, re-onboard.
- `5xx` / transport failure — the message stays in the local **outbox** with status `failed`/`sending` and is retried on the next drain (reconnect, foreground, or manual retry). Retries reuse the same `clientMessageId`, so a duplicate can never land.

## 11. Actionable APNs push (chat)

The deck's push (§4) is **silent** (`content-available`, no alert). Chat reminders are **visible and actionable** — this is a new payload class alongside the silent one.

```json
{
  "aps": {
    "alert": {
      "title": "Reminder",
      "body": "Have you booked the flight yet? It's due by Friday."
    },
    "sound": "default",
    "category": "FF_REMINDER",
    "mutable-content": 1
  },
  "chatId": "ch_reminders",
  "messageId": "m_1001"
}
```

- `aps.alert` — visible text. Rendered by iOS on the lock screen / banner. **APNs delivers through Apple, not the tailnet**, so the reminder text arrives even off-tailnet; *acting* on it (opening the chat, loading a web card) still needs Tailscale.
- `aps.category` — the client registers actionable categories:
  - `FF_REMINDER` → actions **Done**, **Snooze**, **Reply** (text-input action).
  - `FF_QUESTION` → actions from the message's `quickReplies` (rendered as buttons where the payload also carries `quickReplies`).
- `chatId` (string, required) — the thread the notification belongs to. Tapping the notification **deep-links** to this chat (client nav routes to the Chats tab and opens the thread).
- `messageId` (string, optional) — the specific message; used to mark it read / anchor scroll.
- Action semantics:
  - **Done** → client POSTs a `user`/`text` message with body `"Done"` (via the outbox, idempotent) and clears the notification.
  - **Snooze** → client POSTs `"Snooze"`; the backend owns re-scheduling. The client does NOT set a local timer.
  - **Reply** (text input) → client POSTs the typed text as a `user`/`text` message.
- If the device has not been granted notification permission, the backend still queues messages; the client surfaces them on next foreground fetch. Permission is requested at a **contextual moment** (first time the user opens a chat), not blindly at launch.

## 12. Chat reachability & doctrine

- All chat endpoints resolve on the tailnet; the outbox exists precisely because the user composes off-tailnet and sends on reconnect.
- The client authors + holds conversation state locally (SQLite). This is the deliberate reversal of the card-era "client never authors" rule — scoped to chat only.
- Message dedup is by server `id` on receive and by `clientMessageId` on send. Both directions are idempotent.
- Reminder scheduling / the "when to nag" loop lives entirely in the backend repo and is out of scope for the client.
