#!/bin/zsh
# Build Ghost.app and code-sign it. Ad-hoc by default; set GHOST_SIGN_ID to a certificate name to keep macOS
# permissions (Accessibility, notifications) across rebuilds, e.g. GHOST_SIGN_ID="My Dev Cert" ./build.sh
set -euo pipefail
cd "${0:A:h}"
swift build -c release
BIN=.build/release/Ghost
# App icon, rendered by the Ghost shader (only when missing).
if [[ ! -f Resources/AppIcon.icns ]]; then
  T=$(mktemp -d); "$BIN" --icon "$T/icon.png" >/dev/null
  mkdir -p "$T/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$T/icon.png" --out "$T/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$T/icon.png" --out "$T/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$T/AppIcon.iconset" -o Resources/AppIcon.icns
  cp "$T/icon.png" Resources/AppIcon.png
  rm -rf "$T"
fi
APP=Ghost.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ghost"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/GhostParts.usdz "$APP/Contents/Resources/"
codesign --force --sign "${GHOST_SIGN_ID:--}" --identifier local.ghostshell "$APP"
echo "Built $PWD/$APP"
