import { logActivity } from "@/lib/activity"
import { unauthorized, validateAgent } from "@/lib/backend"
import { getDeckVersion, listCards, upsertCard } from "@/lib/store"

export const dynamic = "force-dynamic"

/**
 * GET /agent/cards — list the agent-curated deck cards (agent key). Ordered
 * front-of-deck first. Convenience for the DA to see what it has queued.
 */
export function GET(req: Request) {
  if (!validateAgent(req)) {
    logActivity("agent_request_failed", "GET /agent/cards 401")
    return unauthorized()
  }
  return Response.json({ version: getDeckVersion(), cards: listCards() })
}

/**
 * POST /agent/cards — enqueue (or update) a deck card (agent key). Bumps the
 * deck version so the phone refetches `/stack` (Docs/DECISIONS.md B-05).
 *
 * Body: `{ id?, url, title, priority?, type?, ttl? }`
 */
export async function POST(req: Request) {
  if (!validateAgent(req)) {
    logActivity("agent_request_failed", "POST /agent/cards 401")
    return unauthorized()
  }
  let body: unknown
  try {
    body = await req.json()
  } catch {
    return Response.json({ error: "invalid JSON body" }, { status: 400 })
  }
  const b = (body ?? {}) as Record<string, unknown>
  if (typeof b.url !== "string" || b.url.trim() === "") {
    return Response.json({ error: "url is required" }, { status: 400 })
  }
  if (typeof b.title !== "string" || b.title.trim() === "") {
    return Response.json({ error: "title is required" }, { status: 400 })
  }
  const card = upsertCard({
    id: typeof b.id === "string" ? b.id : undefined,
    url: b.url,
    title: b.title,
    priority: typeof b.priority === "number" ? b.priority : undefined,
    type: typeof b.type === "string" ? b.type : undefined,
    ttl: typeof b.ttl === "number" ? b.ttl : null,
  })
  logActivity("agent_card", `Enqueued card ${card.id} (deck v${getDeckVersion()})`)
  return Response.json(card, { status: 201 })
}
