import { logActivity } from "@/lib/activity"
import { unauthorized, validateAgent } from "@/lib/backend"
import { serializeMessage } from "@/lib/chat"
import { getInbox } from "@/lib/store"

export const dynamic = "force-dynamic"

/**
 * GET /agent/inbox?since=<cursor> — the read-back loop (agent key). Returns
 * every human-authored (`role: user`) message across ALL threads since a cursor,
 * oldest→newest. Quick-reply taps arrive as `user`/`text` so they surface here
 * too, as do unsolicited messages to the default thread. This closes the
 * agent-asks → human-answers → agent-reads cycle so the DA can see answers.
 */
export function GET(req: Request) {
  if (!validateAgent(req)) {
    logActivity("agent_request_failed", "GET /agent/inbox 401")
    return unauthorized()
  }
  const since = new URL(req.url).searchParams.get("since")
  const { messages, nextCursor } = getInbox(since)
  logActivity("agent_inbox", `Read ${messages.length} human msgs`)
  return Response.json({
    messages: messages.map(serializeMessage),
    nextCursor,
  })
}
