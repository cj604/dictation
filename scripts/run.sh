#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -x "$ROOT_DIR/bin/chris-dictation" ]]; then
  "$ROOT_DIR/scripts/build.sh"
fi

"$ROOT_DIR/bin/chris-dictation"
