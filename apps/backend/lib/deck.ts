/**
 * The deck the backend serves — and the single seam where its *source* can swap.
 *
 * Today the deck is a static in-memory array. Tomorrow it becomes an
 * assistant-curated `brain`/`feed` query (necessarily async). Callers go through
 * `getDeck()` and `getVersion()` — never the raw array — so that swap is a
 * one-function-body change, not a caller-rippling edit. This mirrors the iOS
 * client's discipline (everything goes through `api.fetchStack()`).
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

const HOUR_MS = 60 * 60 * 1000

function agoISO(hours: number): string {
  return new Date(Date.now() - hours * HOUR_MS).toISOString()
}

/**
 * The current deck — index 0 is front-of-deck, lowest priority = highest.
 * The static fixture source; replace this body with a `brain`/`feed` query when
 * the deck becomes curated. Not exported: callers use `getDeck()`.
 */
const currentDeck: Card[] = [
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
 * The ordered deck to serve. Async by design so the future curated source (a
 * `brain`/`feed` query) drops in without changing a single caller.
 */
export async function getDeck(): Promise<Card[]> {
  return currentDeck
}

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
