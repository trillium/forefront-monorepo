import { logActivity } from "@/lib/activity"
import { unauthorized, validateBearer } from "@/lib/backend"
import { serializeChat } from "@/lib/chat"
import { createHumanChat, listChats } from "@/lib/store"

export const dynamic = "force-dynamic"

/**
 * GET /chats — the inbox (Docs/BACKEND_CONTRACT.md §8). Most-recently-active
 * first. Always returns at least the seeded default thread, so the human always
 * has somewhere to write — the inbox is never a dead end.
 */
export function GET(req: Request) {
  if (!validateBearer(req)) {
    logActivity("chat_request_failed", "GET /chats 401")
    return unauthorized()
  }
  const chats = listChats().map(serializeChat)
  logActivity("chat_request", `Listed ${chats.length} chats`)
  return Response.json({ chats })
}

/**
 * POST /chats — the human starts a NEW thread (§8-adjacent). Idempotent on
 * `clientChatId` so an offline retry never forks a duplicate thread. Distinct
 * from `POST /agent/chats`, which is agent-initiated. Bearer (human) auth.
 *
 * Body: `{ clientChatId: string, title?: string }`
 */
export async function POST(req: Request) {
  if (!validateBearer(req)) {
    logActivity("chat_request_failed", "POST /chats 401")
    return unauthorized()
  }
  let body: unknown
  try {
    body = await req.json()
  } catch {
    return Response.json({ error: "invalid JSON body" }, { status: 400 })
  }
  const b = (body ?? {}) as Record<string, unknown>
  const clientChatId =
    typeof b.clientChatId === "string" ? b.clientChatId.trim() : ""
  if (!clientChatId) {
    return Response.json({ error: "clientChatId is required" }, { status: 400 })
  }
  const title = typeof b.title === "string" ? b.title : undefined

  const { chat, created } = createHumanChat({ clientChatId, title })
  logActivity("chat_created", `${created ? "Created" : "Reused"} ${chat.id}`)
  return Response.json(serializeChat({ ...chat, unreadCount: 0, lastMessagePreview: null }), {
    status: created ? 201 : 200,
  })
}
