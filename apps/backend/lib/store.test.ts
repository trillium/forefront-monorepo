/**
 * Unit coverage for lib/store.ts. Each test runs against a fresh `:memory:` DB
 * via `_resetForTest`, so cases are isolated and never touch the filesystem.
 *
 * Run: bun test
 */

import { beforeEach, describe, expect, test } from "bun:test"
import {
  _resetForTest,
  appendMessage,
  appendUserMessageIdempotent,
  bumpDeckVersion,
  clearUnread,
  createHumanChat,
  DEFAULT_CHAT_ID,
  deleteCard,
  ensureChat,
  enqueuePush,
  getChat,
  getDeckVersion,
  getInbox,
  getMessages,
  listCards,
  listChats,
  listPushes,
  parseCursor,
  upsertCard,
} from "./store"

beforeEach(() => {
  _resetForTest(":memory:")
})

describe("chats", () => {
  test("ensureChat mints an id when none given", () => {
    const chat = ensureChat({ title: "Reminders", topic: "reminders" })
    expect(chat.id).toMatch(/^ch_/)
    expect(chat.title).toBe("Reminders")
    expect(chat.topic).toBe("reminders")
    expect(getChat(chat.id)).not.toBeNull()
  })

  test("ensureChat is idempotent on a provided id and updates title/topic", () => {
    const a = ensureChat({ id: "ch_x", title: "First" })
    const b = ensureChat({ id: "ch_x", title: "Renamed", topic: "questions" })
    expect(b.id).toBe(a.id)
    expect(b.title).toBe("Renamed")
    expect(b.topic).toBe("questions")
    // Only one non-default chat exists (ch_general is always seeded).
    expect(listChats().filter((c) => c.id !== DEFAULT_CHAT_ID).length).toBe(1)
  })

  test("ensureChat on existing id without fields preserves them", () => {
    ensureChat({ id: "ch_x", title: "Keep", topic: "reminders" })
    const again = ensureChat({ id: "ch_x" })
    expect(again.title).toBe("Keep")
    expect(again.topic).toBe("reminders")
  })

  test("listChats orders most-recently-active first with preview + unread", () => {
    const older = ensureChat({ id: "ch_old", title: "Old" })
    const newer = ensureChat({ id: "ch_new", title: "New" })
    appendMessage({ chatId: older.id, role: "agent", kind: "text", body: "old msg" })
    appendMessage({ chatId: newer.id, role: "agent", kind: "text", body: "new msg" })

    const chats = listChats()
    expect(chats[0]!.id).toBe("ch_new")
    expect(chats[0]!.lastMessagePreview).toBe("new msg")
    expect(chats[0]!.unreadCount).toBe(1)
    expect(chats[1]!.id).toBe("ch_old")
  })
})

describe("default thread + human-started chats", () => {
  test("ch_general is seeded and always present", () => {
    expect(getChat(DEFAULT_CHAT_ID)).not.toBeNull()
    // GET /chats is never a dead end: at least the default thread is listed.
    expect(listChats().some((c) => c.id === DEFAULT_CHAT_ID)).toBe(true)
  })

  test("createHumanChat is idempotent on clientChatId", () => {
    const first = createHumanChat({ clientChatId: "cc-1", title: "Trip planning" })
    expect(first.created).toBe(true)
    expect(first.chat.title).toBe("Trip planning")

    const repeat = createHumanChat({ clientChatId: "cc-1", title: "Different" })
    expect(repeat.created).toBe(false)
    expect(repeat.chat.id).toBe(first.chat.id)
    // Title is the originally-created one, not the retry's.
    expect(repeat.chat.title).toBe("Trip planning")
  })

  test("unsolicited human message to ch_general surfaces in the agent inbox", () => {
    // No agent-initiated conversation — human just writes to the default thread.
    appendUserMessageIdempotent({
      chatId: DEFAULT_CHAT_ID,
      body: "hey, can you help me?",
      clientMessageId: "unsolicited-1",
    })
    const inbox = getInbox(null)
    expect(inbox.messages.map((m) => m.body)).toContain("hey, can you help me?")
    expect(inbox.messages.find((m) => m.body === "hey, can you help me?")!.chatId).toBe(
      DEFAULT_CHAT_ID,
    )
  })
})

describe("messages + cursors", () => {
  test("agent message increments unread; user message does not", () => {
    const c = ensureChat({ id: "ch_a", title: "A" })
    appendMessage({ chatId: c.id, role: "agent", kind: "text", body: "hi" })
    expect(listChats()[0]!.unreadCount).toBe(1)
    appendMessage({ chatId: c.id, role: "user", kind: "text", body: "reply" })
    // getMessages clears unread on read, so check before reading:
    expect(listChats()[0]!.unreadCount).toBe(1)
  })

  test("getMessages returns oldest→newest and advances the cursor", () => {
    const c = ensureChat({ id: "ch_a", title: "A" })
    const m1 = appendMessage({ chatId: c.id, role: "agent", kind: "text", body: "one" })
    const m2 = appendMessage({ chatId: c.id, role: "agent", kind: "text", body: "two" })

    const first = getMessages(c.id, null)
    expect(first.messages.map((m) => m.body)).toEqual(["one", "two"])
    expect(first.messages[0]!.id).toBe(m1.id)
    expect(first.nextCursor).toBe(m2.cursor)

    // Nothing new since the last cursor.
    const second = getMessages(c.id, first.nextCursor)
    expect(second.messages.length).toBe(0)
    expect(second.nextCursor).toBe(first.nextCursor)

    // A new message shows up on the next incremental fetch.
    const m3 = appendMessage({ chatId: c.id, role: "agent", kind: "text", body: "three" })
    const third = getMessages(c.id, second.nextCursor)
    expect(third.messages.map((m) => m.body)).toEqual(["three"])
    expect(third.nextCursor).toBe(m3.cursor)
  })

  test("getMessages clears unread on read", () => {
    const c = ensureChat({ id: "ch_a", title: "A" })
    appendMessage({ chatId: c.id, role: "agent", kind: "text", body: "hi" })
    getMessages(c.id, null)
    expect(listChats()[0]!.unreadCount).toBe(0)
  })

  test("limit paginates and preserves order", () => {
    const c = ensureChat({ id: "ch_a", title: "A" })
    for (let i = 0; i < 5; i++) {
      appendMessage({ chatId: c.id, role: "agent", kind: "text", body: `m${i}` })
    }
    const page1 = getMessages(c.id, null, 2)
    expect(page1.messages.map((m) => m.body)).toEqual(["m0", "m1"])
    const page2 = getMessages(c.id, page1.nextCursor, 2)
    expect(page2.messages.map((m) => m.body)).toEqual(["m2", "m3"])
    const page3 = getMessages(c.id, page2.nextCursor, 2)
    expect(page3.messages.map((m) => m.body)).toEqual(["m4"])
  })

  test("kind-specific fields serialize round-trip", () => {
    const c = ensureChat({ id: "ch_a", title: "A" })
    appendMessage({
      chatId: c.id,
      role: "agent",
      kind: "question",
      body: "Booked?",
      quickReplies: ["Yes", "No"],
    })
    appendMessage({
      chatId: c.id,
      role: "agent",
      kind: "linkToWebCard",
      body: "Fill this",
      webCardURL: "https://example.ts.net/forms/x",
    })
    appendMessage({
      chatId: c.id,
      role: "agent",
      kind: "reminder",
      body: "Due Friday",
      reminderDueAt: "2026-07-11T17:00:00Z",
    })
    const { messages } = getMessages(c.id, null)
    expect(messages[0]!.quickReplies).toEqual(["Yes", "No"])
    expect(messages[0]!.reminder).toBeNull()
    expect(messages[1]!.webCardURL).toBe("https://example.ts.net/forms/x")
    expect(messages[2]!.reminder).toEqual({ dueAt: "2026-07-11T17:00:00Z" })
  })
})

describe("idempotency", () => {
  test("same clientMessageId dedups and returns the first message", () => {
    const c = ensureChat({ id: "ch_a", title: "A" })
    const first = appendUserMessageIdempotent({
      chatId: c.id,
      body: "Booked it",
      clientMessageId: "cid-1",
    })
    expect(first.created).toBe(true)

    const repeat = appendUserMessageIdempotent({
      chatId: c.id,
      body: "Booked it (retry)",
      clientMessageId: "cid-1",
    })
    expect(repeat.created).toBe(false)
    expect(repeat.message.id).toBe(first.message.id)
    // Body is the originally-accepted one, not the retry body.
    expect(repeat.message.body).toBe("Booked it")

    // Only one message landed.
    expect(getMessages(c.id, null).messages.length).toBe(1)
  })

  test("same clientMessageId in different chats does not collide", () => {
    const a = ensureChat({ id: "ch_a", title: "A" })
    const b = ensureChat({ id: "ch_b", title: "B" })
    const inA = appendUserMessageIdempotent({ chatId: a.id, body: "x", clientMessageId: "cid" })
    const inB = appendUserMessageIdempotent({ chatId: b.id, body: "y", clientMessageId: "cid" })
    expect(inA.created).toBe(true)
    expect(inB.created).toBe(true)
    expect(inA.message.id).not.toBe(inB.message.id)
  })
})

describe("inbox read-back", () => {
  test("returns only user messages across all chats, oldest→newest", () => {
    const a = ensureChat({ id: "ch_a", title: "A" })
    const b = ensureChat({ id: "ch_b", title: "B" })
    appendMessage({ chatId: a.id, role: "agent", kind: "question", body: "Q1" })
    appendUserMessageIdempotent({ chatId: a.id, body: "Yes", clientMessageId: "c1" })
    appendMessage({ chatId: b.id, role: "agent", kind: "question", body: "Q2" })
    appendUserMessageIdempotent({ chatId: b.id, body: "No", clientMessageId: "c2" })

    const inbox = getInbox(null)
    expect(inbox.messages.map((m) => m.body)).toEqual(["Yes", "No"])
    expect(inbox.messages.every((m) => m.role === "user")).toBe(true)

    // Incremental: nothing new since the cursor.
    const next = getInbox(inbox.nextCursor)
    expect(next.messages.length).toBe(0)

    // A new answer surfaces.
    appendUserMessageIdempotent({ chatId: a.id, body: "Later", clientMessageId: "c3" })
    const after = getInbox(inbox.nextCursor)
    expect(after.messages.map((m) => m.body)).toEqual(["Later"])
  })

  test("empty inbox echoes the incoming cursor as nextCursor", () => {
    const inbox = getInbox("c_7")
    expect(inbox.messages.length).toBe(0)
    expect(inbox.nextCursor).toBe("c_7")
  })
})

describe("cards + deck version", () => {
  test("upsertCard inserts, listCards orders by priority then recency", () => {
    const first = upsertCard({ url: "https://a", title: "A", priority: 2 })
    upsertCard({ url: "https://b", title: "B", priority: 0 })
    upsertCard({ url: "https://c", title: "C", priority: 1 })
    const cards = listCards()
    expect(cards.map((c) => c.title)).toEqual(["B", "C", "A"])
    expect(first.id).toMatch(/^c_/)
  })

  test("upsertCard on same id updates in place and preserves createdAt", () => {
    const a = upsertCard({ id: "c_fixed", url: "https://a", title: "A" })
    const b = upsertCard({ id: "c_fixed", url: "https://a2", title: "A2", priority: 5 })
    expect(b.createdAt).toBe(a.createdAt)
    expect(b.url).toBe("https://a2")
    expect(listCards().length).toBe(1)
  })

  test("deleteCard removes and reports whether a row was hit", () => {
    upsertCard({ id: "c_x", url: "https://x", title: "X" })
    expect(deleteCard("c_x")).toBe(true)
    expect(deleteCard("c_x")).toBe(false)
    expect(listCards().length).toBe(0)
  })

  test("mutations bump the deck version; deleting a missing card does not", () => {
    const v0 = getDeckVersion()
    upsertCard({ id: "c_x", url: "https://x", title: "X" })
    const v1 = getDeckVersion()
    expect(Number(v1)).toBeGreaterThan(Number(v0))

    deleteCard("c_missing")
    expect(getDeckVersion()).toBe(v1)

    deleteCard("c_x")
    expect(Number(getDeckVersion())).toBeGreaterThan(Number(v1))
  })

  test("bumpDeckVersion is monotonic and persisted in meta", () => {
    expect(getDeckVersion()).toBe("1")
    expect(bumpDeckVersion()).toBe("2")
    expect(getDeckVersion()).toBe("2")
  })
})

describe("pushes", () => {
  test("enqueuePush stores a record; listPushes pages it", () => {
    const c = ensureChat({ id: "ch_a", title: "A" })
    const m = appendMessage({
      chatId: c.id,
      role: "agent",
      kind: "reminder",
      body: "Due",
      reminderDueAt: "2026-07-11T17:00:00Z",
    })
    const push = enqueuePush({
      chatId: c.id,
      messageId: m.id,
      category: "FF_REMINDER",
      title: "Reminder",
      body: "Due",
      quickReplies: ["Done", "Snooze"],
    })
    expect(push.id).toMatch(/^p_/)

    const all = listPushes(null)
    expect(all.pushes.length).toBe(1)
    expect(all.pushes[0]!.category).toBe("FF_REMINDER")
    expect(all.pushes[0]!.quickReplies).toEqual(["Done", "Snooze"])

    const after = listPushes(all.nextCursor)
    expect(after.pushes.length).toBe(0)
  })
})

describe("parseCursor", () => {
  test("accepts c_-prefixed, bare ints, and defaults junk to 0", () => {
    expect(parseCursor("c_42")).toBe(42)
    expect(parseCursor("42")).toBe(42)
    expect(parseCursor(null)).toBe(0)
    expect(parseCursor(undefined)).toBe(0)
    expect(parseCursor("")).toBe(0)
    expect(parseCursor("garbage")).toBe(0)
    expect(parseCursor("c_-5")).toBe(0)
  })
})

describe("clearUnread", () => {
  test("resets the tally", () => {
    const c = ensureChat({ id: "ch_a", title: "A" })
    appendMessage({ chatId: c.id, role: "agent", kind: "text", body: "hi" })
    expect(listChats()[0]!.unreadCount).toBe(1)
    clearUnread(c.id)
    expect(listChats()[0]!.unreadCount).toBe(0)
  })
})
