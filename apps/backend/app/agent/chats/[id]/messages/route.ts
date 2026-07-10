import { logActivity } from "@/lib/activity"
import { unauthorized, validateAgent } from "@/lib/backend"
import { parseAgentSend, serializeMessage } from "@/lib/chat"
import { appendMessage, enqueuePush, ensureChat, getChat } from "@/lib/store"

export const dynamic = "force-dynamic"

type Ctx = { params: Promise<{ id: string }> }

/**
 * POST /agent/chats/{id}/messages — the agent authors a message (agent key).
 * Kinds: `text | question(+quickReplies) | linkToWebCard(+webCardURL) |
 * reminder(+dueAt)` (contract §9). A `reminder`/`question` with `push: true`
 * enqueues an actionable-push record (§11); APNs *sending* is out of scope
 * (Docs/DECISIONS.md B-04) — the record is exposed via GET /agent/pushes.
 *
 * The thread is ensured on demand so the agent can post to a fresh id in one
 * call. Authoring an agent message bumps the thread's unread count.
 */
export async function POST(req: Request, ctx: Ctx) {
  if (!validateAgent(req)) {
    logActivity("agent_request_failed", "POST agent message 401")
    return unauthorized()
  }
  const { id } = await ctx.params
  let body: unknown
  try {
    body = await req.json()
  } catch {
    return Response.json({ error: "invalid JSON body" }, { status: 400 })
  }
  const parsed = parseAgentSend(body)
  if (!parsed.ok) {
    return Response.json({ error: parsed.error }, { status: 400 })
  }

  // Ensure the thread exists so agents can author into a new id directly.
  if (!getChat(id)) ensureChat({ id })

  const message = appendMessage({
    chatId: id,
    role: "agent",
    kind: parsed.value.kind,
    body: parsed.value.body,
    quickReplies: parsed.value.quickReplies,
    webCardURL: parsed.value.webCardURL,
    reminderDueAt: parsed.value.reminderDueAt,
  })

  // Actionable push for reminders/questions when explicitly requested.
  let pushed = false
  if (
    parsed.value.push &&
    (parsed.value.kind === "reminder" || parsed.value.kind === "question")
  ) {
    const category =
      parsed.value.kind === "reminder" ? "FF_REMINDER" : "FF_QUESTION"
    enqueuePush({
      chatId: id,
      messageId: message.id,
      category,
      title: parsed.value.kind === "reminder" ? "Reminder" : "Question",
      body: parsed.value.body,
      quickReplies: parsed.value.quickReplies,
    })
    pushed = true

    // Best-effort auto-drain: deliver the just-enqueued push immediately when
    // APNs is configured. The record→send seam is preserved — the record is
    // already durably enqueued, so `forefront push drain` still delivers it
    // standalone if this drain no-ops (unconfigured) or fails. Fire-and-forget:
    // a slow/failing APNs must never block or fail the agent's 201 response.
    void autoDrain(id)
  }

  logActivity(
    "agent_message",
    `Authored ${parsed.value.kind} in ${id}${pushed ? " (+push)" : ""}`,
  )
  return Response.json(serializeMessage(message), { status: 201 })
}

/**
 * Fire-and-forget drain triggered right after a `push: true` message is
 * enqueued. Lazily imports lib/apns so the module graph stays build-safe, and
 * swallows every error into the activity feed — the durable record is the
 * source of truth, so a failed auto-drain is recoverable via `push drain`.
 */
async function autoDrain(chatId: string): Promise<void> {
  try {
    const { drainPushes, isConfigured } = await import("@/lib/apns")
    if (!isConfigured()) return
    const summary = await drainPushes()
    logActivity(
      "push_drain",
      `auto-drain after ${chatId}: ${summary.accepted}/${summary.attempts} accepted` +
        ` across ${summary.deviceCount} device(s)`,
    )
  } catch (err) {
    logActivity(
      "push_drain_failed",
      `auto-drain error: ${err instanceof Error ? err.message : String(err)}`,
    )
  }
}
