import { logActivity } from "@/lib/activity"
import { unauthorized, validateAgent } from "@/lib/backend"
import { deleteCard, getDeckVersion } from "@/lib/store"

export const dynamic = "force-dynamic"

type Ctx = { params: Promise<{ id: string }> }

/**
 * DELETE /agent/cards/{id} — remove a curated deck card (agent key). Bumps the
 * deck version iff a card was actually removed, so the phone refetches. Returns
 * 404 when the id is unknown.
 */
export async function DELETE(req: Request, ctx: Ctx) {
  if (!validateAgent(req)) {
    logActivity("agent_request_failed", "DELETE /agent/cards 401")
    return unauthorized()
  }
  const { id } = await ctx.params
  const removed = deleteCard(id)
  if (!removed) {
    return Response.json({ error: "card not found" }, { status: 404 })
  }
  logActivity("agent_card", `Removed card ${id} (deck v${getDeckVersion()})`)
  return Response.json({ id, deleted: true, version: getDeckVersion() })
}
