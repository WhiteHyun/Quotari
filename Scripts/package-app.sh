#!/bin/zsh
# Builds a distributable Quotari.app into dist/.
#
#   VERSION=0.1.0 Scripts/package-app.sh
#
# Environment:
#   VERSION             bundle version (default 0.1.0)
#   CODESIGN_IDENTITY   "Developer ID Application: ..." (default: ad-hoc "-")
#   ARCHS               space-separated build architectures (default: arm64)
#   SPARKLE_PUBLIC_KEY  Sparkle EdDSA public key; when set, the Info.plist gets
#                       SUFeedURL + SUPublicEDKey and auto-update is active.
#                       When unset, the app runs with updates disabled.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
IDENTITY="${CODESIGN_IDENTITY:--}"
ARCHS="${ARCHS:-arm64}"
BUNDLE_ID="com.whitehyun.quotari"
FEED_URL="https://github.com/WhiteHyun/Quotari/releases/latest/download/appcast.xml"
APP_ICON="$PWD/Scripts/assets/Quotari.icns"

if [[ ! -f "$APP_ICON" ]]; then
  echo "App icon not found: $APP_ICON" >&2
  exit 1
fi

Scripts/check-localizations.sh

echo "▸ building release binary"
ARCH_LIST=(${(z)ARCHS})
BINARY_PATHS=()
RESOURCE_BUNDLE=""
for arch in "${ARCH_LIST[@]}"; do
  echo "  • $arch"
  SCRATCH_PATH="$PWD/.build/release-$arch"
  swift build -c release --arch "$arch" --scratch-path "$SCRATCH_PATH"
  BIN=$(swift build -c release --arch "$arch" --scratch-path "$SCRATCH_PATH" --show-bin-path)
  BINARY_PATHS+=("$BIN/Quotari")
  if [[ -z "$RESOURCE_BUNDLE" ]]; then
    RESOURCE_BUNDLE="$BIN/Quotari_Quotari.bundle"
  fi
done

APP=dist/Quotari.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
if (( ${#BINARY_PATHS[@]} == 1 )); then
  cp "${BINARY_PATHS[1]}" "$APP/Contents/MacOS/Quotari"
else
  lipo -create "${BINARY_PATHS[@]}" -output "$APP/Contents/MacOS/Quotari"
fi
lipo "$APP/Contents/MacOS/Quotari" -verify_arch "${ARCH_LIST[@]}"

echo "▸ embedding SwiftPM resources"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "Quotari_Quotari.bundle not found at $RESOURCE_BUNDLE" >&2
  exit 1
fi
# Keep distributable resources inside Contents so codesign seals them. The app
# prefers this packaged bundle and falls back to Bundle.module for source runs.
ditto "$RESOURCE_BUNDLE" "$APP/Contents/Resources/Quotari_Quotari.bundle"
ditto "$APP_ICON" "$APP/Contents/Resources/Quotari.icns"

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
  <key>CFBundleIconFile</key><string>Quotari.icns</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>ko</string>
  </array>
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
xattr -cr "$APP"
SIGN_OPTIONS=()
if [[ "$IDENTITY" != "-" ]]; then
  SIGN_OPTIONS=(--options runtime --timestamp)
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
"$VERIFY_APP/Contents/MacOS/Quotari" --verify-packaged-settings
"$VERIFY_APP/Contents/MacOS/Quotari" -AppleLanguages '(ko)' --verify-packaged-settings
rm -rf "$VERIFY_ROOT"
trap - EXIT

echo "▸ zipping"
ditto -c -k --keepParent --norsrc "$APP" "dist/Quotari-${VERSION}.zip"
echo "done: dist/Quotari-${VERSION}.zip"
