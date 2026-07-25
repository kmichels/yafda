#!/bin/bash
# Builds, signs, notarizes and packages the distributable YAFDA release.
#
# Runs headlessly on bot-mini, which holds the Developer ID identity and the
# validated notary keychain profile. Design and rationale:
# .planning/design/release-pipeline.md (and distribution.md for why direct
# distribution rather than the App Store).
#
# Dev builds are scripts/make_app.sh and stay per-machine/self-signed; this
# script owns the release identity (com.konradmichels.yafda + Developer ID),
# which is deliberately a DIFFERENT TCC identity, so a hacked-on dev build
# never rides on the release build's permission grants.
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY="Developer ID Application: Konrad Michels (85QL287QYW)"
NOTARY_PROFILE="palomino-notary"
BUNDLE_ID="com.konradmichels.yafda"
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD_NUMBER=$(git rev-list --count HEAD)
APP="dist/YAFDA.app"
DMG="dist/YAFDA-${VERSION}.dmg"

# --- 0. Preflight: prove headless signing works before a long build -----------
# The classic failure is errSecInternalComponent from a locked keychain or a
# missing partition-list entry. Catch it in two seconds, with the remediation
# printed, instead of after the notarization wait.
PROBE=$(mktemp /tmp/yafda-sign-probe.XXXXXX)
cp /bin/ls "$PROBE"
if ! codesign --force --timestamp --sign "$IDENTITY" "$PROBE" >/dev/null 2>&1; then
    rm -f "$PROBE"
    cat >&2 <<'REMEDY'
Preflight sign failed (locked keychain or missing partition list).
Run interactively on this machine, then retry:
  security unlock-keychain ~/Library/Keychains/login.keychain-db
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db
Never put a keychain password in this script.
REMEDY
    exit 1
fi
rm -f "$PROBE"
echo "Preflight sign OK."

# --- 1. Release build ---------------------------------------------------------
swift build -c release

# --- 2. Assemble the bundle ---------------------------------------------------
rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/YAFDA "$APP/Contents/MacOS/YAFDA"
if [ -f "Resources/YAFDA.icns" ]; then
    cp Resources/YAFDA.icns "$APP/Contents/Resources/YAFDA.icns"
fi

# Same layout as make_app.sh with three deliberate differences: the release
# bundle id, stamped versions, and (shared with make_app.sh since 3c15a34) no
# LSUIElement - Cmd-Tab must reach the dashboard.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- The release identity. Changing this orphans every TCC grant and the
         UserDefaults domain on every machine that installed a release build;
         Settings.migrateLegacyDefaults carries preferences across, the
         permissions have to be re-granted by hand. Pick once, never change. -->
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>YAFDA</string>
    <key>CFBundleExecutable</key>
    <string>YAFDA</string>
    <key>CFBundleIconFile</key>
    <string>YAFDA</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSMultipleInstancesProhibited</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>YAFDA records your voice while you hold the dictation key so it can transcribe it on-device.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Konrad Michels. On-device dictation - no audio leaves this Mac.</string>
</dict>
</plist>
PLIST

# --- 3. Sign (hardened runtime; notarization requires it) ---------------------
# No nested code to sign first: statically linked, no dylibs/frameworks/XPC.
codesign --force --options runtime --timestamp \
    --entitlements scripts/release.entitlements \
    --sign "$IDENTITY" "$APP"

# --- 4. Package the DMG -------------------------------------------------------
STAGE=$(mktemp -d /tmp/yafda-dmg-stage.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/YAFDA.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "YAFDA" -srcfolder "$STAGE" -format UDZO -quiet "$DMG"

# --- 5. Notarize: ONE submission, of the DMG, then staple both artifacts ------
# Tickets are per code-signature hash and a DMG submission covers the nested
# app, so the loose dist/YAFDA.app used for direct pushes can be stapled from
# the same submission. stapler exits nonzero if that ever stops being true.
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"

# --- 6. Gatekeeper gate -------------------------------------------------------
# No pipes here: grep -q closing spctl's pipe under pipefail is exit 141.
SPCTL_OUT=$(spctl -a -vvv -t exec "$APP" 2>&1 || true)
if [[ "$SPCTL_OUT" != *"source=Notarized Developer ID"* ]]; then
    echo "Gatekeeper gate FAILED:" >&2
    echo "$SPCTL_OUT" >&2
    exit 1
fi
echo "Gatekeeper: Notarized Developer ID."

# --- 7. Publish ---------------------------------------------------------------
cp "$DMG" "$HOME/shared/files/"
echo "Release ${VERSION} (${BUILD_NUMBER}): $DMG (+ ~/shared/files), stapled app at $APP"
