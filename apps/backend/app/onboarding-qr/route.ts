import QRCode from "qrcode"
import { onboardingPayload, resolveEndpoint } from "@/lib/backend"

export const dynamic = "force-dynamic"

/**
 * GET /onboarding-qr — the onboarding QR as a live PNG.
 * Generated per-request from the resolved endpoint, so there's no stale
 * static file to regenerate when the tailnet address changes.
 */
export async function GET() {
  const payload = JSON.stringify(onboardingPayload(resolveEndpoint()))
  const png = await QRCode.toBuffer(payload, {
    width: 256,
    errorCorrectionLevel: "H",
    margin: 2,
  })
  return new Response(new Uint8Array(png), {
    headers: { "Content-Type": "image/png", "Cache-Control": "no-store" },
  })
}
