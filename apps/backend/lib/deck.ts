/**
 * The deck the backend serves — and the single seam where its *source* can swap.
 *
 * Today the deck is a static in-memory array. Tomorrow it becomes an
 * assistant-curated `brain`/`feed` query (necessarily async). Callers go through
 * `getDeck()` and `getVersion()` — never the raw array — so that swap is a
 * one-function-body change, not a caller-rippling edit. This mirrors the iOS
 * client's discipline (everything goes through `api.fetchStack()`).
 */

import { bumpDeckVersion, getDeckVersion, listCards } from "@/lib/store"

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
 * The ordered deck to serve. Now backed by the agent-curated store: cards the
 * DA enqueued via `POST /agent/cards` take over. When the store is empty (fresh
 * device test, no agent curation yet) it falls back to the static fixtures
 * above, preserving the original onboarding flow (Docs/DECISIONS.md B-05).
 *
 * Async by design (unchanged signature) so this swap ripples to zero callers.
 */
export async function getDeck(): Promise<Card[]> {
  const curated = listCards()
  if (curated.length > 0) {
    // Store rows carry `ttl: number | null`; the contract's Card omits ttl when
    // absent, so map null → undefined.
    return curated.map((c) => ({
      id: c.id,
      url: c.url,
      title: c.title,
      priority: c.priority,
      createdAt: c.createdAt,
      updatedAt: c.updatedAt,
      type: c.type,
      ...(c.ttl !== null ? { ttl: c.ttl } : {}),
    }))
  }
  return currentDeck
}

/**
 * Deck version. The client only does equality comparison (int | ISO | etag).
 * Sourced from the store so it reflects agent card mutations (each upsert/delete
 * bumps it) and survives restarts. `bumpVersion()` remains for manual testing.
 */
export function getVersion(): string {
  return getDeckVersion()
}

export function bumpVersion(): string {
  return bumpDeckVersion()
}
