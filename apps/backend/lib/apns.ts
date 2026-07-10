/**
 * The APNs delivery leg — sign a provider JWT and POST a notification to Apple
 * over HTTP/2 (contract §4 silent + §11 actionable).
 *
 * Config-gated by design: with no `.p8` key configured, `isConfigured()` is
 * false and every send is a logged no-op, so the backend ships and runs today
 * and lights up the moment the key is dropped in — no code change. Everything
 * reads env lazily (never at import), so `next build`'s static analysis under
 * Node never touches the key and tests can set env per case.
 *
 * Crypto uses `node:crypto` (Bun implements it): ES256 = SHA-256 over the JWT
 * signing-input, signed with the EC P-256 private key from the `.p8` PEM, in the
 * raw R||S (`ieee-p1363`) form APNs requires — NOT DER. The provider token is
 * cached and reused up to ~50 min (APNs rejects tokens older than 1h and
 * throttles frequent regeneration).
 *
 * Setup: create an APNs Auth Key (`.p8`) in the Apple Developer portal, then set
 * APNS_KEY_PATH / APNS_KEY_ID / APNS_TEAM_ID (see Docs/BACKEND_SERVER.md).
 */

import { createPrivateKey, createSign, type KeyObject } from "node:crypto"
import { existsSync, readFileSync } from "node:fs"
import { connect, constants as http2Constants } from "node:http2"

import type { PushDeliveryResult } from "@/lib/store"

// ── Config ───────────────────────────────────────────────────────────────────

/** APNs environment → gateway host. Sandbox is the default for dev/TestFlight. */
export type ApnsEnvironment = "sandbox" | "production"

const APNS_HOSTS: Record<ApnsEnvironment, string> = {
  sandbox: "api.sandbox.push.apple.com",
  production: "api.push.apple.com",
}

/** Resolved APNs configuration, read from env. */
export interface ApnsConfig {
  keyPath: string
  keyId: string
  teamId: string
  bundleId: string
  environment: ApnsEnvironment
}

/**
 * Read the APNs config from env, or null when the minimum is not set. The
 * minimum for signing is a key path, a key id, and a team id — the bundle id
 * has a sensible default and the environment defaults to sandbox.
 */
export function readConfig(): ApnsConfig | null {
  const keyPath = process.env.APNS_KEY_PATH?.trim()
  const keyId = process.env.APNS_KEY_ID?.trim()
  const teamId = process.env.APNS_TEAM_ID?.trim()
  if (!keyPath || !keyId || !teamId) return null
  const bundleId =
    process.env.APNS_BUNDLE_ID?.trim() || "com.trilliumsmith.forefront"
  const environment: ApnsEnvironment =
    process.env.APNS_ENV?.trim() === "production" ? "production" : "sandbox"
  return { keyPath, keyId, teamId, bundleId, environment }
}

/**
 * True when APNs is fully configured AND the key file actually exists on disk.
 * The file check is what makes "drop the `.p8` in and it lights up" real: env
 * vars can be set before the key is placed, and we must not attempt a send that
 * would throw on an unreadable path.
 */
export function isConfigured(): boolean {
  const cfg = readConfig()
  return cfg !== null && existsSync(cfg.keyPath)
}

// ── JWT signing (ES256) ──────────────────────────────────────────────────────

/** base64url with no padding, per RFC 7515. */
export function base64url(input: Buffer | string): string {
  const buf = typeof input === "string" ? Buffer.from(input, "utf8") : input
  return buf
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "")
}

/**
 * Build a signed APNs provider JWT (ES256).
 *
 * Header `{ alg: "ES256", kid }`, claims `{ iss: teamId, iat }`. The signature
 * is raw R||S (`ieee-p1363`, 64 bytes) — APNs rejects the DER form Node emits by
 * default. `pem` is the `.p8` contents (PKCS#8 PEM). `iat` is injectable so the
 * cache can stamp a real clock and tests can pin a value.
 */
export function buildProviderJWT(input: {
  pem: string | KeyObject
  keyId: string
  teamId: string
  iat?: number
}): string {
  const iat = input.iat ?? Math.floor(Date.now() / 1000)
  const header = base64url(JSON.stringify({ alg: "ES256", kid: input.keyId }))
  const claims = base64url(JSON.stringify({ iss: input.teamId, iat }))
  const signingInput = `${header}.${claims}`

  const key =
    typeof input.pem === "string" ? createPrivateKey(input.pem) : input.pem
  const sign = createSign("SHA256")
  sign.update(signingInput)
  const signature = sign.sign({ key, dsaEncoding: "ieee-p1363" })
  return `${signingInput}.${base64url(signature)}`
}

// ── Cached provider token ────────────────────────────────────────────────────

/** Regenerate the provider token this often (well under APNs's 1h ceiling). */
const TOKEN_TTL_MS = 50 * 60 * 1000

interface CachedToken {
  jwt: string
  /** The config fingerprint this token was minted for; a change invalidates. */
  fingerprint: string
  mintedAt: number
}

let _cachedToken: CachedToken | null = null

/** A cheap fingerprint of the signing inputs so a config swap busts the cache. */
function configFingerprint(cfg: ApnsConfig): string {
  return `${cfg.keyPath}|${cfg.keyId}|${cfg.teamId}`
}

/**
 * Return a valid provider JWT for `cfg`, minting (and caching) a fresh one when
 * the cache is empty, aged past the TTL, or built for a different config. Reads
 * the `.p8` from disk only when a mint is actually needed.
 */
export function getProviderToken(cfg: ApnsConfig, now = Date.now()): string {
  const fingerprint = configFingerprint(cfg)
  if (
    _cachedToken &&
    _cachedToken.fingerprint === fingerprint &&
    now - _cachedToken.mintedAt < TOKEN_TTL_MS
  ) {
    return _cachedToken.jwt
  }
  const pem = readFileSync(cfg.keyPath, "utf8")
  const jwt = buildProviderJWT({
    pem,
    keyId: cfg.keyId,
    teamId: cfg.teamId,
    iat: Math.floor(now / 1000),
  })
  _cachedToken = { jwt, fingerprint, mintedAt: now }
  return jwt
}

/** Clear the cached provider token. Test-only + config-reload hook. */
export function _resetTokenCacheForTest(): void {
  _cachedToken = null
}

// ── Send ─────────────────────────────────────────────────────────────────────

/** Outcome of one `sendPush` attempt. */
export interface SendResult {
  /** APNs HTTP status (200 = accepted), or null when the send never reached Apple. */
  status: number | null
  /** APNs `apns-id` correlation header, when returned. */
  apnsId: string | null
  /** Apple's rejection `reason` (e.g. `BadDeviceToken`), when the body carries one. */
  reason: string | null
  /** Transport-level error string when the request never got an APNs response. */
  error: string | null
}

const {
  HTTP2_HEADER_METHOD,
  HTTP2_HEADER_PATH,
  HTTP2_HEADER_AUTHORITY,
  HTTP2_HEADER_STATUS,
} = http2Constants

/**
 * POST one notification to APNs for a single device token over HTTP/2.
 *
 * Path `/3/device/<token>`; headers `authorization: bearer <jwt>`,
 * `apns-topic: <bundleId>`, `apns-push-type: alert`, `apns-priority: 10`. Opens
 * a short-lived HTTP/2 session per call (fine for the current low-volume drain;
 * a pooled session is a later optimization). Never throws — a transport failure
 * resolves as `{ status: null, error }` so the drain can record it and move on.
 *
 * Config-gated: when APNs is not configured this is a logged no-op returning
 * `{ status: null, error: "not configured" }`.
 */
export async function sendPush(
  deviceToken: string,
  payload: Record<string, unknown>,
  opts: { timeoutMs?: number } = {},
): Promise<SendResult> {
  const cfg = readConfig()
  if (!cfg || !existsSync(cfg.keyPath)) {
    console.log(
      `[apns] not configured — skipping send to ${redactToken(deviceToken)}`,
    )
    return { status: null, apnsId: null, reason: null, error: "not configured" }
  }

  let jwt: string
  try {
    jwt = getProviderToken(cfg)
  } catch (err) {
    return {
      status: null,
      apnsId: null,
      reason: null,
      error: `token mint failed: ${errString(err)}`,
    }
  }

  const host = APNS_HOSTS[cfg.environment]
  const timeoutMs = opts.timeoutMs ?? 10_000
  const body = Buffer.from(JSON.stringify(payload), "utf8")

  return await new Promise<SendResult>((resolve) => {
    let settled = false
    const done = (r: SendResult): void => {
      if (settled) return
      settled = true
      resolve(r)
    }

    const client = connect(`https://${host}:443`)
    // A single hard deadline covers connect + request + response. Every exit
    // path closes the session so no HTTP/2 socket leaks between drains.
    const timer = setTimeout(() => {
      client.close()
      done({
        status: null,
        apnsId: null,
        reason: null,
        error: `timeout after ${timeoutMs}ms`,
      })
    }, timeoutMs)
    timer.unref?.()

    client.on("error", (err) => {
      clearTimeout(timer)
      client.close()
      done({
        status: null,
        apnsId: null,
        reason: null,
        error: `connection error: ${errString(err)}`,
      })
    })

    const req = client.request({
      [HTTP2_HEADER_METHOD]: "POST",
      [HTTP2_HEADER_PATH]: `/3/device/${deviceToken}`,
      [HTTP2_HEADER_AUTHORITY]: host,
      authorization: `bearer ${jwt}`,
      "apns-topic": cfg.bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
      "content-length": String(body.length),
    })

    let status: number | null = null
    let apnsId: string | null = null
    const chunks: Buffer[] = []

    req.on("response", (headers) => {
      const raw = headers[HTTP2_HEADER_STATUS]
      status = typeof raw === "number" ? raw : Number(raw ?? NaN)
      if (Number.isNaN(status)) status = null
      const id = headers["apns-id"]
      apnsId = typeof id === "string" ? id : Array.isArray(id) ? (id[0] ?? null) : null
    })
    req.on("data", (chunk: Buffer) => chunks.push(chunk))
    req.on("error", (err) => {
      clearTimeout(timer)
      client.close()
      done({
        status: null,
        apnsId,
        reason: null,
        error: `stream error: ${errString(err)}`,
      })
    })
    req.on("end", () => {
      clearTimeout(timer)
      client.close()
      const reason = parseReason(Buffer.concat(chunks))
      done({ status, apnsId, reason, error: null })
    })

    req.end(body)
  })
}

/** Extract APNs's `reason` from an error response body, if present. */
function parseReason(body: Buffer): string | null {
  if (body.length === 0) return null
  try {
    const parsed: unknown = JSON.parse(body.toString("utf8"))
    if (
      parsed &&
      typeof parsed === "object" &&
      "reason" in parsed &&
      typeof (parsed as { reason: unknown }).reason === "string"
    ) {
      return (parsed as { reason: string }).reason
    }
    return null
  } catch {
    return null
  }
}

// ── Payload shaping (§4 silent + §11 actionable) ─────────────────────────────

/** The fields a push record carries into payload shaping. */
export interface PushIntent {
  chatId: string
  messageId: string
  category: string
  title: string
  body: string
  quickReplies?: string[] | null
}

/**
 * Build the actionable-push payload (contract §11) for a chat reminder/question.
 *
 * `aps.alert` carries the visible title/body; `aps.category` is the record's
 * category (`FF_REMINDER` / `FF_QUESTION`) so the client renders the right
 * actions; `mutable-content: 1` lets the client's notification-service extension
 * post-process. `chatId` deep-links the tap; `messageId` anchors read/scroll.
 * `quickReplies`, when present, ride alongside so `FF_QUESTION` can render its
 * buttons from the payload.
 */
export function buildActionablePayload(
  intent: PushIntent,
): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    aps: {
      alert: { title: intent.title, body: intent.body },
      sound: "default",
      category: intent.category,
      "mutable-content": 1,
    },
    chatId: intent.chatId,
    messageId: intent.messageId,
  }
  if (intent.quickReplies && intent.quickReplies.length > 0) {
    payload.quickReplies = intent.quickReplies
  }
  return payload
}

/**
 * Build the silent deck-refresh payload (contract §4): `content-available: 1`,
 * no alert/badge/sound, optional top-level `version` hint. Kept here so both
 * push classes live behind one sender.
 */
export function buildSilentPayload(
  version?: string | number,
): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    aps: { "content-available": 1 },
  }
  if (version !== undefined) payload.version = version
  return payload
}

// ── Drain ────────────────────────────────────────────────────────────────────

/** Aggregate outcome of a drain run, for the CLI + activity feed. */
export interface DrainSummary {
  configured: boolean
  deviceCount: number
  /** Push records processed this run. */
  processed: number
  /** Individual (push × device) send attempts. */
  attempts: number
  /** Attempts APNs accepted (HTTP 200). */
  accepted: number
  /** Attempts that failed (non-200 or transport error). */
  failed: number
  perPush: Array<{ pushId: string; results: PushDeliveryResult[] }>
}

/**
 * Ports for the drain, injected so it is unit-testable without a live DB/APNs.
 * Production wiring in `drainPushes` binds these to `lib/store` + `sendPush`.
 */
export interface DrainDeps {
  listDevices: () => Array<{ deviceToken: string; environment: string }>
  markSent: (pushId: string, results: PushDeliveryResult[]) => void
  send: (
    deviceToken: string,
    payload: Record<string, unknown>,
  ) => Promise<SendResult>
  configured: boolean
}

/** A push record as the drain consumes it (intent + its store id). */
export type DrainablePush = PushIntent & { id: string }

/**
 * Core drain, dependency-injected. For each unsent push it builds the §11
 * payload and sends to every registered device, then marks the record sent with
 * the per-device results. When unconfigured it is a **no-op that leaves records
 * unsent** — so nothing is silently consumed before the key exists, and the
 * first real drain after configuration picks them all up. Also a no-op (records
 * left unsent) when there are no devices, for the same reason.
 */
export async function runDrain(
  pushes: DrainablePush[],
  deps: DrainDeps,
): Promise<DrainSummary> {
  const devices = deps.listDevices()
  const summary: DrainSummary = {
    configured: deps.configured,
    deviceCount: devices.length,
    processed: 0,
    attempts: 0,
    accepted: 0,
    failed: 0,
    perPush: [],
  }

  if (!deps.configured || devices.length === 0) {
    // Leave every record unsent so a later, properly-configured drain delivers
    // them. This is the graceful pre-key path.
    return summary
  }

  for (const push of pushes) {
    const payload = buildActionablePayload(push)
    const results: PushDeliveryResult[] = []
    for (const device of devices) {
      const res = await deps.send(device.deviceToken, payload)
      results.push({
        deviceToken: redactToken(device.deviceToken),
        status: res.status,
        reason: res.reason,
        apnsId: res.apnsId,
        error: res.error,
      })
      summary.attempts++
      if (res.status === 200) summary.accepted++
      else summary.failed++
    }
    deps.markSent(push.id, results)
    summary.processed++
    summary.perPush.push({ pushId: push.id, results })
  }
  return summary
}

/**
 * Production drain: send every unsent actionable-push record to every registered
 * device, marking each record sent with its per-device APNs results. Safe to run
 * standalone or right after an agent posts a `push: true` message. Idempotent —
 * only `sent = 0` records are processed, so a re-run never double-sends.
 *
 * Imports `lib/store` lazily so this module stays importable under Node (build)
 * without pulling in `bun:sqlite`.
 */
export async function drainPushes(): Promise<DrainSummary> {
  const store = await import("@/lib/store")
  const unsent = store.listUnsentPushes()
  const pushes: DrainablePush[] = unsent.map((p) => ({
    id: p.id,
    chatId: p.chatId,
    messageId: p.messageId,
    category: p.category,
    title: p.title,
    body: p.body,
    quickReplies: p.quickReplies,
  }))
  return runDrain(pushes, {
    listDevices: () =>
      store
        .listDeviceTokens()
        .map((d) => ({ deviceToken: d.deviceToken, environment: d.environment })),
    markSent: (pushId, results) => store.markPushSent(pushId, results),
    send: (token, payload) => sendPush(token, payload),
    configured: isConfigured(),
  })
}

// ── Small helpers ────────────────────────────────────────────────────────────

/** Redact a device token for logs/results — first 6 + last 4 hex chars. */
export function redactToken(token: string): string {
  if (token.length <= 12) return `${token.slice(0, 2)}…`
  return `${token.slice(0, 6)}…${token.slice(-4)}`
}

function errString(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}
