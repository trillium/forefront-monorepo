"use client"

import { useEffect, useState } from "react"

interface ActivityEntry {
  timestamp: string
  type: string
  details: string
}

const LABELS: Record<string, string> = {
  stack_request: "Stack Request",
  stack_request_failed: "Stack Request Failed",
  push_register: "Push Register",
  push_register_failed: "Push Register Failed",
  chat_request: "Chat Request",
  chat_request_failed: "Chat Request Failed",
  chat_created: "Chat Created",
  chat_message: "Chat Message",
  agent_chat: "Agent · Thread",
  agent_message: "Agent · Message",
  agent_card: "Agent · Card",
  agent_inbox: "Agent · Inbox",
  agent_request_failed: "Agent Request Failed",
}

const ACCENT: Record<string, string> = {
  stack_request: "border-l-blue-500 bg-blue-50 dark:bg-blue-950/30",
  stack_request_failed: "border-l-red-500 bg-red-50 dark:bg-red-950/30",
  push_register: "border-l-green-500 bg-green-50 dark:bg-green-950/30",
  push_register_failed: "border-l-red-500 bg-red-50 dark:bg-red-950/30",
  chat_request: "border-l-blue-500 bg-blue-50 dark:bg-blue-950/30",
  chat_request_failed: "border-l-red-500 bg-red-50 dark:bg-red-950/30",
  chat_created: "border-l-blue-500 bg-blue-50 dark:bg-blue-950/30",
  chat_message: "border-l-sky-500 bg-sky-50 dark:bg-sky-950/30",
  agent_chat: "border-l-purple-500 bg-purple-50 dark:bg-purple-950/30",
  agent_message: "border-l-purple-500 bg-purple-50 dark:bg-purple-950/30",
  agent_card: "border-l-amber-500 bg-amber-50 dark:bg-amber-950/30",
  agent_inbox: "border-l-purple-500 bg-purple-50 dark:bg-purple-950/30",
  agent_request_failed: "border-l-red-500 bg-red-50 dark:bg-red-950/30",
}

function fmtTime(iso: string): string {
  return new Date(iso).toLocaleTimeString("en-US", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: true,
  })
}

export default function Dashboard() {
  const [endpoint, setEndpoint] = useState("")
  const [payload, setPayload] = useState("")
  const [activity, setActivity] = useState<ActivityEntry[]>([])
  const [status, setStatus] = useState("Loading…")

  useEffect(() => {
    fetch("/config")
      .then((r) => r.json())
      .then((c) => {
        setEndpoint(c.endpoint)
        setPayload(JSON.stringify(c.payload))
      })
      .catch(() => setStatus("Config error"))
  }, [])

  useEffect(() => {
    const poll = async () => {
      try {
        const entries: ActivityEntry[] = await fetch("/activity").then((r) => r.json())
        setActivity(entries)
        setStatus(`Active (${entries.length} events)`)
      } catch {
        setStatus("Connection error")
      }
    }
    poll()
    const id = setInterval(poll, 2000)
    return () => clearInterval(id)
  }, [])

  const clearLog = async () => {
    await fetch("/activity/clear", { method: "POST" })
    setActivity([])
  }

  return (
    <main className="mx-auto grid max-w-6xl gap-5 p-5 lg:grid-cols-2">
      <section className="rounded-xl bg-white p-8 shadow-sm dark:bg-neutral-900">
        <h1 className="text-2xl font-semibold">Forefront Backend Onboarding</h1>
        <p className="mt-2 text-sm text-neutral-500">
          Scan this QR code in the Forefront app to connect your phone to this server.
        </p>
        <div className="mt-6 flex justify-center">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src="/onboarding-qr"
            alt="Onboarding QR code"
            width={280}
            height={280}
            className="rounded-lg border border-neutral-200 dark:border-neutral-700"
          />
        </div>
        <pre className="mt-4 overflow-x-auto rounded-md bg-neutral-50 p-3 font-mono text-[11px] break-all whitespace-pre-wrap text-neutral-500 dark:bg-neutral-800">
          {payload || "…"}
        </pre>
        <div className="mt-4 text-sm text-neutral-500">
          <div>✓ Server: {endpoint || "…"}</div>
          <div>✓ Token: test-token</div>
          <p className="mt-2">
            Open the Forefront app, tap “Scan QR”, and point your camera at the code.
          </p>
        </div>
      </section>

      <section className="rounded-xl bg-white p-8 shadow-sm dark:bg-neutral-900">
        <div className="flex items-center justify-between border-b border-neutral-200 pb-2 dark:border-neutral-700">
          <h2 className="text-base font-semibold text-neutral-600 dark:text-neutral-300">
            Activity Log
          </h2>
          <button
            onClick={clearLog}
            className="rounded-md bg-neutral-100 px-3 py-1.5 text-xs text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-300"
          >
            Clear Log
          </button>
        </div>
        <div className="mt-2 flex items-center gap-2 text-xs text-neutral-500">
          <span className="h-2 w-2 animate-pulse rounded-full bg-blue-500" />
          {status}
        </div>
        <div className="mt-3 max-h-[500px] overflow-y-auto">
          {activity.length === 0 ? (
            <div className="p-8 text-center text-sm text-neutral-400">
              Waiting for activity…
            </div>
          ) : (
            activity.map((e, i) => (
              <div
                key={i}
                className={`flex items-start justify-between gap-3 border-l-[3px] p-3 text-sm ${
                  ACCENT[e.type] ?? "border-l-neutral-300"
                }`}
              >
                <div className="flex-1">
                  <div className="font-semibold text-neutral-800 dark:text-neutral-100">
                    {LABELS[e.type] ?? e.type}
                  </div>
                  <div className="mt-0.5 text-xs text-neutral-500">{e.details}</div>
                </div>
                <div className="shrink-0 font-mono text-[11px] whitespace-nowrap text-neutral-400">
                  {fmtTime(e.timestamp)}
                </div>
              </div>
            ))
          )}
        </div>
      </section>
    </main>
  )
}
