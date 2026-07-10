/**
 * Shared chat serialization + request validation for the route handlers.
 *
 * Keeps `app/**\/route.ts` thin: routes do auth + param extraction, then call
 * these to shape responses and validate bodies. Mirrors the lib-seam pattern of
 * `lib/backend.ts`. The public message/chat JSON shapes here are the contract
 * (Docs/BACKEND_CONTRACT.md §8–10) — the client is already built against them.
 */

import type { Chat, Message, MessageKind, MessageRole } from "@/lib/store"

/** The chat inbox row the client consumes (§8). */
export interface ChatDTO {
  id: string
  title: string
  lastMessageAt: string
  unreadCount: number
  lastMessagePreview?: string
  topic?: string
}

/** The message row the client consumes (§9/§10). */
export interface MessageDTO {
  id: string
  chatId: string
  role: MessageRole
  kind: MessageKind
  body: string
  createdAt: string
  quickReplies?: string[]
  webCardURL?: string | null
  reminder?: { dueAt: string }
  clientMessageId?: string
}

/**
 * Serialize a chat (+ its unread/preview) for `GET /chats`. Optional fields are
 * omitted when null so the JSON matches the contract's "optional" markers
 * rather than emitting explicit nulls.
 */
export function serializeChat(
  chat: Chat & { unreadCount: number; lastMessagePreview: string | null },
): ChatDTO {
  const dto: ChatDTO = {
    id: chat.id,
    title: chat.title,
    lastMessageAt: chat.lastMessageAt,
    unreadCount: chat.unreadCount,
  }
  if (chat.lastMessagePreview) dto.lastMessagePreview = chat.lastMessagePreview
  if (chat.topic) dto.topic = chat.topic
  return dto
}

/** Serialize a stored message for the wire. Omits absent optional fields. */
export function serializeMessage(m: Message): MessageDTO {
  const dto: MessageDTO = {
    id: m.id,
    chatId: m.chatId,
    role: m.role,
    kind: m.kind,
    body: m.body,
    createdAt: m.createdAt,
  }
  if (m.quickReplies) dto.quickReplies = m.quickReplies
  // webCardURL is meaningful even as null on linkToWebCard rows; include when set.
  if (m.webCardURL) dto.webCardURL = m.webCardURL
  if (m.reminder) dto.reminder = m.reminder
  if (m.clientMessageId) dto.clientMessageId = m.clientMessageId
  return dto
}

const CONSUMER_KINDS: readonly MessageKind[] = ["text"]
const AGENT_KINDS: readonly MessageKind[] = [
  "text",
  "question",
  "linkToWebCard",
  "reminder",
]

/** A validated consumer send body (§10). */
export interface ConsumerSend {
  clientMessageId: string
  kind: MessageKind
  body: string
}

/**
 * Validate a `POST /chats/{id}/messages` body. The client only ever sends
 * `kind: "text"` (quick-reply taps included), so we accept `text` and default a
 * missing kind to `text`. Returns a discriminated result rather than throwing.
 */
export function parseConsumerSend(
  body: unknown,
): { ok: true; value: ConsumerSend } | { ok: false; error: string } {
  if (typeof body !== "object" || body === null) {
    return { ok: false, error: "body must be a JSON object" }
  }
  const b = body as Record<string, unknown>

  if (typeof b.clientMessageId !== "string" || b.clientMessageId.trim() === "") {
    return { ok: false, error: "clientMessageId is required" }
  }
  if (typeof b.body !== "string" || b.body.trim() === "") {
    return { ok: false, error: "body is required and must be non-empty" }
  }
  const kind = b.kind === undefined ? "text" : b.kind
  if (typeof kind !== "string" || !CONSUMER_KINDS.includes(kind as MessageKind)) {
    return { ok: false, error: "kind must be 'text'" }
  }
  return {
    ok: true,
    value: {
      clientMessageId: b.clientMessageId.trim(),
      kind: kind as MessageKind,
      body: b.body,
    },
  }
}

/** A validated agent-authored message body (producer side). */
export interface AgentSend {
  kind: MessageKind
  body: string
  quickReplies: string[] | null
  webCardURL: string | null
  reminderDueAt: string | null
  push: boolean
}

/**
 * Normalize a reminder due-time to ISO-8601 (what the iOS client decodes as a
 * `Date`), or null if it can't be understood. `dueAt` is advisory display text —
 * dropping an unparseable value is far better than storing a raw string like
 * "tomorrow 5pm", which fails the client's `.iso8601` Date decode and breaks the
 * ENTIRE thread's message sync (one bad field kills the whole `/messages` fetch).
 * Accepts ISO-8601 as-is, plus common forms: "in 30 min", "in 1 hour",
 * "in 2 days", "today"/"tomorrow" (+ optional "5pm"), and weekday names.
 */
export function normalizeDueAt(input: string, now: Date = new Date()): string | null {
  const s = input.trim().toLowerCase()
  if (!s) return null

  // Already a date the engine understands and looks date-shaped (ISO-8601 etc.).
  const direct = new Date(input)
  if (!Number.isNaN(direct.getTime()) && /\d{4}-\d{2}-\d{2}/.test(input)) {
    return direct.toISOString()
  }

  const UNIT = { min: 60_000, hour: 3_600_000, day: 86_400_000 }
  const parseClock = (str: string): { h: number; m: number } | null => {
    const t = str.match(/(\d{1,2})(?::(\d{2}))?\s*(am|pm)?/)
    if (!t) return null
    let h = parseInt(t[1], 10)
    if (t[3] === "pm" && h < 12) h += 12
    if (t[3] === "am" && h === 12) h = 0
    return { h, m: t[2] ? parseInt(t[2], 10) : 0 }
  }

  let mt = s.match(/^in\s+(\d+)\s*(min(?:ute)?s?|h(?:ou)?rs?|days?)$/)
  if (mt) {
    const n = parseInt(mt[1], 10)
    const unit = mt[2].startsWith("d") ? UNIT.day : mt[2].startsWith("h") ? UNIT.hour : UNIT.min
    return new Date(now.getTime() + n * unit).toISOString()
  }

  mt = s.match(/^(today|tomorrow)(?:\s+(.+))?$/)
  if (mt) {
    const d = new Date(now)
    if (mt[1] === "tomorrow") d.setDate(d.getDate() + 1)
    const clock = mt[2] ? parseClock(mt[2]) : null
    d.setHours(clock?.h ?? 9, clock?.m ?? 0, 0, 0)
    return d.toISOString()
  }

  const DAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
  mt = s.match(/^(?:next\s+)?(\w+day)(?:\s+(.+))?$/)
  if (mt) {
    const target = DAYS.indexOf(mt[1])
    if (target >= 0) {
      const d = new Date(now)
      let delta = (target - d.getDay() + 7) % 7
      if (delta === 0) delta = 7 // the NEXT occurrence, not today
      d.setDate(d.getDate() + delta)
      const clock = mt[2] ? parseClock(mt[2]) : null
      d.setHours(clock?.h ?? 9, clock?.m ?? 0, 0, 0)
      return d.toISOString()
    }
  }

  return null // unparseable → drop (advisory only; never ship a non-ISO string)
}

/**
 * Validate a `POST /agent/chats/{id}/messages` body. Agents may author any of
 * the four kinds; kind-specific fields are validated against the kind.
 */
export function parseAgentSend(
  body: unknown,
): { ok: true; value: AgentSend } | { ok: false; error: string } {
  if (typeof body !== "object" || body === null) {
    return { ok: false, error: "body must be a JSON object" }
  }
  const b = body as Record<string, unknown>

  const kind = b.kind
  if (typeof kind !== "string" || !AGENT_KINDS.includes(kind as MessageKind)) {
    return {
      ok: false,
      error: "kind must be one of text | question | linkToWebCard | reminder",
    }
  }
  if (typeof b.body !== "string" || b.body.trim() === "") {
    return { ok: false, error: "body is required and must be non-empty" }
  }

  let quickReplies: string[] | null = null
  if (b.quickReplies !== undefined && b.quickReplies !== null) {
    if (
      !Array.isArray(b.quickReplies) ||
      !b.quickReplies.every((v) => typeof v === "string")
    ) {
      return { ok: false, error: "quickReplies must be an array of strings" }
    }
    quickReplies = b.quickReplies as string[]
  }

  let webCardURL: string | null = null
  if (kind === "linkToWebCard") {
    if (typeof b.webCardURL !== "string" || b.webCardURL.trim() === "") {
      return { ok: false, error: "webCardURL is required for linkToWebCard" }
    }
    webCardURL = b.webCardURL
  } else if (typeof b.webCardURL === "string" && b.webCardURL.trim() !== "") {
    webCardURL = b.webCardURL
  }

  let reminderDueAt: string | null = null
  if (kind === "reminder") {
    const due =
      typeof b.dueAt === "string"
        ? b.dueAt
        : typeof (b.reminder as Record<string, unknown> | undefined)?.dueAt === "string"
          ? ((b.reminder as Record<string, unknown>).dueAt as string)
          : null
    if (!due) {
      return { ok: false, error: "dueAt is required for reminder" }
    }
    // Normalize to ISO-8601 (or null if unparseable) — never store a raw string
    // like "tomorrow 5pm", which breaks the client's Date decode.
    reminderDueAt = normalizeDueAt(due)
  }

  const push = b.push === true

  return {
    ok: true,
    value: { kind: kind as MessageKind, body: b.body, quickReplies, webCardURL, reminderDueAt, push },
  }
}
