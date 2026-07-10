/**
 * Dashboard activity feed — an in-memory record of requests the app made.
 * Separate from the deck source (lib/deck.ts): this is diagnostics, not domain.
 * Never logs tokens or request bodies.
 */

/** One entry in the dashboard activity feed. */
export interface ActivityEntry {
  timestamp: string
  type: string
  details: string
}

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
