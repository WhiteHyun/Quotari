#!/bin/zsh
# Builds a distributable Quotari.app into dist/.
#
#   VERSION=0.1.0 Scripts/package-app.sh
#
# Environment:
#   VERSION             bundle version (default 0.1.0)
#   CODESIGN_IDENTITY   "Developer ID Application: ..." (default: ad-hoc "-")
#   SPARKLE_PUBLIC_KEY  Sparkle EdDSA public key; when set, the Info.plist gets
#                       SUFeedURL + SUPublicEDKey and auto-update is active.
#                       When unset, the app runs with updates disabled.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
IDENTITY="${CODESIGN_IDENTITY:--}"
BUNDLE_ID="com.whitehyun.quotari"
FEED_URL="https://github.com/WhiteHyun/Quotari/releases/latest/download/appcast.xml"

echo "▸ building release binary"
swift build -c release
BIN=$(swift build -c release --show-bin-path)

APP=dist/Quotari.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/Quotari" "$APP/Contents/MacOS/Quotari"

echo "▸ embedding Sparkle.framework"
SPARKLE=$(find .build -type d -name "Sparkle.framework" | grep -v dSYM | head -1)
if [[ -z "$SPARKLE" ]]; then
  echo "Sparkle.framework not found under .build" >&2
  exit 1
fi
cp -R "$SPARKLE" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Quotari" 2>/dev/null || true

echo "▸ writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Quotari</string>
  <key>CFBundleDisplayName</key><string>Quotari</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>Quotari</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
PLIST
if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  cat >> "$APP/Contents/Info.plist" <<PLIST
  <key>SUFeedURL</key><string>${FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
PLIST
fi
cat >> "$APP/Contents/Info.plist" <<PLIST
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

echo "▸ codesigning (identity: ${IDENTITY})"
codesign --force --sign "$IDENTITY" --options runtime "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$IDENTITY" --options runtime "$APP"
codesign --verify --deep "$APP"

echo "▸ zipping"
ditto -c -k --keepParent "$APP" "dist/Quotari-${VERSION}.zip"
echo "done: dist/Quotari-${VERSION}.zip"
