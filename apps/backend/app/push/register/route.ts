import { logActivity } from "@/lib/fixtures"
import { unauthorized, validateBearer } from "@/lib/backend"

export const dynamic = "force-dynamic"

/** POST /push/register — device-token sink, no-op APNs (Docs/BACKEND_CONTRACT.md §5). */
export async function POST(req: Request) {
  if (!validateBearer(req)) {
    logActivity("push_register_failed", "401 Unauthorized")
    return unauthorized()
  }
  try {
    const body = await req.json()
    // Read the token to validate JSON shape, but never log its value.
    const token = typeof body?.deviceToken === "string" ? body.deviceToken : ""
    logActivity("push_register", `Device token registered (${token.length} chars)`)
    return new Response(null, { status: 200 })
  } catch {
    return Response.json({ error: "invalid request" }, { status: 400 })
  }
}
