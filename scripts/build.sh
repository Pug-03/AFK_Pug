#!/bin/bash
# Builds "dist/AFK Pug.app" (ad-hoc signed). Usage: scripts/build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/AFKPug"

APP="dist/AFK Pug.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AFKPug"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon, rendered from the SwiftUI pug
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
"$BIN" --render-icon "$ICONSET/base.png" >/dev/null
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICONSET/base.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$ICONSET/base.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
rm "$ICONSET/base.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  # Quit politely (restores everything); never touch Claude's AFKPug --mcp servers.
  osascript -e 'quit app "AFK Pug"' >/dev/null 2>&1 || true; sleep 1
  pkill -f 'AFK Pug.app/Contents/MacOS/AFKPug$' 2>/dev/null || true
  rm -rf "/Applications/AFK Pug.app"
  cp -R "$APP" /Applications/
  open "/Applications/AFK Pug.app"
  echo "Installed to /Applications"
fi
