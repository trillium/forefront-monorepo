/**
 * Shared backend helpers for the Forefront API route handlers.
 *
 * Auth, the onboarding payload, and endpoint resolution live here so every
 * `app/**\/route.ts` handler stays a thin adapter. Ported from the retired
 * standalone Bun server's router; the logic is identical, only the transport
 * (Next.js App Router route handlers) changed.
 */

/** Fixed bearer token for testing (Docs/BACKEND_CONTRACT.md §1). */
export const BEARER_TOKEN = "test-token"

/** Extract and validate `Authorization: Bearer <token>` from a request. */
export function validateBearer(req: Request): boolean {
  const auth = req.headers.get("authorization")
  if (!auth) return false
  const parts = auth.split(" ")
  if (parts.length !== 2 || parts[0] !== "Bearer") return false
  return parts[1] === BEARER_TOKEN
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
    authToken: BEARER_TOKEN,
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
