/**
 * Coverage for lib/apns.ts — the APNs delivery leg.
 *
 * We cannot hit real APNs without a device + a real Auth Key, so we prove the
 * two things a real send depends on: (1) the provider JWT is a correct,
 * cryptographically-valid ES256 token — generated with a throwaway EC P-256 key
 * and VERIFIED against the derived public key; (2) the payloads match contract
 * §4/§11 and the drain wires records → devices → sent-marks correctly, including
 * the graceful no-op paths when unconfigured or device-less.
 *
 * Run: bun test
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test"
import {
  createVerify,
  generateKeyPairSync,
  type KeyObject,
} from "node:crypto"
import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import {
  base64url,
  buildActionablePayload,
  buildProviderJWT,
  buildSilentPayload,
  _resetTokenCacheForTest,
  getProviderToken,
  isConfigured,
  readConfig,
  redactToken,
  runDrain,
  sendPush,
  type ApnsConfig,
  type DrainablePush,
  type SendResult,
} from "./apns"
import type { PushDeliveryResult } from "./store"

// ── Test key material (EC P-256, exported as PKCS#8 PEM = Apple .p8 shape) ─────

function makeKeypair(): { pem: string; publicKey: KeyObject } {
  const { privateKey, publicKey } = generateKeyPairSync("ec", {
    namedCurve: "P-256",
  })
  const pem = privateKey.export({ type: "pkcs8", format: "pem" }) as string
  return { pem, publicKey }
}

/** Decode a base64url JWT segment back to a UTF-8 string. */
function decodeSegment(seg: string): string {
  return Buffer.from(seg, "base64url").toString("utf8")
}

// Snapshot + restore env so cases that set APNS_* never leak into each other.
const APNS_ENV_KEYS = [
  "APNS_KEY_PATH",
  "APNS_KEY_ID",
  "APNS_TEAM_ID",
  "APNS_BUNDLE_ID",
  "APNS_ENV",
] as const
let savedEnv: Record<string, string | undefined> = {}

beforeEach(() => {
  savedEnv = {}
  for (const k of APNS_ENV_KEYS) {
    savedEnv[k] = process.env[k]
    delete process.env[k]
  }
  _resetTokenCacheForTest()
})

afterEach(() => {
  for (const k of APNS_ENV_KEYS) {
    if (savedEnv[k] === undefined) delete process.env[k]
    else process.env[k] = savedEnv[k]
  }
  _resetTokenCacheForTest()
})

// ── base64url ─────────────────────────────────────────────────────────────────

describe("base64url", () => {
  test("is URL-safe and unpadded", () => {
    // 0xFB 0xFF encodes to "+/8=" in standard base64; url-safe drops padding
    // and swaps + / → - _.
    const encoded = base64url(Buffer.from([0xfb, 0xff]))
    expect(encoded).not.toContain("+")
    expect(encoded).not.toContain("/")
    expect(encoded).not.toContain("=")
    expect(encoded).toBe("-_8")
  })

  test("round-trips a UTF-8 string via base64url decode", () => {
    const s = '{"alg":"ES256"}'
    expect(decodeSegment(base64url(s))).toBe(s)
  })
})

// ── JWT signing + verification (the load-bearing crypto proof) ────────────────

describe("buildProviderJWT", () => {
  test("produces a verifiable ES256 token with correct header + claims", () => {
    const { pem, publicKey } = makeKeypair()
    const iat = 1_700_000_000
    const jwt = buildProviderJWT({
      pem,
      keyId: "ABC123KEYID",
      teamId: "TEAM123456",
      iat,
    })

    const [headerSeg, claimsSeg, sigSeg] = jwt.split(".")
    expect(headerSeg).toBeDefined()
    expect(claimsSeg).toBeDefined()
    expect(sigSeg).toBeDefined()

    // Header: alg ES256, kid matches.
    const header = JSON.parse(decodeSegment(headerSeg!)) as {
      alg: string
      kid: string
    }
    expect(header.alg).toBe("ES256")
    expect(header.kid).toBe("ABC123KEYID")

    // Claims: iss = teamId, iat = injected value.
    const claims = JSON.parse(decodeSegment(claimsSeg!)) as {
      iss: string
      iat: number
    }
    expect(claims.iss).toBe("TEAM123456")
    expect(claims.iat).toBe(iat)

    // Signature: raw R||S (64 bytes) and VERIFIES against the derived pubkey.
    const rawSig = Buffer.from(sigSeg!, "base64url")
    expect(rawSig.length).toBe(64)

    const verify = createVerify("SHA256")
    verify.update(`${headerSeg}.${claimsSeg}`)
    const ok = verify.verify(
      { key: publicKey, dsaEncoding: "ieee-p1363" },
      rawSig,
    )
    expect(ok).toBe(true)
  })

  test("a tampered signing-input fails verification", () => {
    const { pem, publicKey } = makeKeypair()
    const jwt = buildProviderJWT({ pem, keyId: "K", teamId: "T", iat: 1 })
    const [headerSeg, claimsSeg, sigSeg] = jwt.split(".")
    const rawSig = Buffer.from(sigSeg!, "base64url")

    const verify = createVerify("SHA256")
    // Verify against a DIFFERENT signing input — must fail.
    verify.update(`${headerSeg}.${claimsSeg}TAMPER`)
    const ok = verify.verify(
      { key: publicKey, dsaEncoding: "ieee-p1363" },
      rawSig,
    )
    expect(ok).toBe(false)
  })

  test("defaults iat to now when omitted", () => {
    const { pem } = makeKeypair()
    const before = Math.floor(Date.now() / 1000)
    const jwt = buildProviderJWT({ pem, keyId: "K", teamId: "T" })
    const after = Math.floor(Date.now() / 1000)
    const claims = JSON.parse(decodeSegment(jwt.split(".")[1]!)) as {
      iat: number
    }
    expect(claims.iat).toBeGreaterThanOrEqual(before)
    expect(claims.iat).toBeLessThanOrEqual(after)
  })
})

// ── Config + isConfigured ─────────────────────────────────────────────────────

describe("config", () => {
  test("readConfig is null when the required env is unset", () => {
    expect(readConfig()).toBeNull()
    expect(isConfigured()).toBe(false)
  })

  test("readConfig null when only some of the required env is set", () => {
    process.env.APNS_KEY_PATH = "/tmp/x.p8"
    process.env.APNS_KEY_ID = "K"
    // teamId missing
    expect(readConfig()).toBeNull()
  })

  test("readConfig fills defaults for bundle id and environment", () => {
    process.env.APNS_KEY_PATH = "/tmp/x.p8"
    process.env.APNS_KEY_ID = "KID"
    process.env.APNS_TEAM_ID = "TID"
    const cfg = readConfig()
    expect(cfg).not.toBeNull()
    expect(cfg!.bundleId).toBe("com.trilliumsmith.forefront")
    expect(cfg!.environment).toBe("sandbox")
  })

  test("APNS_ENV=production selects the production environment", () => {
    process.env.APNS_KEY_PATH = "/tmp/x.p8"
    process.env.APNS_KEY_ID = "KID"
    process.env.APNS_TEAM_ID = "TID"
    process.env.APNS_ENV = "production"
    expect(readConfig()!.environment).toBe("production")
  })

  test("isConfigured is false when env is set but the key file is missing", () => {
    process.env.APNS_KEY_PATH = "/definitely/not/here.p8"
    process.env.APNS_KEY_ID = "KID"
    process.env.APNS_TEAM_ID = "TID"
    expect(readConfig()).not.toBeNull()
    expect(isConfigured()).toBe(false)
  })

  test("isConfigured is true when env is set and the key file exists", () => {
    const dir = mkdtempSync(join(tmpdir(), "apns-cfg-"))
    try {
      const keyPath = join(dir, "AuthKey.p8")
      const { pem } = makeKeypair()
      writeFileSync(keyPath, pem)
      process.env.APNS_KEY_PATH = keyPath
      process.env.APNS_KEY_ID = "KID"
      process.env.APNS_TEAM_ID = "TID"
      expect(isConfigured()).toBe(true)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

// ── Token cache ───────────────────────────────────────────────────────────────

describe("getProviderToken cache", () => {
  function cfgFor(keyPath: string): ApnsConfig {
    return {
      keyPath,
      keyId: "KID",
      teamId: "TID",
      bundleId: "com.trilliumsmith.forefront",
      environment: "sandbox",
    }
  }

  test("reuses a cached token within the TTL and refreshes past it", () => {
    const dir = mkdtempSync(join(tmpdir(), "apns-cache-"))
    try {
      const keyPath = join(dir, "AuthKey.p8")
      writeFileSync(keyPath, makeKeypair().pem)
      const cfg = cfgFor(keyPath)

      const t0 = 1_700_000_000_000
      const a = getProviderToken(cfg, t0)
      const b = getProviderToken(cfg, t0 + 10 * 60 * 1000) // +10m, within TTL
      expect(b).toBe(a)

      const c = getProviderToken(cfg, t0 + 51 * 60 * 1000) // +51m, past TTL
      expect(c).not.toBe(a)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  test("a different key config busts the cache", () => {
    const dir = mkdtempSync(join(tmpdir(), "apns-cache2-"))
    try {
      const keyPathA = join(dir, "A.p8")
      const keyPathB = join(dir, "B.p8")
      writeFileSync(keyPathA, makeKeypair().pem)
      writeFileSync(keyPathB, makeKeypair().pem)
      const t0 = 1_700_000_000_000
      const a = getProviderToken(cfgFor(keyPathA), t0)
      const b = getProviderToken(cfgFor(keyPathB), t0)
      expect(b).not.toBe(a)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

// ── Payload shaping (§4 + §11) ────────────────────────────────────────────────

describe("buildActionablePayload", () => {
  test("shapes a reminder into the §11 payload", () => {
    const payload = buildActionablePayload({
      chatId: "ch_reminders",
      messageId: "m_1001",
      category: "FF_REMINDER",
      title: "Reminder",
      body: "Have you booked the flight yet?",
      quickReplies: null,
    })
    const aps = payload.aps as Record<string, unknown>
    expect(aps.alert).toEqual({
      title: "Reminder",
      body: "Have you booked the flight yet?",
    })
    expect(aps.category).toBe("FF_REMINDER")
    expect(aps["mutable-content"]).toBe(1)
    expect(aps.sound).toBe("default")
    expect(payload.chatId).toBe("ch_reminders")
    expect(payload.messageId).toBe("m_1001")
    // No quickReplies key when none provided.
    expect("quickReplies" in payload).toBe(false)
  })

  test("includes quickReplies for a question", () => {
    const payload = buildActionablePayload({
      chatId: "ch_q",
      messageId: "m_2002",
      category: "FF_QUESTION",
      title: "Question",
      body: "Coffee?",
      quickReplies: ["Yes", "No"],
    })
    expect((payload.aps as Record<string, unknown>).category).toBe("FF_QUESTION")
    expect(payload.quickReplies).toEqual(["Yes", "No"])
  })
})

describe("buildSilentPayload", () => {
  test("is content-available only, no alert", () => {
    const payload = buildSilentPayload(42)
    expect(payload.aps).toEqual({ "content-available": 1 })
    expect(payload.version).toBe(42)
    expect("alert" in (payload.aps as Record<string, unknown>)).toBe(false)
  })

  test("omits version when not supplied", () => {
    const payload = buildSilentPayload()
    expect("version" in payload).toBe(false)
  })
})

// ── sendPush: unconfigured no-op ──────────────────────────────────────────────

describe("sendPush (unconfigured)", () => {
  test("is a no-op returning 'not configured' when no key is set", async () => {
    const res = await sendPush("aabbccdd", { aps: {} })
    expect(res.status).toBeNull()
    expect(res.error).toBe("not configured")
  })
})

// ── Drain (dependency-injected, no live DB/APNs) ──────────────────────────────

describe("runDrain", () => {
  const push: DrainablePush = {
    id: "p_1",
    chatId: "ch_reminders",
    messageId: "m_1001",
    category: "FF_REMINDER",
    title: "Reminder",
    body: "Book the flight",
    quickReplies: null,
  }

  function accepting(): {
    send: (t: string, p: Record<string, unknown>) => Promise<SendResult>
    calls: Array<{ token: string; payload: Record<string, unknown> }>
  } {
    const calls: Array<{
      token: string
      payload: Record<string, unknown>
    }> = []
    return {
      calls,
      send: async (token, payload) => {
        calls.push({ token, payload })
        return {
          status: 200,
          apnsId: "apns-id-xyz",
          reason: null,
          error: null,
        }
      },
    }
  }

  test("sends each push to every device and marks it sent", async () => {
    const marks: Array<{ pushId: string; results: PushDeliveryResult[] }> = []
    const { send, calls } = accepting()
    const summary = await runDrain([push], {
      listDevices: () => [
        { deviceToken: "tokenAAAA0000", environment: "sandbox" },
        { deviceToken: "tokenBBBB1111", environment: "sandbox" },
      ],
      markSent: (pushId, results) => marks.push({ pushId, results }),
      send,
      configured: true,
    })

    expect(summary.processed).toBe(1)
    expect(summary.attempts).toBe(2)
    expect(summary.accepted).toBe(2)
    expect(summary.failed).toBe(0)
    expect(calls.length).toBe(2)
    // Payload shaped once and reused per device.
    expect((calls[0]!.payload.aps as Record<string, unknown>).category).toBe(
      "FF_REMINDER",
    )
    // Marked sent with two redacted per-device results.
    expect(marks.length).toBe(1)
    expect(marks[0]!.pushId).toBe("p_1")
    expect(marks[0]!.results.length).toBe(2)
    expect(marks[0]!.results[0]!.status).toBe(200)
    // Token is redacted in the recorded result, never stored raw.
    expect(marks[0]!.results[0]!.deviceToken).not.toBe("tokenAAAA0000")
  })

  test("records failures (non-200) without throwing", async () => {
    const marks: Array<{ pushId: string; results: PushDeliveryResult[] }> = []
    const summary = await runDrain([push], {
      listDevices: () => [
        { deviceToken: "badtoken0000", environment: "sandbox" },
      ],
      markSent: (pushId, results) => marks.push({ pushId, results }),
      send: async () => ({
        status: 400,
        apnsId: null,
        reason: "BadDeviceToken",
        error: null,
      }),
      configured: true,
    })
    expect(summary.accepted).toBe(0)
    expect(summary.failed).toBe(1)
    expect(marks[0]!.results[0]!.reason).toBe("BadDeviceToken")
    // Still marked sent (delivery attempted) so it isn't retried forever.
    expect(marks.length).toBe(1)
  })

  test("no-op when unconfigured: nothing sent, nothing marked", async () => {
    let sends = 0
    let marked = 0
    const summary = await runDrain([push], {
      listDevices: () => [
        { deviceToken: "tokenAAAA0000", environment: "sandbox" },
      ],
      markSent: () => marked++,
      send: async () => {
        sends++
        return { status: 200, apnsId: null, reason: null, error: null }
      },
      configured: false,
    })
    expect(sends).toBe(0)
    expect(marked).toBe(0)
    expect(summary.processed).toBe(0)
    expect(summary.configured).toBe(false)
  })

  test("no-op when there are no registered devices", async () => {
    let sends = 0
    let marked = 0
    const summary = await runDrain([push], {
      listDevices: () => [],
      markSent: () => marked++,
      send: async () => {
        sends++
        return { status: 200, apnsId: null, reason: null, error: null }
      },
      configured: true,
    })
    expect(sends).toBe(0)
    expect(marked).toBe(0)
    expect(summary.deviceCount).toBe(0)
    expect(summary.processed).toBe(0)
  })
})

// ── redactToken ───────────────────────────────────────────────────────────────

describe("redactToken", () => {
  test("keeps first 6 + last 4 for a long token", () => {
    const r = redactToken("0123456789abcdef0123456789abcdef")
    expect(r).toBe("012345…cdef")
    expect(r).not.toContain("6789abcdef012")
  })

  test("collapses a short token", () => {
    expect(redactToken("abcd")).toBe("ab…")
  })
})
