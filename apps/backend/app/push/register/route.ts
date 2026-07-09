import { logActivity } from "@/lib/activity"
import { registerDevice, unauthorized, validateBearer } from "@/lib/backend"

export const dynamic = "force-dynamic"

/** POST /push/register — device-token sink, no-op APNs (Docs/BACKEND_CONTRACT.md §5). */
export async function POST(req: Request) {
  if (!validateBearer(req)) {
    logActivity("push_register_failed", "401 Unauthorized")
    return unauthorized()
  }
  try {
    const body = await req.json()
    const token = typeof body?.deviceToken === "string" ? body.deviceToken : ""
    // Delegate to the push seam — swap its impl (real APNs registry) without
    // touching this route.
    const label = await registerDevice(token)
    logActivity("push_register", label)
    return new Response(null, { status: 200 })
  } catch {
    return Response.json({ error: "invalid request" }, { status: 400 })
  }
}
