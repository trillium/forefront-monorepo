#!/usr/bin/env bash
# Build Forefront signed with YOUR team and install it on YOUR iPhone over cable.
#
# Usage: Scripts/install-phone.sh
# Needs: .team-id  (gitignored, 10-char Team ID — developer.apple.com/account → Membership)
#        .device-id (gitignored, device UDID — optional; auto-detects if absent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEME="Forefront"
BUNDLE_ID="com.trilliumsmith.forefront"
DERIVED="$REPO_ROOT/DerivedData-device"
TEAM_FILE="$REPO_ROOT/.team-id"
DEVICE_FILE="$REPO_ROOT/.device-id"

# 0. Team ID.
if [[ ! -f "$TEAM_FILE" ]]; then
  echo "✗ no team id: write your 10-char Team ID to .team-id" >&2
  echo "  developer.apple.com/account → Membership Details → Team ID" >&2
  exit 2
fi
TEAM_ID="$(tr -d '[:space:]' < "$TEAM_FILE")"
[[ ${#TEAM_ID} -eq 10 ]] || { echo "✗ .team-id should be exactly 10 characters, got '${TEAM_ID}'" >&2; exit 2; }

# Device UDIDs come in two shapes: modern hardware UDIDs are 8-16 hex
# (e.g. 00008150-000509C03442401C), while devicectl's coredevice identifiers
# are standard 8-4-4-4-12 UUIDs. Accept both.
UDID_RE='^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{16}|([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12})$'

# Print "<udid>\t<name>" for the first connected device in devicectl JSON on
# stdin (empty output => none).
extract_first_connected_device() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '
      .result.devices[]?
      | select(.connectionProperties.tunnelState == "connected")
      | [.hardwareProperties.udid, .deviceProperties.name] | @tsv
    ' 2>/dev/null | head -n1
  else
    python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for d in data.get("result", {}).get("devices", []):
    if d.get("connectionProperties", {}).get("tunnelState") == "connected":
        udid = d.get("hardwareProperties", {}).get("udid", "")
        name = d.get("deviceProperties", {}).get("name", "")
        if udid:
            print(f"{udid}\t{name}")
            break
' 2>/dev/null
  fi
}

# 1. Find the phone. Prefer pinned UDID in .device-id; fall back to auto-detect.
if [[ -f "$DEVICE_FILE" ]]; then
  DEVICE_ID="$(tr -d '[:space:]' < "$DEVICE_FILE")"
  [[ "$DEVICE_ID" =~ $UDID_RE ]] || {
    echo "✗ .device-id is not a valid device UDID: '$DEVICE_ID'" >&2
    echo "  expected a UUID like 00008150-000509C03442401C (xcrun devicectl list devices)" >&2
    exit 2
  }
  DEVICE_NAME="pinned device (.device-id)"
  echo "==> Using $DEVICE_NAME: $DEVICE_ID"
else
  echo "==> Looking for a connected iPhone"
  DEVICES_JSON="$(xcrun devicectl list devices --json-output - 2>/dev/null || true)"
  if [[ -z "$DEVICES_JSON" ]]; then
    echo "✗ could not query devices (xcrun devicectl list devices failed)." >&2
    echo "  Plug the iPhone in with the cable, unlock it, tap Trust, then re-run." >&2
    exit 2
  fi
  DEVICE_INFO="$(printf '%s' "$DEVICES_JSON" | extract_first_connected_device)"
  DEVICE_ID="${DEVICE_INFO%%$'\t'*}"
  DEVICE_NAME="${DEVICE_INFO#*$'\t'}"
  if [[ -z "$DEVICE_ID" ]]; then
    echo "✗ no connected iPhone found. Plug it in, unlock it, tap Trust, then re-run." >&2
    echo "  Debug: xcrun devicectl list devices" >&2
    exit 2
  fi
  [[ "$DEVICE_ID" =~ $UDID_RE ]] || {
    echo "✗ extracted device id is not a valid UDID: '$DEVICE_ID'" >&2
    echo "  Debug: xcrun devicectl list devices --json-output -" >&2
    exit 2
  }
  echo "    found: $DEVICE_NAME ($DEVICE_ID)"
fi

# 2. Regenerate the Xcode project (it's gitignored). ALWAYS regenerate, not just
# when missing: the generated file list goes stale the moment a source file is
# added or removed, and a stale project fails with "cannot find type X in scope"
# for the new file. xcodegen is fast and idempotent, so regenerate every run.
command -v xcodegen >/dev/null || { echo "✗ xcodegen missing: brew install xcodegen" >&2; exit 2; }
( cd "$REPO_ROOT" && xcodegen generate )

# 3. Build for device. Signing overrides passed here only — never in project.yml.
echo "==> Building signed build (team $TEAM_ID) — first run may take a few minutes"
xcodebuild \
  -project "$REPO_ROOT/$SCHEME.xcodeproj" \
  -scheme "$SCHEME" \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_IDENTITY="Apple Development" \
  build

APP_BUNDLE="$DERIVED/Build/Products/Debug-iphoneos/$SCHEME.app"
[[ -d "$APP_BUNDLE" ]] || { echo "✗ build reported success but $APP_BUNDLE not found" >&2; exit 1; }

# 4. Install + launch.
echo "==> Installing on $DEVICE_NAME"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_BUNDLE"
echo "==> Launching $BUNDLE_ID"
LAUNCHED=1
LAUNCH_OUT="$(xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" 2>&1)" || {
  LAUNCHED=0
  if grep -q 'Locked\|could not be, unlocked' <<< "$LAUNCH_OUT"; then
    echo "    (launch refused — the phone is LOCKED. Unlock it and tap the app icon," >&2
    echo "     or re-run this script while unlocked.)" >&2
  else
    echo "    (launch refused — if this is the first install, trust the developer profile:" >&2
    echo "     Settings ▸ General ▸ VPN & Device Management ▸ Trust — then tap the app icon)" >&2
  fi
}
[[ "$LAUNCHED" -eq 1 ]] && printf '%s\n' "$LAUNCH_OUT" | tail -1

if [[ "$LAUNCHED" -eq 1 ]]; then
  echo "✓ done — Forefront is on your phone."
else
  echo "✓ installed but NOT launched — trust the developer profile (above), then tap the app icon." >&2
  echo "  Re-run this script after trusting to launch it automatically." >&2
  exit 3
fi
