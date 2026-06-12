#!/usr/bin/env bash
#
# Assemble sshMagic.app from the SwiftPM build product.
#
# macOS gates Bonjour browsing and outbound LAN connections behind the "Local
# Network" privacy permission (System Settings ▸ Privacy & Security ▸ Local
# Network). That prompt only fires for a code-signed *app bundle* carrying
# NSLocalNetworkUsageDescription + NSBonjourServices in its Info.plist — a bare
# `swift run` executable can't request it and discovery silently finds nothing.
# So we build, lay out a .app, write the plist, and ad-hoc sign.
#
# Usage:
#   ./scripts/bundle_app.sh [debug|release]   (default: release)
#   open ./dist/sshMagic.app
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="sshMagic"
BUNDLE_ID="com.blackmirrorstudio.sshmagic"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building ($CONFIG)…"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"

if [ ! -x "$BIN" ]; then
  echo "error: built binary not found at $BIN" >&2
  exit 1
fi

echo "==> Laying out bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# App icon. Regenerate if missing so a fresh checkout still gets one.
ICON="$ROOT/Resources/AppIcon.icns"
if [ ! -f "$ICON" ]; then
  echo "==> Generating app icon…"
  swift "$ROOT/scripts/make_icon.swift"
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>sshMagic</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>sshMagic scans your local network to discover SSH servers you can connect to.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_ssh._tcp</string>
    </array>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing…"
# Ad-hoc (-) signing is enough for the Local Network prompt on a dev machine.
# Replace with a Developer ID identity for distribution.
codesign --force --deep --sign - \
  --entitlements "$ROOT/scripts/sshMagic.entitlements" \
  "$APP"

echo "==> Done: $APP"
echo "    Launch with: open \"$APP\""
