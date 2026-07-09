/**
 * Shared backend helpers for the Forefront API route handlers.
 *
 * Auth, the onboarding payload, endpoint resolution, and the device-token sink
 * live here so every `app/**\/route.ts` handler stays a thin adapter. When an
 * implementation becomes real (env-backed auth, APNs push), it changes here —
 * the routes don't.
 */

/**
 * The bearer token the server accepts. Env-sourced so real auth doesn't require
 * a code change; defaults to the fixed testing token. The onboarding payload
 * hands this same value to the app, so QR and validation never drift.
 */
export const expectedBearerToken = process.env.BACKEND_TOKEN ?? "test-token"

/** Extract and validate `Authorization: Bearer <token>` from a request. */
export function validateBearer(req: Request): boolean {
  const auth = req.headers.get("authorization")
  if (!auth) return false
  const parts = auth.split(" ")
  if (parts.length !== 2 || parts[0] !== "Bearer") return false
  return parts[1] === expectedBearerToken
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
 * Register a device's APNs token. The seam for push: today a no-op that just
 * acknowledges; swap this body for a real registry/store without touching the
 * route. Returns a short label for the activity feed (never logs the token).
 */
export async function registerDevice(deviceToken: string): Promise<string> {
  // No-op APNs for now — the app's launch-time poll is the source of truth.
  return `Device token registered (${deviceToken.length} chars)`
}
