/**
 * The durable store behind chat + deck — the single seam where persistence lives.
 *
 * Backed by `bun:sqlite` (built into the Bun runtime, zero dependencies). A file
 * DB at `FOREFRONT_DB_PATH` (default `.data/forefront.db`, gitignored) survives
 * server restarts so a long device-test doesn't lose threads mid-flow. Callers go
 * through the exported functions — never the raw DB — so a hosted store can drop
 * in behind the same signatures later (mirrors `lib/deck.ts` and `lib/backend.ts`).
 *
 * Cursors: one global monotonic `seq` (autoincrement) totally orders every
 * message. `since=<cursor>` returns rows with `seq > cursor`. This single
 * mechanism drives both the per-thread consumer fetch (contract §9) and the
 * cross-thread agent inbox. See Docs/DECISIONS.md B-01/B-03.
 */

import type { Database } from "bun:sqlite"
import { mkdirSync } from "node:fs"
import { dirname, isAbsolute, resolve } from "node:path"

/**
 * Lazily resolve the `bun:sqlite` `Database` class.
 *
 * `next build` collects page data under **Node**, where `bun:sqlite` does not
 * exist — a top-level `import { Database } from "bun:sqlite"` would crash the
 * build the moment this module is imported, even though no DB is ever opened at
 * build time. A dynamic `require` inside the open path keeps the module
 * importable under Node (build) while still binding the real driver at request
 * time under Bun (`bun run dev`/`start`). See Docs/DECISIONS.md B-01.
 */
function loadDatabaseClass(): typeof Database {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const mod = require("bun:sqlite") as { Database: typeof Database }
  return mod.Database
}

// ── Domain types (shapes mirror Docs/BACKEND_CONTRACT.md §8–12) ──────────────

/** A chat thread. */
export interface Chat {
  id: string
  title: string
  topic: string | null
  createdAt: string
  lastMessageAt: string
}

export type MessageRole = "user" | "agent" | "system"
export type MessageKind = "text" | "question" | "linkToWebCard" | "reminder"

/** A single message row, already serialized for the API. */
export interface Message {
  /** Stable server id (`m_<seq>`). */
  id: string
  /** Opaque monotonic cursor for this row (`c_<seq>`). */
  cursor: string
  chatId: string
  role: MessageRole
  kind: MessageKind
  body: string
  createdAt: string
  /** Present on question/reminder kinds. */
  quickReplies: string[] | null
  /** Present on linkToWebCard kind. */
  webCardURL: string | null
  /** Present on reminder kind. */
  reminder: { dueAt: string } | null
  /** Echoed back to the consumer for optimistic reconciliation; null for agent-authored. */
  clientMessageId: string | null
}

/** A deck card, agent-curated. Shape mirrors lib/deck.ts `Card` (§3). */
export interface StoredCard {
  id: string
  url: string
  title: string
  priority: number
  createdAt: string
  updatedAt: string
  type: string
  ttl: number | null
}

/**
 * The per-device outcome of one APNs delivery attempt, recorded on the push so
 * the drain result is inspectable (contract §11, feat/apns-sender). `status` is
 * the APNs HTTP status (200 = accepted); `reason` is Apple's rejection reason
 * string when present (e.g. `BadDeviceToken`); `apnsId` is the `apns-id` header
 * Apple echoes for correlation. `error` is set when the send never reached Apple
 * (transport failure) rather than a non-200 APNs response.
 */
export interface PushDeliveryResult {
  /** APNs device token targeted (hex). */
  deviceToken: string
  status: number | null
  reason: string | null
  apnsId: string | null
  error: string | null
}

/**
 * An actionable-push record (§11). Records the push intent (recorded by
 * `enqueuePush`) plus its delivery state once the drain has run. `sent` is false
 * until the drain attempts delivery to every registered device.
 */
export interface PushRecord {
  id: string
  chatId: string
  messageId: string
  category: string
  title: string
  body: string
  quickReplies: string[] | null
  createdAt: string
  /** `seq`-based cursor so consumers can page pushes too. */
  cursor: string
  /** True once the drain has attempted delivery for this record. */
  sent: boolean
  /** ISO timestamp the record was marked sent, or null when still pending. */
  sentAt: string | null
  /** Per-device delivery outcomes recorded by the drain, or null when pending. */
  apnsResults: PushDeliveryResult[] | null
}

/** A registered APNs device token (§5). The drain targets every row here. */
export interface DeviceToken {
  deviceToken: string
  environment: string
  registeredAt: string
}

// ── DB bootstrap ─────────────────────────────────────────────────────────────

/**
 * Resolve the configured DB path against the repo root. An in-memory path
 * (`:memory:`) is passed through untouched so tests can run isolated.
 */
function resolveDbPath(): string {
  const configured = process.env.FOREFRONT_DB_PATH ?? ".data/forefront.db"
  if (configured === ":memory:") return configured
  return isAbsolute(configured) ? configured : resolve(process.cwd(), configured)
}

/**
 * Open (and migrate) a database at `path`. Exposed for tests, which pass
 * `:memory:` for a fresh isolated store per case. Production callers use the
 * module singleton via the exported ops below.
 */
export function openDatabase(path: string): Database {
  if (path !== ":memory:") {
    // Ensure the parent dir exists — bun:sqlite won't create it.
    mkdirSync(dirname(path), { recursive: true })
  }
  const DatabaseClass = loadDatabaseClass()
  const db = new DatabaseClass(path)
  // WAL keeps concurrent route-handler reads from blocking on a write.
  db.exec("PRAGMA journal_mode = WAL")
  db.exec("PRAGMA foreign_keys = ON")
  migrate(db)
  seedDefaults(db)
  return db
}

/** The always-present default thread. The inbox is never a dead end (§8). */
export const DEFAULT_CHAT_ID = "ch_general"
const DEFAULT_CHAT_TITLE = "Agent"

/**
 * Seed the well-known default thread so `GET /chats` always returns somewhere
 * the human can write, even before the agent has initiated any conversation.
 * Idempotent — INSERT OR IGNORE leaves an existing thread untouched.
 */
function seedDefaults(db: Database): void {
  const ts = nowISO()
  db.query(
    `INSERT OR IGNORE INTO chats (id, title, topic, created_at, last_message_at)
     VALUES (?, ?, ?, ?, ?)`,
  ).run(DEFAULT_CHAT_ID, DEFAULT_CHAT_TITLE, "general", ts, ts)
  db.query("INSERT OR IGNORE INTO unread (chat_id, count) VALUES (?, 0)").run(
    DEFAULT_CHAT_ID,
  )
}

/** Create tables if absent. Idempotent — safe to run on every open. */
function migrate(db: Database): void {
  db.exec(`
    CREATE TABLE IF NOT EXISTS chats (
      id             TEXT PRIMARY KEY,
      title          TEXT NOT NULL,
      topic          TEXT,
      created_at     TEXT NOT NULL,
      last_message_at TEXT NOT NULL,
      client_chat_id TEXT           -- idempotency key for human-started threads
    );

    -- Human-started threads dedup on client_chat_id (offline-retry safe).
    CREATE UNIQUE INDEX IF NOT EXISTS idx_chats_client_dedup
      ON chats(client_chat_id) WHERE client_chat_id IS NOT NULL;

    CREATE TABLE IF NOT EXISTS messages (
      seq              INTEGER PRIMARY KEY AUTOINCREMENT,
      id               TEXT NOT NULL UNIQUE,
      chat_id          TEXT NOT NULL REFERENCES chats(id),
      role             TEXT NOT NULL,
      kind             TEXT NOT NULL,
      body             TEXT NOT NULL,
      created_at       TEXT NOT NULL,
      quick_replies    TEXT,           -- JSON array or NULL
      web_card_url     TEXT,
      reminder_due_at  TEXT,
      client_message_id TEXT           -- NULL for agent-authored
    );

    -- Idempotency key for consumer sends: (chat_id, client_message_id) is unique.
    CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_client_dedup
      ON messages(chat_id, client_message_id)
      WHERE client_message_id IS NOT NULL;

    CREATE INDEX IF NOT EXISTS idx_messages_chat_seq ON messages(chat_id, seq);

    -- Per-thread unread tally, maintained on insert/read.
    CREATE TABLE IF NOT EXISTS unread (
      chat_id TEXT PRIMARY KEY REFERENCES chats(id),
      count   INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS cards (
      id         TEXT PRIMARY KEY,
      url        TEXT NOT NULL,
      title      TEXT NOT NULL,
      priority   INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      type       TEXT NOT NULL,
      ttl        INTEGER
    );

    CREATE TABLE IF NOT EXISTS pushes (
      seq           INTEGER PRIMARY KEY AUTOINCREMENT,
      id            TEXT NOT NULL UNIQUE,
      chat_id       TEXT NOT NULL,
      message_id    TEXT NOT NULL,
      category      TEXT NOT NULL,
      title         TEXT NOT NULL,
      body          TEXT NOT NULL,
      quick_replies TEXT,
      created_at    TEXT NOT NULL,
      -- Delivery leg (feat/apns-sender). A push record starts unsent; the drain
      -- marks it sent once every registered device has been attempted. sent = 0
      -- until then, so the drain is safely re-runnable and only touches new rows.
      sent          INTEGER NOT NULL DEFAULT 0,
      sent_at       TEXT,
      -- JSON array of per-device APNs results, for observability. NULL until sent.
      apns_results  TEXT
    );

    -- APNs device tokens, one row per token (upsert). The drain targets these.
    -- environment records which APNs host the token was minted against so a
    -- sandbox-built token is never blasted at the production gateway.
    CREATE TABLE IF NOT EXISTS device_tokens (
      device_token  TEXT PRIMARY KEY,
      environment   TEXT NOT NULL,
      registered_at TEXT NOT NULL
    );

    -- Single-row key/value for the deck version, so it survives restarts.
    CREATE TABLE IF NOT EXISTS meta (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
  `)

  // ── In-place migrations for stores created before feat/apns-sender ──────────
  // `CREATE TABLE IF NOT EXISTS` never alters an existing table, so a DB opened
  // by an older build keeps the pre-sender `pushes` shape. Add the delivery
  // columns idempotently. bun:sqlite has no `ADD COLUMN IF NOT EXISTS`, so probe
  // the schema first.
  addColumnIfMissing(db, "pushes", "sent", "INTEGER NOT NULL DEFAULT 0")
  addColumnIfMissing(db, "pushes", "sent_at", "TEXT")
  addColumnIfMissing(db, "pushes", "apns_results", "TEXT")
}

/**
 * Add `column` to `table` if a column of that name is not already present.
 * Idempotent DDL for evolving a store opened by an older build. `definition`
 * must supply a constant/NULL default (SQLite forbids non-constant ADD COLUMN
 * defaults), which every caller here satisfies.
 */
function addColumnIfMissing(
  db: Database,
  table: string,
  column: string,
  definition: string,
): void {
  const cols = db.query(`PRAGMA table_info(${table})`).all() as Array<{
    name: string
  }>
  if (cols.some((c) => c.name === column)) return
  db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${definition}`)
}

// Module singleton. Lazily opened so importing the module (e.g. during
// `next build` static analysis) never touches the filesystem.
let _db: Database | null = null

/** The shared production database, opened on first use. */
export function db(): Database {
  if (!_db) _db = openDatabase(resolveDbPath())
  return _db
}

/**
 * Reset the singleton to a fresh database at `path`. Test-only helper so cases
 * can point the module ops at an isolated `:memory:` store.
 */
export function _resetForTest(path = ":memory:"): Database {
  if (_db) _db.close()
  _db = openDatabase(path)
  return _db
}

// ── Row → API serialization ──────────────────────────────────────────────────

interface MessageRow {
  seq: number
  id: string
  chat_id: string
  role: string
  kind: string
  body: string
  created_at: string
  quick_replies: string | null
  web_card_url: string | null
  reminder_due_at: string | null
  client_message_id: string | null
}

function parseQuickReplies(raw: string | null): string[] | null {
  if (!raw) return null
  try {
    const parsed: unknown = JSON.parse(raw)
    if (Array.isArray(parsed) && parsed.every((v) => typeof v === "string")) {
      return parsed as string[]
    }
    return null
  } catch {
    return null
  }
}

function rowToMessage(row: MessageRow): Message {
  return {
    id: row.id,
    cursor: `c_${row.seq}`,
    chatId: row.chat_id,
    role: row.role as MessageRole,
    kind: row.kind as MessageKind,
    body: row.body,
    createdAt: row.created_at,
    quickReplies: parseQuickReplies(row.quick_replies),
    webCardURL: row.web_card_url,
    reminder: row.reminder_due_at ? { dueAt: row.reminder_due_at } : null,
    clientMessageId: row.client_message_id,
  }
}

/**
 * Parse a `since` cursor (`c_<n>` or a bare integer) into a numeric floor.
 * Anything unparseable → 0 (return from the beginning). The contract treats the
 * cursor as opaque, so we accept both forms defensively.
 */
export function parseCursor(since: string | null | undefined): number {
  if (!since) return 0
  const raw = since.startsWith("c_") ? since.slice(2) : since
  const n = Number.parseInt(raw, 10)
  return Number.isFinite(n) && n >= 0 ? n : 0
}

// ── ID + time helpers ────────────────────────────────────────────────────────

function nowISO(): string {
  return new Date().toISOString()
}

function randomId(prefix: string): string {
  return `${prefix}${crypto.randomUUID().replace(/-/g, "").slice(0, 12)}`
}

// ── Chat ops ─────────────────────────────────────────────────────────────────

/**
 * Create a thread, or return the existing one if `id` already exists (ensure
 * semantics). When ensuring an existing thread, a provided `title`/`topic`
 * updates it; omitted fields are left untouched.
 */
export function ensureChat(input: {
  id?: string
  title?: string
  topic?: string | null
}): Chat {
  const database = db()
  const id = input.id?.trim() || randomId("ch_")
  const existing = getChat(id)
  if (existing) {
    const title = input.title?.trim() || existing.title
    const topic = input.topic !== undefined ? input.topic : existing.topic
    database
      .query("UPDATE chats SET title = ?, topic = ? WHERE id = ?")
      .run(title, topic, id)
    return { ...existing, title, topic }
  }
  const title = input.title?.trim() || "Chat"
  const topic = input.topic ?? null
  const ts = nowISO()
  database
    .query(
      "INSERT INTO chats (id, title, topic, created_at, last_message_at) VALUES (?, ?, ?, ?, ?)",
    )
    .run(id, title, topic, ts, ts)
  database.query("INSERT INTO unread (chat_id, count) VALUES (?, 0)").run(id)
  return { id, title, topic, createdAt: ts, lastMessageAt: ts }
}

/**
 * Create a human-started thread idempotently on `clientChatId` (contract-style
 * offline-retry key, mirrors message `clientMessageId`). A repeat returns the
 * already-created thread. `created` is false on a dedup hit so the route can
 * pick 200 vs 201. This is human-initiated conversation — distinct from the
 * agent-initiated `ensureChat` path used by `POST /agent/chats`.
 */
export function createHumanChat(input: {
  clientChatId: string
  title?: string
}): { chat: Chat; created: boolean } {
  const database = db()
  const existing = findChatByClientId(input.clientChatId)
  if (existing) return { chat: existing, created: false }

  const id = randomId("ch_")
  const title = input.title?.trim() || "New Chat"
  const ts = nowISO()
  try {
    database
      .query(
        `INSERT INTO chats (id, title, topic, created_at, last_message_at, client_chat_id)
         VALUES (?, ?, ?, ?, ?, ?)`,
      )
      .run(id, title, null, ts, ts, input.clientChatId)
    database.query("INSERT INTO unread (chat_id, count) VALUES (?, 0)").run(id)
    return {
      chat: { id, title, topic: null, createdAt: ts, lastMessageAt: ts },
      created: true,
    }
  } catch (err) {
    // Lost a race on the unique index — return the winner.
    const raced = findChatByClientId(input.clientChatId)
    if (raced) return { chat: raced, created: false }
    throw err
  }
}

/** Look up a thread by its human idempotency key. */
export function findChatByClientId(clientChatId: string): Chat | null {
  const row = db()
    .query(
      "SELECT id, title, topic, created_at, last_message_at FROM chats WHERE client_chat_id = ?",
    )
    .get(clientChatId) as
    | {
        id: string
        title: string
        topic: string | null
        created_at: string
        last_message_at: string
      }
    | null
  if (!row) return null
  return {
    id: row.id,
    title: row.title,
    topic: row.topic,
    createdAt: row.created_at,
    lastMessageAt: row.last_message_at,
  }
}

/** Fetch one thread by id, or null. */
export function getChat(id: string): Chat | null {
  const row = db()
    .query(
      "SELECT id, title, topic, created_at, last_message_at FROM chats WHERE id = ?",
    )
    .get(id) as
    | {
        id: string
        title: string
        topic: string | null
        created_at: string
        last_message_at: string
      }
    | null
  if (!row) return null
  return {
    id: row.id,
    title: row.title,
    topic: row.topic,
    createdAt: row.created_at,
    lastMessageAt: row.last_message_at,
  }
}

/**
 * The inbox: every thread with its unread count and a preview of the newest
 * message, ordered most-recently-active first (contract §8).
 */
export function listChats(): Array<
  Chat & { unreadCount: number; lastMessagePreview: string | null }
> {
  // Order by the newest message's monotonic seq (not the ISO timestamp): two
  // messages can share a millisecond, and seq gives a stable total order. A
  // thread with no messages yet sorts by created_at then id. See B-03.
  const rows = db()
    .query(
      `SELECT
         c.id, c.title, c.topic, c.created_at, c.last_message_at,
         COALESCE(u.count, 0) AS unread_count,
         (SELECT body FROM messages m
            WHERE m.chat_id = c.id
            ORDER BY m.seq DESC LIMIT 1) AS preview,
         (SELECT MAX(m.seq) FROM messages m WHERE m.chat_id = c.id) AS last_seq
       FROM chats c
       LEFT JOIN unread u ON u.chat_id = c.id
       ORDER BY COALESCE(last_seq, -1) DESC, c.created_at DESC, c.id DESC`,
    )
    .all() as Array<{
    id: string
    title: string
    topic: string | null
    created_at: string
    last_message_at: string
    unread_count: number
    preview: string | null
    last_seq: number | null
  }>
  return rows.map((r) => ({
    id: r.id,
    title: r.title,
    topic: r.topic,
    createdAt: r.created_at,
    lastMessageAt: r.last_message_at,
    unreadCount: r.unread_count,
    lastMessagePreview: r.preview,
  }))
}

// ── Message ops ──────────────────────────────────────────────────────────────

interface AppendMessageInput {
  chatId: string
  role: MessageRole
  kind: MessageKind
  body: string
  quickReplies?: string[] | null
  webCardURL?: string | null
  reminderDueAt?: string | null
  clientMessageId?: string | null
}

/**
 * Append a message and bump the thread's `last_message_at`. `agent`/`system`
 * messages increment the thread's unread count (the human hasn't seen them);
 * `user` messages do not. Returns the serialized canonical message.
 *
 * Idempotency is the caller's job for consumer sends — use
 * `appendUserMessageIdempotent` which dedups on `clientMessageId` first.
 */
export function appendMessage(input: AppendMessageInput): Message {
  const database = db()
  const id = randomId("m_")
  const ts = nowISO()
  const quickReplies =
    input.quickReplies && input.quickReplies.length > 0
      ? JSON.stringify(input.quickReplies)
      : null

  const info = database
    .query(
      `INSERT INTO messages
         (id, chat_id, role, kind, body, created_at,
          quick_replies, web_card_url, reminder_due_at, client_message_id)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .run(
      id,
      input.chatId,
      input.role,
      input.kind,
      input.body,
      ts,
      quickReplies,
      input.webCardURL ?? null,
      input.reminderDueAt ?? null,
      input.clientMessageId ?? null,
    )

  database
    .query("UPDATE chats SET last_message_at = ? WHERE id = ?")
    .run(ts, input.chatId)

  // Unread counts messages the human hasn't seen — i.e. non-user messages.
  if (input.role !== "user") {
    database
      .query("UPDATE unread SET count = count + 1 WHERE chat_id = ?")
      .run(input.chatId)
  }

  const seq = Number(info.lastInsertRowid)
  return rowToMessage({
    seq,
    id,
    chat_id: input.chatId,
    role: input.role,
    kind: input.kind,
    body: input.body,
    created_at: ts,
    quick_replies: quickReplies,
    web_card_url: input.webCardURL ?? null,
    reminder_due_at: input.reminderDueAt ?? null,
    client_message_id: input.clientMessageId ?? null,
  })
}

/**
 * Append a consumer-authored `user` message idempotently on
 * `(chatId, clientMessageId)`. A repeat with the same id returns the
 * already-accepted message instead of inserting a duplicate (contract §10).
 * `created` is false on a dedup hit so the route can pick 200 vs 201.
 */
export function appendUserMessageIdempotent(input: {
  chatId: string
  body: string
  clientMessageId: string
  kind?: MessageKind
}): { message: Message; created: boolean } {
  const existing = findByClientMessageId(input.chatId, input.clientMessageId)
  if (existing) return { message: existing, created: false }

  try {
    const message = appendMessage({
      chatId: input.chatId,
      role: "user",
      kind: input.kind ?? "text",
      body: input.body,
      clientMessageId: input.clientMessageId,
    })
    return { message, created: true }
  } catch (err) {
    // A concurrent request may have inserted the same key between our check and
    // insert; the unique index throws. Re-read and return the winner.
    const raced = findByClientMessageId(input.chatId, input.clientMessageId)
    if (raced) return { message: raced, created: false }
    throw err
  }
}

/** Look up a message by its consumer idempotency key. */
export function findByClientMessageId(
  chatId: string,
  clientMessageId: string,
): Message | null {
  const row = db()
    .query(
      `SELECT * FROM messages WHERE chat_id = ? AND client_message_id = ?`,
    )
    .get(chatId, clientMessageId) as MessageRow | null
  return row ? rowToMessage(row) : null
}

/**
 * Incremental fetch for one thread: messages with `seq > since`, oldest→newest,
 * capped at `limit`. Returns the page and the `nextCursor` (the newest row's
 * cursor, or the incoming `since` echoed back when the page is empty).
 * Reading a thread clears its unread count (contract §8/§9).
 */
export function getMessages(
  chatId: string,
  since: string | null | undefined,
  limit = 100,
): { messages: Message[]; nextCursor: string } {
  const floor = parseCursor(since)
  const rows = db()
    .query(
      `SELECT * FROM messages
         WHERE chat_id = ? AND seq > ?
         ORDER BY seq ASC
         LIMIT ?`,
    )
    .all(chatId, floor, limit) as MessageRow[]

  const messages = rows.map(rowToMessage)
  const nextCursor =
    messages.length > 0 ? messages[messages.length - 1]!.cursor : `c_${floor}`

  // Reading the thread marks it caught up.
  clearUnread(chatId)
  return { messages, nextCursor }
}

/** Reset a thread's unread tally to zero. */
export function clearUnread(chatId: string): void {
  db().query("UPDATE unread SET count = 0 WHERE chat_id = ?").run(chatId)
}

/**
 * The agent read-back loop: every human-authored (`role = user`) message across
 * all threads with `seq > since`, oldest→newest. Quick-reply taps arrive as
 * `user`/`text` (contract §9/§11) so they surface here too. Closes the
 * agent-asks → human-answers → agent-reads cycle.
 */
export function getInbox(
  since: string | null | undefined,
  limit = 200,
): { messages: Message[]; nextCursor: string } {
  const floor = parseCursor(since)
  const rows = db()
    .query(
      `SELECT * FROM messages
         WHERE role = 'user' AND seq > ?
         ORDER BY seq ASC
         LIMIT ?`,
    )
    .all(floor, limit) as MessageRow[]
  const messages = rows.map(rowToMessage)
  const nextCursor =
    messages.length > 0 ? messages[messages.length - 1]!.cursor : `c_${floor}`
  return { messages, nextCursor }
}

// ── Card ops ─────────────────────────────────────────────────────────────────

/**
 * Upsert a deck card. Provided id updates in place; omitted id mints a new one.
 * Bumps the deck version so the client refetches. Returns the stored card.
 */
export function upsertCard(input: {
  id?: string
  url: string
  title: string
  priority?: number
  type?: string
  ttl?: number | null
}): StoredCard {
  const database = db()
  const id = input.id?.trim() || randomId("c_")
  const existing = database
    .query("SELECT created_at FROM cards WHERE id = ?")
    .get(id) as { created_at: string } | null
  const now = nowISO()
  const createdAt = existing?.created_at ?? now
  const card: StoredCard = {
    id,
    url: input.url,
    title: input.title,
    priority: input.priority ?? 0,
    createdAt,
    updatedAt: now,
    type: input.type ?? "web",
    ttl: input.ttl ?? null,
  }
  database
    .query(
      `INSERT INTO cards (id, url, title, priority, created_at, updated_at, type, ttl)
       VALUES ($id, $url, $title, $priority, $created_at, $updated_at, $type, $ttl)
       ON CONFLICT(id) DO UPDATE SET
         url = $url, title = $title, priority = $priority,
         updated_at = $updated_at, type = $type, ttl = $ttl`,
    )
    .run({
      $id: card.id,
      $url: card.url,
      $title: card.title,
      $priority: card.priority,
      $created_at: card.createdAt,
      $updated_at: card.updatedAt,
      $type: card.type,
      $ttl: card.ttl,
    })
  bumpDeckVersion()
  return card
}

/** Delete a card by id. Bumps the deck version iff a row was removed. */
export function deleteCard(id: string): boolean {
  const info = db().query("DELETE FROM cards WHERE id = ?").run(id)
  const removed = info.changes > 0
  if (removed) bumpDeckVersion()
  return removed
}

/**
 * Agent-curated deck, ordered front-of-deck first (lowest priority first, then
 * newest). Empty array means the store has no curated cards — callers fall back
 * to fixtures (Docs/DECISIONS.md B-05).
 */
export function listCards(): StoredCard[] {
  const rows = db()
    .query(
      `SELECT id, url, title, priority, created_at, updated_at, type, ttl
         FROM cards
         ORDER BY priority ASC, updated_at DESC`,
    )
    .all() as Array<{
    id: string
    url: string
    title: string
    priority: number
    created_at: string
    updated_at: string
    type: string
    ttl: number | null
  }>
  return rows.map((r) => ({
    id: r.id,
    url: r.url,
    title: r.title,
    priority: r.priority,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
    type: r.type,
    ttl: r.ttl,
  }))
}

// ── Deck version (persisted so it survives restarts) ─────────────────────────

/** Current deck version string. Defaults to "1" before any bump. */
export function getDeckVersion(): string {
  const row = db()
    .query("SELECT value FROM meta WHERE key = 'deck_version'")
    .get() as { value: string } | null
  return row?.value ?? "1"
}

/** Increment and persist the deck version, returning the new value. */
export function bumpDeckVersion(): string {
  const next = String(Number(getDeckVersion()) + 1)
  db()
    .query(
      `INSERT INTO meta (key, value) VALUES ('deck_version', ?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
    )
    .run(next)
  return next
}

// ── Push ops (record + delivery state; sending lives in lib/apns.ts) ─────────

/** Raw `pushes` row shape shared by the read paths. */
interface PushRow {
  seq: number
  id: string
  chat_id: string
  message_id: string
  category: string
  title: string
  body: string
  quick_replies: string | null
  created_at: string
  sent: number
  sent_at: string | null
  apns_results: string | null
}

/** Parse the stored `apns_results` JSON back into typed delivery results. */
function parseApnsResults(raw: string | null): PushDeliveryResult[] | null {
  if (!raw) return null
  try {
    const parsed: unknown = JSON.parse(raw)
    if (!Array.isArray(parsed)) return null
    return parsed as PushDeliveryResult[]
  } catch {
    return null
  }
}

function rowToPush(r: PushRow): PushRecord {
  return {
    id: r.id,
    chatId: r.chat_id,
    messageId: r.message_id,
    category: r.category,
    title: r.title,
    body: r.body,
    quickReplies: parseQuickReplies(r.quick_replies),
    createdAt: r.created_at,
    cursor: `c_${r.seq}`,
    sent: r.sent === 1,
    sentAt: r.sent_at,
    apnsResults: parseApnsResults(r.apns_results),
  }
}

/** Enqueue an actionable-push record for a reminder/question message (§11). */
export function enqueuePush(input: {
  chatId: string
  messageId: string
  category: string
  title: string
  body: string
  quickReplies?: string[] | null
}): PushRecord {
  const database = db()
  const id = randomId("p_")
  const ts = nowISO()
  const quickReplies =
    input.quickReplies && input.quickReplies.length > 0
      ? JSON.stringify(input.quickReplies)
      : null
  const info = database
    .query(
      `INSERT INTO pushes
         (id, chat_id, message_id, category, title, body, quick_replies, created_at, sent)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)`,
    )
    .run(
      id,
      input.chatId,
      input.messageId,
      input.category,
      input.title,
      input.body,
      quickReplies,
      ts,
    )
  return {
    id,
    chatId: input.chatId,
    messageId: input.messageId,
    category: input.category,
    title: input.title,
    body: input.body,
    quickReplies: parseQuickReplies(quickReplies),
    createdAt: ts,
    cursor: `c_${Number(info.lastInsertRowid)}`,
    sent: false,
    sentAt: null,
    apnsResults: null,
  }
}

/** List actionable-push records with `seq > since`, oldest→newest. */
export function listPushes(
  since: string | null | undefined,
  limit = 200,
): { pushes: PushRecord[]; nextCursor: string } {
  const floor = parseCursor(since)
  const rows = db()
    .query(
      `SELECT seq, id, chat_id, message_id, category, title, body, quick_replies,
              created_at, sent, sent_at, apns_results
         FROM pushes WHERE seq > ? ORDER BY seq ASC LIMIT ?`,
    )
    .all(floor, limit) as PushRow[]
  const pushes = rows.map(rowToPush)
  const nextCursor =
    pushes.length > 0 ? pushes[pushes.length - 1]!.cursor : `c_${floor}`
  return { pushes, nextCursor }
}

/**
 * Unsent push records, oldest→newest. The drain reads these, delivers each to
 * every registered device, then calls `markPushSent`. Because only `sent = 0`
 * rows are returned, a re-run after a partial or full drain never re-sends an
 * already-delivered record.
 */
export function listUnsentPushes(limit = 500): PushRecord[] {
  const rows = db()
    .query(
      `SELECT seq, id, chat_id, message_id, category, title, body, quick_replies,
              created_at, sent, sent_at, apns_results
         FROM pushes WHERE sent = 0 ORDER BY seq ASC LIMIT ?`,
    )
    .all(limit) as PushRow[]
  return rows.map(rowToPush)
}

/** Count push records still awaiting a drain. Cheap status probe. */
export function countUnsentPushes(): number {
  const row = db()
    .query("SELECT COUNT(*) AS n FROM pushes WHERE sent = 0")
    .get() as { n: number }
  return row.n
}

/**
 * Mark a push record delivered, recording the per-device APNs results. Called by
 * the drain after every registered device has been attempted. Idempotent: a
 * second call just overwrites the results with the newer attempt's outcome.
 */
export function markPushSent(
  pushId: string,
  results: PushDeliveryResult[],
): void {
  db()
    .query(
      "UPDATE pushes SET sent = 1, sent_at = ?, apns_results = ? WHERE id = ?",
    )
    .run(nowISO(), JSON.stringify(results), pushId)
}

// ── Device-token ops (§5) ────────────────────────────────────────────────────

/**
 * Register (upsert) an APNs device token. A repeat POST of the same token
 * refreshes its environment + timestamp rather than duplicating the row. The
 * drain sends to every token here.
 */
export function upsertDeviceToken(input: {
  deviceToken: string
  environment?: string
}): DeviceToken {
  const environment = input.environment?.trim() || "sandbox"
  const registeredAt = nowISO()
  db()
    .query(
      `INSERT INTO device_tokens (device_token, environment, registered_at)
       VALUES (?, ?, ?)
       ON CONFLICT(device_token) DO UPDATE SET
         environment = excluded.environment,
         registered_at = excluded.registered_at`,
    )
    .run(input.deviceToken, environment, registeredAt)
  return { deviceToken: input.deviceToken, environment, registeredAt }
}

/** Every registered device token, newest registration first. */
export function listDeviceTokens(): DeviceToken[] {
  const rows = db()
    .query(
      `SELECT device_token, environment, registered_at
         FROM device_tokens ORDER BY registered_at DESC`,
    )
    .all() as Array<{
    device_token: string
    environment: string
    registered_at: string
  }>
  return rows.map((r) => ({
    deviceToken: r.device_token,
    environment: r.environment,
    registeredAt: r.registered_at,
  }))
}

/** Count registered device tokens. Cheap status probe. */
export function countDeviceTokens(): number {
  const row = db()
    .query("SELECT COUNT(*) AS n FROM device_tokens")
    .get() as { n: number }
  return row.n
}
