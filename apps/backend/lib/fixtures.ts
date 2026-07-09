/**
 * Fixture deck + mutable server state for the Forefront backend.
 *
 * v1 is in-memory and hardcoded per the ISA spec (no DB, no persistence).
 * When the deck becomes assistant-curated, this module is the single seam to
 * swap the constant array for a `brain`/`feed` query — everything else in the
 * router stays put.
 */

/** A single deck card. Shape mirrors Docs/BACKEND_CONTRACT.md §3. */
export interface Card {
  id: string
  url: string
  title: string
  priority: number
  createdAt: string
  updatedAt: string
  type: string
  ttl?: number
}

/** One entry in the dashboard activity feed. */
export interface ActivityEntry {
  timestamp: string
  type: string
  details: string
}

const HOUR_MS = 60 * 60 * 1000

function agoISO(hours: number): string {
  return new Date(Date.now() - hours * HOUR_MS).toISOString()
}

/**
 * Static fixture deck — index 0 is front-of-deck, lowest priority = highest.
 * Ported 1:1 from the retired Go server's `fixtureCards`.
 */
export const fixtureCards: Card[] = [
  {
    id: "demo-1",
    url: "https://example.com",
    title: "Example — Forefront",
    priority: 0,
    createdAt: agoISO(24),
    updatedAt: agoISO(24),
    type: "web",
    ttl: 3600,
  },
  {
    id: "demo-2",
    url: "https://apple.com/developer",
    title: "Apple Developer",
    priority: 1,
    createdAt: agoISO(12),
    updatedAt: agoISO(12),
    type: "web",
    ttl: 3600,
  },
  {
    id: "demo-3",
    url: "https://developer.apple.com/swift",
    title: "Swift Documentation",
    priority: 2,
    createdAt: agoISO(6),
    updatedAt: agoISO(6),
    type: "web",
    ttl: 3600,
  },
]

/**
 * Deck version. The client only does equality comparison (int | ISO | etag),
 * so a monotonic string is fine. Bump via `bumpVersion()` to trigger a client
 * refetch during testing.
 */
let version = "1"

export function getVersion(): string {
  return version
}

export function bumpVersion(): string {
  version = String(Number(version) + 1)
  return version
}

// --- Activity log (dashboard only; never logs tokens or request bodies) ---

const MAX_ACTIVITY = 50
const activityLog: ActivityEntry[] = []

export function logActivity(type: string, details: string): void {
  activityLog.push({ timestamp: new Date().toISOString(), type, details })
  if (activityLog.length > MAX_ACTIVITY) activityLog.shift()
}

/** Newest-first snapshot for the dashboard. */
export function readActivity(): ActivityEntry[] {
  return [...activityLog].reverse()
}

export function clearActivity(): void {
  activityLog.length = 0
}
