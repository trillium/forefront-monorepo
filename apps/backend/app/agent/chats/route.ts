import { logActivity } from "@/lib/activity"
import { unauthorized, validateAgent } from "@/lib/backend"
import { serializeChat } from "@/lib/chat"
import { ensureChat } from "@/lib/store"

export const dynamic = "force-dynamic"

/**
 * POST /agent/chats — the agent creates or ensures a thread (agent key). This is
 * agent-initiated conversation, distinct from the human-initiated `POST /chats`.
 * Idempotent on a provided `id`: re-posting an existing id updates its
 * title/topic and returns it rather than forking a duplicate.
 *
 * Body: `{ id?: string, title?: string, topic?: string }`
 */
export async function POST(req: Request) {
  if (!validateAgent(req)) {
    logActivity("agent_request_failed", "POST /agent/chats 401")
    return unauthorized()
  }
  let body: unknown
  try {
    body = await req.json()
  } catch {
    return Response.json({ error: "invalid JSON body" }, { status: 400 })
  }
  const b = (body ?? {}) as Record<string, unknown>
  const id = typeof b.id === "string" ? b.id : undefined
  const title = typeof b.title === "string" ? b.title : undefined
  const topic =
    typeof b.topic === "string" ? b.topic : b.topic === null ? null : undefined

  const chat = ensureChat({ id, title, topic })
  logActivity("agent_chat", `Ensured thread ${chat.id}`)
  return Response.json(
    serializeChat({ ...chat, unreadCount: 0, lastMessagePreview: null }),
  )
}
