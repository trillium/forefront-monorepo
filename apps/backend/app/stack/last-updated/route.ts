import { getVersion } from "@/lib/deck"
import { logActivity } from "@/lib/activity"
import { unauthorized, validateBearer } from "@/lib/backend"

// In-memory fixture state must not be statically cached.
export const dynamic = "force-dynamic"

/** GET /stack/last-updated — cheap version probe (Docs/BACKEND_CONTRACT.md §2). */
export function GET(req: Request) {
  if (!validateBearer(req)) {
    logActivity("stack_request_failed", "401 Unauthorized")
    return unauthorized()
  }
  logActivity("stack_request", "Version probe")
  return Response.json({ version: getVersion() })
}
