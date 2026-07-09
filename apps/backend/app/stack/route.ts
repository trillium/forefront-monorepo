import { getDeck, getVersion } from "@/lib/deck"
import { logActivity } from "@/lib/activity"
import { unauthorized, validateBearer } from "@/lib/backend"

export const dynamic = "force-dynamic"

/** GET /stack — full ordered deck (Docs/BACKEND_CONTRACT.md §3). */
export async function GET(req: Request) {
  if (!validateBearer(req)) {
    logActivity("stack_request_failed", "401 Unauthorized")
    return unauthorized()
  }
  const cards = await getDeck()
  logActivity("stack_request", `Fetched ${cards.length} cards`)
  return Response.json({ version: getVersion(), cards })
}
