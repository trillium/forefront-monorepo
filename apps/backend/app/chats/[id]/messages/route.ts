import { logActivity } from "@/lib/activity"
import { unauthorized, validateBearer } from "@/lib/backend"
import { parseConsumerSend, serializeMessage } from "@/lib/chat"
import {
  appendUserMessageIdempotent,
  getChat,
  getMessages,
} from "@/lib/store"

export const dynamic = "force-dynamic"

type Ctx = { params: Promise<{ id: string }> }

/**
 * GET /chats/{id}/messages?since=<cursor> — incremental message fetch for one
 * thread (Docs/BACKEND_CONTRACT.md §9). Oldest→newest within the page; reading
 * clears the thread's unread count. Cursor is opaque to the client.
 */
export async function GET(req: Request, ctx: Ctx) {
  if (!validateBearer(req)) {
    logActivity("chat_request_failed", "GET messages 401")
    return unauthorized()
  }
  const { id } = await ctx.params
  if (!getChat(id)) {
    return Response.json({ error: "chat not found" }, { status: 404 })
  }
  const since = new URL(req.url).searchParams.get("since")
  const { messages, nextCursor } = getMessages(id, since)
  logActivity("chat_request", `Fetched ${messages.length} msgs from ${id}`)
  return Response.json({
    messages: messages.map(serializeMessage),
    nextCursor,
  })
}

/**
 * POST /chats/{id}/messages — send a user-authored message (§10). Idempotent on
 * `clientMessageId`: a repeat returns the already-accepted message (200) rather
 * than creating a duplicate; a first insert returns 201. Echoes the canonical
 * server message so the client reconciles its optimistic row.
 */
export async function POST(req: Request, ctx: Ctx) {
  if (!validateBearer(req)) {
    logActivity("chat_request_failed", "POST message 401")
    return unauthorized()
  }
  const { id } = await ctx.params
  if (!getChat(id)) {
    return Response.json({ error: "chat not found" }, { status: 404 })
  }
  let body: unknown
  try {
    body = await req.json()
  } catch {
    return Response.json({ error: "invalid JSON body" }, { status: 400 })
  }
  const parsed = parseConsumerSend(body)
  if (!parsed.ok) {
    return Response.json({ error: parsed.error }, { status: 400 })
  }
  const { message, created } = appendUserMessageIdempotent({
    chatId: id,
    body: parsed.value.body,
    clientMessageId: parsed.value.clientMessageId,
    kind: parsed.value.kind,
  })
  logActivity(
    "chat_message",
    `${created ? "Accepted" : "Deduped"} user msg in ${id}`,
  )
  return Response.json(serializeMessage(message), {
    status: created ? 201 : 200,
  })
}
