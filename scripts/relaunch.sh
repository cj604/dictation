#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$HOME/Applications/Chris Dictation.app"

# Kill any running instance
pkill -f chris-dictation >/dev/null 2>&1 || true
sleep 0.5

# Rebuild and reinstall the .app bundle
"$ROOT_DIR/scripts/install_app.sh"

# Launch via the .app bundle so macOS treats it as a proper GUI app
open "$APP_DIR"
echo "Launched Chris Dictation via .app bundle"
