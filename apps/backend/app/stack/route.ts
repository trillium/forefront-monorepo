import { fixtureCards, getVersion, logActivity } from "@/lib/fixtures"
import { unauthorized, validateBearer } from "@/lib/backend"

export const dynamic = "force-dynamic"

/** GET /stack — full ordered deck (Docs/BACKEND_CONTRACT.md §3). */
export function GET(req: Request) {
  if (!validateBearer(req)) {
    logActivity("stack_request_failed", "401 Unauthorized")
    return unauthorized()
  }
  logActivity("stack_request", `Fetched ${fixtureCards.length} cards`)
  return Response.json({ version: getVersion(), cards: fixtureCards })
}
