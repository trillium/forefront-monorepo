# Forefront Backend Server

The dev/testing backend the Forefront iOS app talks to over the Tailscale tailnet.
It serves a small **fixture deck** so you can exercise the full onboarding →
poll → fetch → swipe → undo flow end-to-end on a real device.

- **What it is:** a Next.js 16 app (App Router) whose route handlers implement
  [`BACKEND_CONTRACT.md`](./BACKEND_CONTRACT.md). The API *is* the app — there's
  no separate server process.
- **Where it lives:** `~/code/forefront-backend` (its own repo, not this one).
- **What it is not (yet):** no database, no real APNs, no auth beyond a fixed
  bearer token, no dynamic card generation. It's a fixture server for device testing.

## Run it

```bash
cd ~/code/forefront-backend
bun install          # first time only
bun run dev          # next dev on 0.0.0.0:9238
```

Then open the dashboard at **http://localhost:9238/** — it shows the onboarding
QR code and a live activity log of every request the phone makes.

## Onboard the phone

1. Make sure the phone has **Tailscale** installed and connected (the API is
   reachable only on the tailnet).
2. Open the dashboard on your Mac (`http://localhost:9238/`).
3. In the Forefront app, tap **Scan QR** and point the camera at the code.
4. The app stores the endpoint + bearer token in the Keychain, polls
   `/stack/last-updated`, fetches `/stack`, and renders the deck. Watch the
   dashboard's activity log light up as it happens.

## Endpoints

All app-facing endpoints require `Authorization: Bearer test-token`.

| Method | Path                   | Auth | Purpose                                             |
| ------ | ---------------------- | ---- | --------------------------------------------------- |
| `GET`  | `/stack/last-updated`  | ✅   | Cheap version probe. `{ "version": "1" }`           |
| `GET`  | `/stack`               | ✅   | Full ordered deck. `{ "version", "cards": [...] }`  |
| `POST` | `/push/register`       | ✅   | Device-token sink. `{ "deviceToken": "..." }` → 200 (no-op APNs) |
| `GET`  | `/config`              | —    | Endpoint + onboarding payload (dashboard)           |
| `GET`  | `/onboarding-qr`       | —    | The onboarding payload as a live PNG                |
| `GET`  | `/activity`            | —    | Newest-first request log (dashboard)                |
| `POST` | `/activity/clear`      | —    | Reset the request log                               |

Invalid/missing bearer on a protected endpoint returns `401` — which the app
surfaces as "auth expired, please re-scan."

### Quick check

```bash
curl http://localhost:9238/stack/last-updated                              # 401
curl -H "Authorization: Bearer test-token" http://localhost:9238/stack | jq # deck
```

## Tailnet reachability

`bun run dev` binds to `0.0.0.0`, so the phone reaches it at the Mac's tailnet
address. The QR payload's endpoint is resolved from env (below):

- Tailnet IP: `http://100.74.138.74:9238`
- MagicDNS:   `http://macbook.hippo-tilapia.ts.net:9238`

## Configuration (`.env`)

| Var                | Default            | Effect                                          |
| ------------------ | ------------------ | ----------------------------------------------- |
| `BACKEND_HOST`     | `100.74.138.74`    | Host baked into the QR payload's endpoint URL   |
| `BACKEND_ENDPOINT` | —                  | Full override (e.g. the MagicDNS URL)           |
| `PORT`             | `9238`             | Next dev port                                   |

> The `dev`/`start` scripts wrap next with `dotenv -e .env --` on purpose: Next
> loads `.env` into the app runtime, but *after* it has already chosen the bind
> port, so a bare `next dev` ignores `PORT` from `.env`. `dotenv-cli` injects
> `PORT` into next's environment first, so `bun run dev` binds 9238 with no flags.

## Deck

Three cards, hardcoded in `lib/deck.ts` (front-of-deck first, lowest `priority`
= highest). Callers go through the `getDeck()` accessor and `getVersion()`, never
a raw array — so swapping the source for a curated `brain`/`feed` query later is
a one-function change, not a caller-rippling edit. To force the app to refetch
during testing, bump the version — call `bumpVersion()` or edit the `version`
seed and restart.

## Caveats (fixture server, by design)

- **State is in-memory.** Version and the activity log reset on restart, and are
  not shared across multiple production workers. Fine for `next dev` testing.
- **APNs is a no-op.** `/push/register` accepts and logs the token but sends no
  pushes. The app's launch-time poll is the source of truth anyway.
- **Fixed bearer token.** `test-token`, read by the app from the QR payload —
  never hardcoded in the app.

## Future scope

The port to a production shape is deliberately deferred:

- **Card content pages** — real self-hosted pages (`app/cards/[id]/page.tsx`)
  rendered in the app's WebView, instead of fixture cards pointing at external URLs.
- **Attach to PULSE** — a Next.js app can't be mounted in-process as a PULSE
  module; PULSE will **reverse-proxy** `/forefront/*` to this app and link it
  from `/status/` (One-URL rule).
- **Assistant-curated deck** — replace the body of `getDeck()` in `lib/deck.ts`
  with a `brain`/`feed` query so the deck order is assembled by the DA. Already
  async, so no caller changes. This is the whole reason the backend lives in
  TS/bun rather than Go.
