# Talking to Forefront from Your Assistant

The Forefront backend has two credential tiers. The **device bearer** is what the iPhone uses — it can read the deck, post user messages, and read chat history. The **agent key** is what your DA uses — it can author messages, curate the deck, read human replies, and enqueue pushes. The two keys are intentionally separate so the assistant can't impersonate the human and vice versa.

This page documents the agent-facing surface: auth, the `forefront` CLI, every `/agent/*` endpoint, and the read-back loop the DA runs to catch human replies.

---

## Auth

```
FOREFRONT_AGENT_TOKEN=<your-agent-token>
FOREFRONT_BASE_URL=http://your-tailscale-host:9238   # default: http://127.0.0.1:9238
```

Every `/agent/*` route requires `Authorization: Bearer <FOREFRONT_AGENT_TOKEN>`. Requests with the device bearer return `401`. The default dev token is `dev-agent-token` (set in `.env`).

| Token | Can do |
|-------|--------|
| Device bearer (`BACKEND_TOKEN`) | Read deck, read chats, post `user` messages |
| Agent key (`FOREFRONT_AGENT_TOKEN`) | Author `agent` messages, curate deck, read inbox/pushes |

---

## The CLI

`forefront` is the ergonomic DA surface — curl wrapped into verbs. Install it from the backend repo:

```bash
cd ~/code/forefront-backend
bun install                  # first time
bun run forefront help       # or: bunx --bun ./cli/forefront.ts help
```

Or link it globally:

```bash
bun link                     # inside ~/code/forefront-backend
```

### All verbs

```
# Deck curation
forefront card add <url> --title <t> [--priority <n>] [--ttl <seconds>] [--id <id>]
forefront card list
forefront card rm <id>

# Thread management
forefront chat create --title <t> [--topic <x>] [--id <id>]

# Messaging
forefront say    <chatId> <text>
forefront ask    <chatId> <question> --replies Yes,No,Maybe [--push]
forefront remind <chatId> <text> --due <ISO-8601> [--push]

# Reading
forefront inbox  [--since <cursor>]
forefront pushes [--since <cursor>]

# APNs delivery
forefront push drain    # send pending pushes to Apple
forefront push status   # configured? / device count / pending count
```

### Examples

```bash
# Queue a card in the deck
forefront card add "https://example.com/article" --title "Good read on X"

# Open a thread and say something
forefront chat create --title "Today's briefing" --id morning
forefront say morning "Good morning. Here's what I found."

# Ask a question with quick-reply options and send a push
forefront ask morning "Ready for your summary?" --replies "Yes,Give me a minute" --push

# Set a reminder (dueAt must be ISO-8601)
forefront remind morning "You have a call at 3pm" --due "2024-03-15T15:00:00Z" --push

# Read new human replies since last check
forefront inbox --since <cursor-from-previous-response>
```

---

## HTTP Endpoints

All endpoints require `Authorization: Bearer <FOREFRONT_AGENT_TOKEN>`.

### Threads

#### `POST /agent/chats`

Create or ensure a thread. Idempotent on `id` — re-posting an existing id updates the title/topic instead of creating a duplicate.

**Body:**
```json
{
  "id": "morning",          // optional; generated if omitted
  "title": "Daily briefing",
  "topic": "morning-context"  // optional
}
```

**Response `200`:** the chat object (same shape as `GET /chats/:id`).

---

### Messages

#### `POST /agent/chats/{id}/messages`

Author a message into a thread. The thread is created on demand if `id` is new. Bumps the thread's unread count so the phone surfaces it.

**Body — all kinds:**

```json
// Plain text
{ "kind": "text", "body": "Hello." }

// Question with quick replies
{
  "kind": "question",
  "body": "Ready for your briefing?",
  "quickReplies": ["Yes", "In 5 minutes", "Skip today"],
  "push": true    // enqueue an actionable push (optional)
}

// Reminder
{
  "kind": "reminder",
  "body": "Your 3pm call starts soon.",
  "dueAt": "2024-03-15T15:00:00Z",  // ISO-8601, server normalizes
  "push": true
}

// Link card (opens a web card in the app)
{
  "kind": "linkToWebCard",
  "body": "Article worth reading:",
  "webCardURL": "https://example.com/article"
}
```

**Response `201`:** the message object.

**Push behavior:** when `push: true` on a `question` or `reminder`, the server enqueues an actionable-push record and triggers an auto-drain if APNs is configured. The record is durable — `forefront push drain` re-delivers it if auto-drain fails.

---

### Deck

#### `GET /agent/cards`

List the current deck, front-of-deck first.

**Response:**
```json
{ "version": 42, "cards": [{ "id": "...", "url": "...", "title": "...", "priority": 0, "type": null, "ttl": null }] }
```

#### `POST /agent/cards`

Enqueue or update a card. Bumps the deck version so the phone refetches on next poll.

**Body:**
```json
{
  "url": "https://example.com",    // required
  "title": "Article title",        // required
  "id": "custom-id",               // optional; generated if omitted
  "priority": 10,                  // optional; lower = further front
  "type": "article",               // optional; freeform tag
  "ttl": 86400                     // optional; seconds until auto-expiry
}
```

**Response `201`:** the card object.

#### `DELETE /agent/cards/{id}`

Remove a card. Bumps the deck version iff a card was actually removed. Returns `404` when the id is unknown.

---

### The Read-Back Loop

#### `GET /agent/inbox?since=<cursor>`

Returns every human-authored (`role: user`) message across **all threads** since a cursor, oldest→newest. Quick-reply taps arrive here as `user`/`text`. This is how the DA reads answers — poll this after asking a question or on a background schedule.

**Response:**
```json
{
  "messages": [
    {
      "id": "msg-123",
      "chatId": "morning",
      "role": "user",
      "kind": "text",
      "body": "Yes",
      "createdAt": "2024-03-15T09:01:00Z"
    }
  ],
  "nextCursor": "msg-123"
}
```

Pass `nextCursor` as `since` on the next call to avoid re-reading. Omit `since` to get everything from the beginning.

---

### Push Queue

#### `GET /agent/pushes?since=<cursor>`

The actionable-push record queue. Every `question` or `reminder` with `push: true` lands here. The DA can inspect what's pending before running `forefront push drain`.

**Response:**
```json
{
  "pushes": [
    {
      "id": "push-abc",
      "chatId": "morning",
      "messageId": "msg-456",
      "category": "FF_QUESTION",
      "title": "Question",
      "body": "Ready for your briefing?",
      "quickReplies": ["Yes", "In 5 minutes"],
      "sentAt": null,
      "createdAt": "2024-03-15T09:00:00Z"
    }
  ],
  "nextCursor": "push-abc"
}
```

`sentAt: null` means pending. After `push drain`, `sentAt` is set.

---

## Push Delivery

APNs sending happens outside the HTTP layer. `push drain` and `push status` run **in-process against the shared SQLite file** — not over HTTP — so the CLI process can see what the server enqueued.

```bash
forefront push status   # check if APNs is configured and how many pushes are pending
forefront push drain    # deliver pending records to Apple
```

APNs credentials are set via env vars — see [Server Setup](/backend/server) for the full list. When unconfigured, `push drain` is a safe no-op: records stay pending and deliver the next time drain runs with credentials set.

---

## What's Not Yet There

Two read endpoints are missing from the agent surface:

- **`GET /agent/chats`** — list threads from the agent's perspective
- **`GET /agent/chats/{id}/messages?since=<cursor>&limit=<n>`** — read a specific thread's history

Today the only agent-key read is `GET /agent/inbox`, which surfaces new human input across all threads but doesn't let the DA pull a single thread's full history. The consumer endpoint `GET /chats/{id}/messages` covers this but requires the device bearer, not the agent key.

These are tracked as a known gap. For now, the DA should maintain its own in-memory or store-backed context of what it has sent, using `inbox` to catch replies.
