#!/bin/bash
# Builds Mutter.app from the SwiftPM release binary.
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="build/Mutter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Mutter "$APP/Contents/MacOS/Mutter"

# App icon (generated once; rerun scripts/make_icon.swift to change it).
if [ -f "Resources/Mutter.icns" ]; then
    cp Resources/Mutter.icns "$APP/Contents/Resources/Mutter.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Changing this orphans every TCC grant (Accessibility, Microphone,
         iCloud Drive) and the whole UserDefaults domain, because both are
         keyed on the bundle id. Settings.migrateLegacyDefaults carries the
         preferences across; the permissions have to be re-granted by hand. -->
    <key>CFBundleIdentifier</key>
    <string>local.mutter</string>
    <key>CFBundleName</key>
    <string>Mutter</string>
    <key>CFBundleExecutable</key>
    <string>Mutter</string>
    <key>CFBundleIconFile</key>
    <string>Mutter</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <!-- No LSUIElement here, deliberately: WhisperFlow was a regular app and
         Cmd-Tab reaching the dashboard is part of the workflow. Setting it
         back to true removes the app from the switcher and the Dock. -->

    <!-- Two copies running at once means two status items, two global event
         monitors, two paste keystrokes per dictation, and two processes racing
         on the same sync-base.json. Easy to hit with an old build in Downloads
         alongside a new one in Applications. -->
    <key>LSMultipleInstancesProhibited</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Mutter records your voice while you hold the dictation key so it can transcribe it on-device.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Local build — no data leaves this Mac.</string>
</dict>
</plist>
PLIST

# Prefer the stable local identity (keeps macOS permission grants valid
# across rebuilds); fall back to ad-hoc.
#
# The identity is still called "WhisperFlow Dev" two renames later. Leave it.
# The name is cosmetic, but the certificate leaf is half of the TCC designated
# requirement, so reissuing it under a nicer name invalidates the signature and
# drops every permission grant. Stale name, load-bearing cert.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "WhisperFlow Dev"; then
    codesign --force --sign "WhisperFlow Dev" "$APP"
    echo "Signed with 'WhisperFlow Dev'."
else
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc (run scripts/make_signing_cert.sh for a stable identity)."
fi

echo "Built $APP"
