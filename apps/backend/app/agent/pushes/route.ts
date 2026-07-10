import { logActivity } from "@/lib/activity"
import { unauthorized, validateAgent } from "@/lib/backend"
import { listPushes } from "@/lib/store"

export const dynamic = "force-dynamic"

/**
 * GET /agent/pushes?since=<cursor> — the actionable-push queue (agent key).
 *
 * APNs *sending* is out of scope (needs a signed key + cert + prod entitlement;
 * Docs/DECISIONS.md B-04). Instead, every reminder/question authored with
 * `push: true` enqueues a record here. This makes push intent observable and
 * testable, and is the exact seam a real APNs sender slots into: iterate these
 * records, POST to Apple, mark them delivered. The iOS side already handles
 * receipt (contract §11).
 */
export function GET(req: Request) {
  if (!validateAgent(req)) {
    logActivity("agent_request_failed", "GET /agent/pushes 401")
    return unauthorized()
  }
  const since = new URL(req.url).searchParams.get("since")
  const { pushes, nextCursor } = listPushes(since)
  return Response.json({ pushes, nextCursor })
}
