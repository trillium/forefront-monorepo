import { logActivity } from "@/lib/activity"
import { registerDevice, unauthorized, validateBearer } from "@/lib/backend"

export const dynamic = "force-dynamic"

/**
 * POST /push/register — persist the device's APNs token so the push drain can
 * target it (Docs/BACKEND_CONTRACT.md §5). Body: `{ deviceToken, environment? }`
 * where `environment` is `sandbox` (default) or `production`. The token is
 * upserted; a repeat registration refreshes the row.
 */
export async function POST(req: Request) {
  if (!validateBearer(req)) {
    logActivity("push_register_failed", "401 Unauthorized")
    return unauthorized()
  }
  try {
    const body = await req.json()
    const token = typeof body?.deviceToken === "string" ? body.deviceToken : ""
    if (!token) {
      return Response.json({ error: "deviceToken required" }, { status: 400 })
    }
    const environment =
      body?.environment === "production" ? "production" : "sandbox"
    // Delegate to the push seam — persistence lives in lib/backend + lib/store.
    const label = await registerDevice(token, environment)
    logActivity("push_register", label)
    return new Response(null, { status: 200 })
  } catch {
    return Response.json({ error: "invalid request" }, { status: 400 })
  }
}
