#!/usr/bin/env bun
/**
 * `forefront` — the DA-ergonomic CLI over the backend's `/agent/*` surface.
 *
 * PAI is CLI-first: the assistant curates the deck, starts threads, asks
 * questions, and reads human answers through these verbs rather than hand-rolled
 * curl. Every call uses the agent key (`FOREFRONT_AGENT_TOKEN`) against the
 * local server (`FOREFRONT_BASE_URL`, default the dev port from .env).
 *
 * Usage:
 *   forefront card add   <url> --title <t> [--priority <n>] [--ttl <s>] [--id <id>]
 *   forefront card list
 *   forefront card rm    <id>
 *   forefront chat create --title <t> [--topic <x>] [--id <id>]
 *   forefront say        <chatId> <text>
 *   forefront ask        <chatId> <question> --replies a,b,c [--push]
 *   forefront remind     <chatId> <text> --due <when> [--push]
 *   forefront inbox      [--since <cursor>]
 *   forefront pushes     [--since <cursor>]
 *
 * Env:
 *   FOREFRONT_BASE_URL    default http://127.0.0.1:<PORT|9238>
 *   FOREFRONT_AGENT_TOKEN default dev-agent-token
 */

const AGENT_TOKEN = process.env.FOREFRONT_AGENT_TOKEN ?? "dev-agent-token"
const BASE_URL =
  process.env.FOREFRONT_BASE_URL ??
  `http://127.0.0.1:${process.env.PORT ?? "9238"}`

// ── Arg parsing ──────────────────────────────────────────────────────────────

interface ParsedArgs {
  positionals: string[]
  flags: Record<string, string | boolean>
}

/** Split argv into positionals and `--flag [value]` pairs (bare flag → true). */
function parseArgs(argv: string[]): ParsedArgs {
  const positionals: string[] = []
  const flags: Record<string, string | boolean> = {}
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!
    if (arg.startsWith("--")) {
      const name = arg.slice(2)
      const next = argv[i + 1]
      if (next !== undefined && !next.startsWith("--")) {
        flags[name] = next
        i++
      } else {
        flags[name] = true
      }
    } else {
      positionals.push(arg)
    }
  }
  return { positionals, flags }
}

function flagStr(flags: Record<string, string | boolean>, name: string): string | undefined {
  const v = flags[name]
  return typeof v === "string" ? v : undefined
}

// ── HTTP ─────────────────────────────────────────────────────────────────────

/** Call the backend with the agent key; exits non-zero on a non-2xx response. */
async function call(
  method: string,
  path: string,
  body?: unknown,
): Promise<unknown> {
  let res: Response
  try {
    res = await fetch(`${BASE_URL}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${AGENT_TOKEN}`,
        ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
      },
      body: body !== undefined ? JSON.stringify(body) : undefined,
    })
  } catch (err) {
    fail(
      `could not reach ${BASE_URL} — is the backend running? (bun run dev)\n  ${String(err)}`,
    )
  }
  const text = await res.text()
  let parsed: unknown = text
  try {
    parsed = text ? JSON.parse(text) : null
  } catch {
    // Non-JSON body; leave as text.
  }
  if (!res.ok) {
    const detail =
      parsed && typeof parsed === "object" && "error" in parsed
        ? (parsed as { error: unknown }).error
        : text
    fail(`${method} ${path} → ${res.status}: ${detail}`)
  }
  return parsed
}

function fail(message: string): never {
  console.error(`✗ ${message}`)
  process.exit(1)
}

function print(value: unknown): void {
  console.log(JSON.stringify(value, null, 2))
}

// ── Verbs ────────────────────────────────────────────────────────────────────

function usage(): never {
  console.error(
    `forefront — agent CLI for the Forefront backend

  card add   <url> --title <t> [--priority <n>] [--ttl <s>] [--id <id>]
  card list
  card rm    <id>
  chat create --title <t> [--topic <x>] [--id <id>]
  say        <chatId> <text...>
  ask        <chatId> <question...> --replies a,b,c [--push]
  remind     <chatId> <text...> --due <when> [--push]
  inbox      [--since <cursor>]
  pushes     [--since <cursor>]

Env: FOREFRONT_BASE_URL (${BASE_URL}), FOREFRONT_AGENT_TOKEN`,
  )
  process.exit(2)
}

async function cmdCard(args: ParsedArgs): Promise<void> {
  const [sub, ...rest] = args.positionals
  if (sub === "add") {
    const url = rest[0]
    const title = flagStr(args.flags, "title")
    if (!url) fail("card add: <url> is required")
    if (!title) fail("card add: --title is required")
    const priorityRaw = flagStr(args.flags, "priority")
    const ttlRaw = flagStr(args.flags, "ttl")
    const body: Record<string, unknown> = { url, title }
    if (flagStr(args.flags, "id")) body.id = flagStr(args.flags, "id")
    if (priorityRaw !== undefined) body.priority = Number(priorityRaw)
    if (ttlRaw !== undefined) body.ttl = Number(ttlRaw)
    print(await call("POST", "/agent/cards", body))
  } else if (sub === "list") {
    print(await call("GET", "/agent/cards"))
  } else if (sub === "rm") {
    const id = rest[0]
    if (!id) fail("card rm: <id> is required")
    print(await call("DELETE", `/agent/cards/${encodeURIComponent(id)}`))
  } else {
    fail("card: expected add | list | rm")
  }
}

async function cmdChat(args: ParsedArgs): Promise<void> {
  const [sub] = args.positionals
  if (sub === "create") {
    const title = flagStr(args.flags, "title")
    if (!title) fail("chat create: --title is required")
    const body: Record<string, unknown> = { title }
    if (flagStr(args.flags, "topic")) body.topic = flagStr(args.flags, "topic")
    if (flagStr(args.flags, "id")) body.id = flagStr(args.flags, "id")
    print(await call("POST", "/agent/chats", body))
  } else {
    fail("chat: expected create")
  }
}

/** Join the trailing positionals (after the chatId) into one text body. */
function joinText(positionals: string[], from: number): string {
  return positionals.slice(from).join(" ")
}

async function cmdSay(args: ParsedArgs): Promise<void> {
  const chatId = args.positionals[0]
  const text = joinText(args.positionals, 1)
  if (!chatId) fail("say: <chatId> is required")
  if (!text) fail("say: <text> is required")
  print(
    await call("POST", `/agent/chats/${encodeURIComponent(chatId)}/messages`, {
      kind: "text",
      body: text,
    }),
  )
}

async function cmdAsk(args: ParsedArgs): Promise<void> {
  const chatId = args.positionals[0]
  const question = joinText(args.positionals, 1)
  if (!chatId) fail("ask: <chatId> is required")
  if (!question) fail("ask: <question> is required")
  const repliesRaw = flagStr(args.flags, "replies")
  const quickReplies = repliesRaw
    ? repliesRaw.split(",").map((s) => s.trim()).filter(Boolean)
    : undefined
  const body: Record<string, unknown> = { kind: "question", body: question }
  if (quickReplies && quickReplies.length > 0) body.quickReplies = quickReplies
  if (args.flags.push === true) body.push = true
  print(
    await call("POST", `/agent/chats/${encodeURIComponent(chatId)}/messages`, body),
  )
}

async function cmdRemind(args: ParsedArgs): Promise<void> {
  const chatId = args.positionals[0]
  const text = joinText(args.positionals, 1)
  if (!chatId) fail("remind: <chatId> is required")
  if (!text) fail("remind: <text> is required")
  const due = flagStr(args.flags, "due")
  if (!due) fail("remind: --due <when> is required")
  const body: Record<string, unknown> = {
    kind: "reminder",
    body: text,
    dueAt: due,
  }
  if (args.flags.push === true) body.push = true
  print(
    await call("POST", `/agent/chats/${encodeURIComponent(chatId)}/messages`, body),
  )
}

async function cmdInbox(args: ParsedArgs): Promise<void> {
  const since = flagStr(args.flags, "since")
  const q = since ? `?since=${encodeURIComponent(since)}` : ""
  print(await call("GET", `/agent/inbox${q}`))
}

async function cmdPushes(args: ParsedArgs): Promise<void> {
  const since = flagStr(args.flags, "since")
  const q = since ? `?since=${encodeURIComponent(since)}` : ""
  print(await call("GET", `/agent/pushes${q}`))
}

// ── Dispatch ─────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const argv = process.argv.slice(2)
  const verb = argv[0]
  const args = parseArgs(argv.slice(1))

  switch (verb) {
    case "card":
      return cmdCard(args)
    case "chat":
      return cmdChat(args)
    case "say":
      return cmdSay(args)
    case "ask":
      return cmdAsk(args)
    case "remind":
      return cmdRemind(args)
    case "inbox":
      return cmdInbox(args)
    case "pushes":
      return cmdPushes(args)
    case "help":
    case "--help":
    case "-h":
    case undefined:
      usage()
    default:
      fail(`unknown command: ${verb}\nRun \`forefront help\` for usage.`)
  }
}

main().catch((err: unknown) => {
  fail(String(err))
})
