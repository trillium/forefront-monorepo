import { clearActivity } from "@/lib/activity"

export const dynamic = "force-dynamic"

/** POST /activity/clear — reset the dashboard feed. */
export function POST() {
  clearActivity()
  return Response.json(
    { status: "cleared" },
    { headers: { "Access-Control-Allow-Origin": "*" } },
  )
}
