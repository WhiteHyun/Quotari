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

echo "▸ embedding SwiftPM resources"
RESOURCE_BUNDLE="$BIN/Quotari_Quotari.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "Quotari_Quotari.bundle not found at $RESOURCE_BUNDLE" >&2
  exit 1
fi
# Keep distributable resources inside Contents so codesign seals them. The app
# prefers this packaged bundle and falls back to Bundle.module for source runs.
ditto "$RESOURCE_BUNDLE" "$APP/Contents/Resources/Quotari_Quotari.bundle"

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
SIGN_OPTIONS=()
if [[ "$IDENTITY" != "-" ]]; then
  SIGN_OPTIONS=(--options runtime)
fi
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE_FRAMEWORK/Versions/B"
# Sparkle's manual-distribution guidance requires bottom-up signing. In
# particular, preserve the Downloader service's entitlement metadata.
codesign --force --sign "$IDENTITY" "${SIGN_OPTIONS[@]}" \
  "$SPARKLE_VERSION/XPCServices/Installer.xpc"
codesign --force --sign "$IDENTITY" "${SIGN_OPTIONS[@]}" --preserve-metadata=entitlements \
  "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
codesign --force --sign "$IDENTITY" "${SIGN_OPTIONS[@]}" "$SPARKLE_VERSION/Autoupdate"
codesign --force --sign "$IDENTITY" "${SIGN_OPTIONS[@]}" "$SPARKLE_VERSION/Updater.app"
codesign --force --sign "$IDENTITY" "${SIGN_OPTIONS[@]}" "$SPARKLE_FRAMEWORK"
codesign --force --sign "$IDENTITY" "${SIGN_OPTIONS[@]}" "$APP"
codesign --verify --deep --strict "$APP"

echo "▸ verifying isolated packaged resources"
VERIFY_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/quotari-package.XXXXXX")
trap 'rm -rf "$VERIFY_ROOT"' EXIT
VERIFY_APP="$VERIFY_ROOT/Quotari.app"
ditto "$APP" "$VERIFY_APP"
codesign --verify --deep --strict "$VERIFY_APP"
"$VERIFY_APP/Contents/MacOS/Quotari" --verify-packaged-resources
rm -rf "$VERIFY_ROOT"
trap - EXIT

echo "▸ zipping"
ditto -c -k --keepParent "$APP" "dist/Quotari-${VERSION}.zip"
echo "done: dist/Quotari-${VERSION}.zip"
