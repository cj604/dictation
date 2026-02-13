#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT_DIR/bin"

swiftc \
  "$ROOT_DIR"/Sources/chris-dictation/*.swift \
  -o "$ROOT_DIR/bin/chris-dictation" \
  -framework AppKit \
  -framework AVFoundation \
  -framework ApplicationServices

# Sign with stable identity so macOS Accessibility permission survives rebuilds
codesign -f -s - --identifier com.cj.chris-dictation "$ROOT_DIR/bin/chris-dictation"

echo "Built: $ROOT_DIR/bin/chris-dictation"
