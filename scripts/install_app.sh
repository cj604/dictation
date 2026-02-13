#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$HOME/Applications/Chris Dictation.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Build first
"$ROOT_DIR/scripts/build.sh"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Chris Dictation</string>
  <key>CFBundleDisplayName</key>
  <string>Chris Dictation</string>
  <key>CFBundleIdentifier</key>
  <string>com.cj.chris-dictation</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleExecutable</key>
  <string>chris-dictation</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Chris Dictation needs microphone access to record audio for transcription.</string>
</dict>
</plist>
PLIST

# Copy the actual binary into the bundle (not a launcher script)
cp "$ROOT_DIR/bin/chris-dictation" "$MACOS_DIR/chris-dictation"

# Sign the entire .app bundle with stable identity
codesign -f -s - --identifier com.cj.chris-dictation "$APP_DIR"

echo "Installed app: $APP_DIR"
echo "Open it with: open \"$APP_DIR\""
