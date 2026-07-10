import { expect, test, describe } from "bun:test"
import { normalizeDueAt, parseAgentSend } from "./chat"

// A fixed reference point so relative parsing is deterministic.
// 2026-07-09T18:00:00 local (a Thursday).
const NOW = new Date("2026-07-09T18:00:00")

describe("normalizeDueAt", () => {
  test("passes ISO-8601 through as canonical ISO", () => {
    const iso = "2026-07-12T17:00:00.000Z"
    expect(normalizeDueAt(iso, NOW)).toBe(new Date(iso).toISOString())
  })

  test("parses 'in N minutes/hours/days' relative to now", () => {
    expect(normalizeDueAt("in 30 min", NOW)).toBe(new Date(NOW.getTime() + 30 * 60_000).toISOString())
    expect(normalizeDueAt("in 1 hour", NOW)).toBe(new Date(NOW.getTime() + 3_600_000).toISOString())
    expect(normalizeDueAt("in 2 days", NOW)).toBe(new Date(NOW.getTime() + 2 * 86_400_000).toISOString())
  })

  test("parses today/tomorrow with an optional clock time", () => {
    const tomorrow5pm = normalizeDueAt("tomorrow 5pm", NOW)!
    const d = new Date(tomorrow5pm)
    expect(d.getDate()).toBe(NOW.getDate() + 1)
    expect(d.getHours()).toBe(17)
    // bare "tomorrow" defaults to 9am
    expect(new Date(normalizeDueAt("tomorrow", NOW)!).getHours()).toBe(9)
  })

  test("parses weekday names to the NEXT occurrence", () => {
    // NOW is a Thursday; "friday" → the next day
    const friday = new Date(normalizeDueAt("friday", NOW)!)
    expect(friday.getDay()).toBe(5)
    expect(friday > NOW).toBe(true)
  })

  test("returns null for anything unparseable (never a raw string)", () => {
    expect(normalizeDueAt("whenever you feel like it", NOW)).toBeNull()
    expect(normalizeDueAt("", NOW)).toBeNull()
  })
})

describe("parseAgentSend reminder normalization", () => {
  test("a reminder's dueAt is normalized to ISO or null — never a raw string", () => {
    const r = parseAgentSend({ kind: "reminder", body: "book flight", dueAt: "tomorrow 5pm" })
    expect(r.ok).toBe(true)
    if (r.ok) {
      // Must be valid ISO (Date round-trips) — this is what broke the client.
      expect(r.value.reminderDueAt).not.toBeNull()
      expect(new Date(r.value.reminderDueAt!).toISOString()).toBe(r.value.reminderDueAt)
    }
  })

  test("an unparseable dueAt becomes null, not a raw string", () => {
    const r = parseAgentSend({ kind: "reminder", body: "x", dueAt: "sometime soon" })
    expect(r.ok).toBe(true)
    if (r.ok) expect(r.value.reminderDueAt).toBeNull()
  })
})
