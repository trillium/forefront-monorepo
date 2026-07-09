import { onboardingPayload, resolveEndpoint } from "@/lib/backend"

export const dynamic = "force-dynamic"

/** GET /config — endpoint + onboarding payload for the dashboard. */
export function GET() {
  const endpoint = resolveEndpoint()
  return Response.json(
    {
      endpoint,
      payload: onboardingPayload(endpoint),
    },
    { headers: { "Access-Control-Allow-Origin": "*" } },
  )
}
