#!/usr/bin/env bash
# End-to-end proof of the chat + agent-producer surface.
#
# Proves the full loop against a running backend:
#   agent posts a message  ->  consumer GET returns it
#   user POSTs a reply      ->  GET /agent/inbox returns the reply
#   agent adds a card       ->  GET /stack shows it
#   auth boundary           ->  device token is rejected on /agent/*
#
# Usage:
#   bun run dev              # in another terminal (starts on :9238 under bun --bun)
#   ./scripts/e2e.sh         # or: BASE=http://127.0.0.1:9238 ./scripts/e2e.sh
#
# Requires: curl, jq. Exits non-zero on the first failed assertion.

set -euo pipefail

BASE="${BASE:-http://127.0.0.1:${PORT:-9238}}"
DEVICE="${BACKEND_TOKEN:-test-token}"
AGENT="${FOREFRONT_AGENT_TOKEN:-dev-agent-token}"
CHAT="ch_e2e"

pass() { echo "  ✓ $1"; }
die()  { echo "  ✗ $1" >&2; exit 1; }

echo "E2E against $BASE"

# ── 0. Auth boundary ─────────────────────────────────────────────────────────
echo "[0] auth boundary"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $DEVICE" "$BASE/agent/inbox")
[ "$code" = "401" ] || die "device token reached /agent/inbox (got $code, want 401)"
pass "device token rejected on /agent/* (401)"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $AGENT" "$BASE/agent/inbox")
[ "$code" = "200" ] || die "agent token failed on /agent/inbox (got $code, want 200)"
pass "agent token accepted on /agent/* (200)"

# ── 1. Agent posts a message; consumer GET returns it ────────────────────────
echo "[1] agent authors -> consumer reads"
curl -s -X POST -H "Authorization: Bearer $AGENT" -H 'Content-Type: application/json' \
  -d "{\"id\":\"$CHAT\",\"title\":\"E2E\",\"topic\":\"e2e\"}" "$BASE/agent/chats" >/dev/null
qid=$(curl -s -X POST -H "Authorization: Bearer $AGENT" -H 'Content-Type: application/json' \
  -d '{"kind":"question","body":"Booked the flight?","quickReplies":["Booked it","Not yet"],"push":true}' \
  "$BASE/agent/chats/$CHAT/messages" | jq -r .id)
[ -n "$qid" ] && [ "$qid" != "null" ] || die "agent message returned no id"
pass "agent posted question $qid"

got=$(curl -s -H "Authorization: Bearer $DEVICE" "$BASE/chats/$CHAT/messages" \
  | jq -r '.messages[] | select(.id=="'"$qid"'") | .body')
[ "$got" = "Booked the flight?" ] || die "consumer GET did not return the agent message (got: '$got')"
pass "consumer GET /chats/$CHAT/messages returned the agent message"

# The thread shows in the inbox with unread > 0.
unread=$(curl -s -H "Authorization: Bearer $DEVICE" "$BASE/chats" \
  | jq -r '.chats[] | select(.id=="'"$CHAT"'") | .unreadCount')
[ -n "$unread" ] || die "thread missing from GET /chats"
pass "GET /chats lists the thread (unread=$unread)"

# ── 2. User replies; agent inbox returns the reply ───────────────────────────
echo "[2] user replies -> agent reads back"
cid="e2e-reply-$(date +%s)"
curl -s -X POST -H "Authorization: Bearer $DEVICE" -H 'Content-Type: application/json' \
  -d "{\"clientMessageId\":\"$cid\",\"kind\":\"text\",\"body\":\"Booked it\"}" \
  "$BASE/chats/$CHAT/messages" >/dev/null
pass "user posted reply (clientMessageId=$cid)"

# Idempotency: repeat returns the same message id.
first=$(curl -s -X POST -H "Authorization: Bearer $DEVICE" -H 'Content-Type: application/json' \
  -d "{\"clientMessageId\":\"$cid\",\"kind\":\"text\",\"body\":\"ignored retry\"}" \
  "$BASE/chats/$CHAT/messages" | jq -r .id)
again=$(curl -s -X POST -H "Authorization: Bearer $DEVICE" -H 'Content-Type: application/json' \
  -d "{\"clientMessageId\":\"$cid\",\"kind\":\"text\",\"body\":\"ignored retry 2\"}" \
  "$BASE/chats/$CHAT/messages" | jq -r .id)
[ "$first" = "$again" ] || die "idempotency broke: $first != $again"
pass "idempotent on clientMessageId (both -> $first)"

reply=$(curl -s -H "Authorization: Bearer $AGENT" "$BASE/agent/inbox" \
  | jq -r '.messages[] | select(.clientMessageId=="'"$cid"'") | .body')
[ "$reply" = "Booked it" ] || die "agent inbox did not surface the human reply (got: '$reply')"
pass "GET /agent/inbox returned the human reply — loop closed"

# ── 3. Push record from the push:true question ───────────────────────────────
echo "[3] actionable-push record"
pcat=$(curl -s -H "Authorization: Bearer $AGENT" "$BASE/agent/pushes" \
  | jq -r '.pushes[] | select(.messageId=="'"$qid"'") | .category')
[ "$pcat" = "FF_QUESTION" ] || die "push record missing/incorrect (got: '$pcat')"
pass "GET /agent/pushes has the FF_QUESTION record (APNs send is out of scope)"

# ── 4. Agent adds a card; /stack shows it ────────────────────────────────────
echo "[4] agent curates deck -> /stack reflects it"
v0=$(curl -s -H "Authorization: Bearer $DEVICE" "$BASE/stack/last-updated" | jq -r .version)
curl -s -X POST -H "Authorization: Bearer $AGENT" -H 'Content-Type: application/json' \
  -d '{"id":"e2e-card","url":"https://ex.ts.net/e2e","title":"E2E Card","priority":0}' \
  "$BASE/agent/cards" >/dev/null
onstack=$(curl -s -H "Authorization: Bearer $DEVICE" "$BASE/stack" \
  | jq -r '.cards[] | select(.id=="e2e-card") | .title')
[ "$onstack" = "E2E Card" ] || die "curated card not on /stack (got: '$onstack')"
v1=$(curl -s -H "Authorization: Bearer $DEVICE" "$BASE/stack/last-updated" | jq -r .version)
[ "$v0" != "$v1" ] || die "deck version did not bump ($v0 -> $v1)"
pass "GET /stack shows the agent card; version bumped $v0 -> $v1"

# Cleanup the card so a re-run starts clean-ish (thread/messages persist).
curl -s -X DELETE -H "Authorization: Bearer $AGENT" "$BASE/agent/cards/e2e-card" >/dev/null
pass "cleaned up e2e-card"

echo
echo "ALL E2E ASSERTIONS PASSED ✅"
