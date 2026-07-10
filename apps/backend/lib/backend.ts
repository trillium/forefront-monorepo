/**
 * Shared backend helpers for the Forefront API route handlers.
 *
 * Auth, the onboarding payload, endpoint resolution, and the device-token sink
 * live here so every `app/**\/route.ts` handler stays a thin adapter. When an
 * implementation becomes real (env-backed auth, APNs push), it changes here —
 * the routes don't.
 */

import { upsertDeviceToken } from "@/lib/store"

/**
 * The bearer token the server accepts. Env-sourced so real auth doesn't require
 * a code change; defaults to the fixed testing token. The onboarding payload
 * hands this same value to the app, so QR and validation never drift.
 */
export const expectedBearerToken = process.env.BACKEND_TOKEN ?? "test-token"

/**
 * The agent key authorizing the `/agent/*` producer surface — the DA, not the
 * phone. Strictly more privileged than the device bearer: it authors
 * `agent`/`system` messages, curates the deck, and reads the human read-back
 * inbox. Env-sourced with a dev default; change it in any shared deployment.
 * See Docs/DECISIONS.md B-02.
 */
export const expectedAgentToken =
  process.env.FOREFRONT_AGENT_TOKEN ?? "dev-agent-token"

/** Parse a `Bearer <token>` header into its token, or null if malformed. */
function bearerToken(req: Request): string | null {
  const auth = req.headers.get("authorization")
  if (!auth) return null
  const parts = auth.split(" ")
  if (parts.length !== 2 || parts[0] !== "Bearer") return null
  return parts[1] ?? null
}

/** Extract and validate `Authorization: Bearer <token>` from a request. */
export function validateBearer(req: Request): boolean {
  return bearerToken(req) === expectedBearerToken
}

/**
 * Validate the agent key on `/agent/*`. The device bearer token is deliberately
 * NOT accepted here — a compromised phone token must never be able to forge
 * agent messages or reorder the deck (B-02).
 */
export function validateAgent(req: Request): boolean {
  return bearerToken(req) === expectedAgentToken
}

/** Standard 401 body used across bearer-protected endpoints. */
export function unauthorized(): Response {
  return Response.json({ error: "unauthorized" }, { status: 401 })
}

/** The QR onboarding payload (Docs/BACKEND_CONTRACT.md §1). */
export function onboardingPayload(endpoint: string) {
  return {
    version: 1,
    endpoints: [endpoint],
    authToken: expectedBearerToken,
    push: { topic: "com.trilliumsmith.forefront" },
  }
}

/**
 * Best-effort URL the app should reach this server at, baked into the QR.
 * Defaults to the machine's tailnet IP on the Next dev port so a scanned
 * phone hits the running app directly.
 */
export function resolveEndpoint(): string {
  const explicit = process.env.BACKEND_ENDPOINT
  if (explicit) return explicit
  const host = process.env.BACKEND_HOST ?? "100.74.138.74"
  const port = process.env.PORT ?? "9238"
  return `http://${host}:${port}`
}

/**
 * Register a device's APNs token, persisting it so the push drain can target it
 * (contract §5). Upserts on the token: a repeat registration refreshes the row
 * rather than duplicating it. `environment` distinguishes a sandbox-minted token
 * (dev builds, TestFlight) from a production one so the drain never blasts a
 * sandbox token at the production gateway; it defaults to `sandbox`.
 *
 * Returns a short label for the activity feed and never logs the token itself.
 */
export async function registerDevice(
  deviceToken: string,
  environment?: string,
): Promise<string> {
  const trimmed = deviceToken.trim()
  if (!trimmed) return "Device token registration skipped (empty token)"
  const row = upsertDeviceToken({ deviceToken: trimmed, environment })
  return `Device token registered (${trimmed.length} chars, ${row.environment})`
}
