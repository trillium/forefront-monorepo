import { readActivity } from "@/lib/activity"

export const dynamic = "force-dynamic"

/** GET /activity — newest-first dashboard feed (no bearer; local dashboard only). */
export function GET() {
  return Response.json(readActivity(), {
    headers: { "Access-Control-Allow-Origin": "*" },
  })
}
