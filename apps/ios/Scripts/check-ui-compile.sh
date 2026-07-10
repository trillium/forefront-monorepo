#!/usr/bin/env bash
#
# check-ui-compile.sh — type-check the SwiftUI/UIKit/WebKit UI + App layer.
#
# The Models/Storage/Networking/Queue layers are SwiftPM library targets and are
# already covered by `swift build` / `swift test` on macOS. The UI + App layer
# (Forefront/UI/**, Forefront/App/**) imports SwiftUI, WebKit, UIKit and
# AVFoundation, so it can only be compiled against the iOS SDK — which raw
# `swift build` on macOS cannot do. This script type-checks those sources against
# the iOS simulator SDK.
#
# Strategy:
#   1. Compile the four pure-Swift library modules (Models, Queue, Storage,
#      Networking) FOR the iOS simulator, emitting .swiftmodule interfaces into a
#      scratch dir (in dependency order).
#   2. Type-check every UI + App source together with `-I <scratch>` so their
#      `import Forefront{Models,Storage,Networking,Queue}` statements resolve and
#      cross-file references (StackQueueModel, AppEnvironment, ...) type-check.
#
# Exit 0 on success (no type errors), non-zero otherwise.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="arm64-apple-ios17.0-simulator"
SWIFTC="$(xcrun --sdk iphonesimulator --find swiftc)"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

COMMON_FLAGS=(
  -sdk "$SDK_PATH"
  -target "$TARGET"
  -I "$SCRATCH"
)

# Emit a .swiftmodule for one library target (compiled for the simulator).
# Args: <module-name> <source-dir>
emit_module() {
  local module_name="$1"
  local source_dir="$2"
  local sources=()
  while IFS= read -r -d '' f; do
    sources+=("$f")
  done < <(find "$source_dir" -name '*.swift' -print0)

  if [ "${#sources[@]}" -eq 0 ]; then
    echo "check-ui-compile: no sources found in $source_dir" >&2
    return 1
  fi

  "$SWIFTC" \
    "${COMMON_FLAGS[@]}" \
    -module-name "$module_name" \
    -emit-module \
    -emit-module-path "$SCRATCH/${module_name}.swiftmodule" \
    "${sources[@]}"
}

echo "check-ui-compile: building library modules for the iOS simulator SDK…"
# Dependency order: Models first; Storage/Queue depend on Models; Networking
# depends on Models + Storage.
emit_module "ForefrontModels"     "Forefront/Models"
emit_module "ForefrontQueue"      "Forefront/Queue"
emit_module "ForefrontStorage"    "Forefront/Storage"
emit_module "ForefrontNetworking" "Forefront/Networking"

echo "check-ui-compile: type-checking UI + App sources against ${TARGET}…"
UI_SOURCES=()
while IFS= read -r -d '' f; do
  UI_SOURCES+=("$f")
done < <(find Forefront/UI Forefront/App Forefront/Util -name '*.swift' -print0)

if [ "${#UI_SOURCES[@]}" -eq 0 ]; then
  echo "check-ui-compile: no UI/App sources found" >&2
  exit 1
fi

# Type-check only (no codegen). `-parse-as-library` because there is a top-level
# @main type; without it the compiler treats the first file as a script entry.
"$SWIFTC" \
  "${COMMON_FLAGS[@]}" \
  -typecheck \
  -parse-as-library \
  -module-name ForefrontApp \
  "${UI_SOURCES[@]}"

echo "check-ui-compile: OK — UI + App layer type-checks clean."
