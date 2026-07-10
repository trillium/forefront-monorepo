# Forefront Backend Server

The dev/testing backend the Forefront iOS app talks to over the Tailscale tailnet.
It serves a **card deck** and a **two-way chat + agent-producer surface** so you
can exercise the full onboarding → poll → fetch → swipe flow *and* the
agent-asks → human-answers → agent-reads loop end-to-end on a real device.

- **What it is:** a Next.js 16 app (App Router) whose route handlers implement
  the client contract (§1–12). The API *is* the app — there's no separate server.
- **Where it lives:** `~/code/forefront-backend` (its own repo).
- **Runtime:** the server runs under the **Bun runtime** (`bun --bun next …`) so
  route handlers can use the built-in `bun:sqlite` driver. Chat + deck state is
  durable in a SQLite file (`.data/forefront.db`, gitignored).

## Run it

```bash
cd ~/code/forefront-backend
bun install          # first time only
bun run dev          # bun --bun next dev on 0.0.0.0:9238
```

Then open the dashboard at **http://localhost:9238/** — it shows the onboarding
QR code and a live activity log of every request the phone (and agent) makes.

## Two credentials

| Credential | Env | Who | Can do |
| ---------- | --- | --- | ------ |
| Device bearer | `BACKEND_TOKEN` (default `test-token`) | the phone / human | read chats & messages, author `user` messages, read the deck |
| Agent key | `FOREFRONT_AGENT_TOKEN` (default `dev-agent-token`) | the assistant (DA) | author `agent`/`system` messages, curate the deck, read the human read-back inbox |

The device token **cannot** reach `/agent/*` (verified: 401). This is a hard
privilege boundary — a compromised phone token can never forge agent messages
or reorder the deck. See `Docs/DECISIONS.md` B-02.

## Endpoints

### Deck (device bearer) — contract §2–3

| Method | Path                   | Auth | Purpose                                            |
| ------ | ---------------------- | ---- | -------------------------------------------------- |
| `GET`  | `/stack/last-updated`  | ✅   | Cheap version probe. `{ "version": "1" }`          |
| `GET`  | `/stack`               | ✅   | Full ordered deck. Agent-curated cards, else the demo fixtures |
| `POST` | `/push/register`       | ✅   | Persist device token `{ deviceToken, environment? }` → 200 |

### Chat — consumer (device bearer) — contract §8–10

| Method | Path                          | Auth | Purpose                                              |
| ------ | ----------------------------- | ---- | ---------------------------------------------------- |
| `GET`  | `/chats`                      | ✅   | Inbox, most-recently-active first. Always includes the default `ch_general` thread |
| `POST` | `/chats`                      | ✅   | Human starts a NEW thread. Idempotent on `clientChatId` |
| `GET`  | `/chats/{id}/messages?since=` | ✅   | Incremental message fetch (oldest→newest); reading clears unread |
| `POST` | `/chats/{id}/messages`        | ✅   | Send a `user` message. Idempotent on `clientMessageId` (201 new / 200 dedup) |

The **default thread** `ch_general` (title "Agent") is seeded on store init and
always present, so the human always has somewhere to write — the inbox is never
a dead end. Unsolicited messages there surface in the agent inbox.

### Producer — agent (agent key) — the DA's surface

| Method   | Path                          | Purpose                                                         |
| -------- | ----------------------------- | -------------------------------------------------------------- |
| `POST`   | `/agent/chats`                | Create/ensure a thread `{ id?, title?, topic? }` (agent-initiated) |
| `POST`   | `/agent/chats/{id}/messages`  | Author an `agent` message: `kind = text \| question(+quickReplies) \| linkToWebCard(+webCardURL) \| reminder(+dueAt)`. `push: true` on question/reminder enqueues an actionable-push record |
| `GET`    | `/agent/cards`                | List agent-curated deck cards                                  |
| `POST`   | `/agent/cards`                | Enqueue/update a deck card `{ id?, url, title, priority?, type?, ttl? }`; bumps deck version |
| `DELETE` | `/agent/cards/{id}`           | Remove a card; bumps deck version (404 if unknown)            |
| `GET`    | `/agent/inbox?since=`         | **Read-back loop:** every human (`user`) message across all threads since a cursor. Closes agent-asks → human-answers → agent-reads |
| `GET`    | `/agent/pushes?since=`        | The actionable-push queue + delivery state (see APNs push below) |

### Dashboard (no auth, local only)

`GET /config`, `GET /onboarding-qr`, `GET /activity`, `POST /activity/clear`.

## The `forefront` CLI

DA-ergonomic wrapper over `/agent/*` (PAI is CLI-first). Uses
`FOREFRONT_AGENT_TOKEN` against `FOREFRONT_BASE_URL` (default `:9238`).

```bash
bun run cli/forefront.ts card add https://x --title "Brief" --priority 0
bun run cli/forefront.ts card list
bun run cli/forefront.ts card rm <id>
bun run cli/forefront.ts chat create --title "Reminders" --topic reminders --id ch_reminders
bun run cli/forefront.ts say ch_reminders "Here is your itinerary."
bun run cli/forefront.ts ask ch_reminders "Booked the flight?" --replies "Booked it,Not yet" --push
bun run cli/forefront.ts remind ch_reminders "Pay the deposit" --due 2026-07-11T17:00:00Z --push
bun run cli/forefront.ts inbox  [--since <cursor>]
bun run cli/forefront.ts pushes [--since <cursor>]
bun run cli/forefront.ts push status   # APNs configured? / devices / pending
bun run cli/forefront.ts push drain     # deliver pending pushes via APNs
```

## APNs push (the delivery leg)

The delivery leg is **built and config-gated** (`lib/apns.ts`). Every
`reminder`/`question` authored with `push: true` persists an actionable-push
record (category `FF_REMINDER` / `FF_QUESTION`, body, quick-reply labels),
readable at `GET /agent/pushes`. `forefront push drain` reads the unsent records,
signs a provider JWT, and POSTs each to Apple over HTTP/2 for every registered
device token (tokens arrive via `POST /push/register` and persist in SQLite),
then marks each record sent with its per-device APNs result. The **iOS side
already handles receipt** (contract §11).

With no key configured, `push drain` is a **safe no-op** and records stay
pending — so the backend ships now and delivers the moment the key is dropped in,
with no code change.

### One-time setup (paid Apple Developer Program)

1. **Create an APNs Auth Key** in the [Apple Developer portal](https://developer.apple.com/account/resources/authkeys/list)
   (*Certificates, IDs & Profiles → Keys → +*), check **Apple Push Notifications
   service (APNs)**, register, and **download the `.p8`** (one download only).
   Note its **Key ID**.
2. **Find your Team ID** (top-right of the portal).
3. **Set the env** (uncomment in `.env`) and store the `.p8` outside git:

   ```bash
   APNS_KEY_PATH=/absolute/path/to/AuthKey_ABC123DEFG.p8
   APNS_KEY_ID=ABC123DEFG
   APNS_TEAM_ID=TEAM123456
   # optional: APNS_BUNDLE_ID=com.trilliumsmith.forefront, APNS_ENV=sandbox|production
   ```

4. **Deliver:** `forefront push drain`.

### How it works

- **JWT**: ES256 signed from the `.p8` with `node:crypto` (raw `ieee-p1363`
  signature APNs requires), header `{ alg:"ES256", kid }`, claims `{ iss, iat }`,
  cached ~50min (APNs rejects tokens > 1h and throttles frequent regeneration).
- **Send**: HTTP/2 POST via `node:http2` to `/3/device/<token>` with
  `apns-topic`, `apns-push-type: alert`, `apns-priority: 10`. Zero npm deps —
  Bun ships `node:crypto` + `node:http2`.
- **Idempotent**: only `sent = 0` records are drained; a re-run never re-sends.
- **Auto-drain**: a `push: true` message triggers a best-effort drain, but the
  durable record means `push drain` always works standalone.

### Sandbox vs production

`APNS_ENV` selects `api.sandbox.push.apple.com` (default; dev + TestFlight) or
`api.push.apple.com` (App Store). The device token's environment **must match the
build** — a sandbox token gets `400 BadDeviceToken` / `403` on production and
vice-versa. `/push/register` records each token's `environment` for a future
per-env routing pass; today the drain uses the server's `APNS_ENV` for all sends.

See `Docs/DECISIONS.md` B-04 (superseded) / B-06.

## Storage & cursors

- **`bun:sqlite`**, file DB at `FOREFRONT_DB_PATH` (default `.data/forefront.db`,
  gitignored). Zero dependencies. Seam: `lib/store.ts`.
- **Cursors** are opaque monotonic integers rendered `c_<n>` — one global `seq`
  totally orders all messages, driving both the per-thread fetch (§9) and the
  cross-thread agent inbox. The deck version reuses the same idea (bump on any
  card mutation → the phone refetches). Details: `Docs/DECISIONS.md` B-01/B-03/B-05.

## Quick check

```bash
# deck
curl -H "Authorization: Bearer test-token" http://localhost:9238/stack | jq
# full loop, all assertions
./scripts/e2e.sh
```

## Tests

```bash
bun test            # store unit tests (lib/)
bun run build       # next build (Node) — stays green; DB driver is required lazily
```

## Tailnet reachability

All app-facing endpoints resolve only on the Tailscale tailnet. The phone needs
the Tailscale app installed and connected. Chat endpoints reuse the same Bearer
auth + endpoint-fallback the deck endpoints use; the client's offline outbox
retries sends with the same `clientMessageId`, so the backend's idempotency
guarantees no duplicate ever lands.
