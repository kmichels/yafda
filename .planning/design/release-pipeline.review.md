The implementation plan is well-thought-out and successfully addresses the manual keychain unlock bottleneck. However, sharing a single data directory between dev and release builds poses a high risk of data corruption during schema migrations, and SSH-based GUI launches can be fragile without explicit bootstrap targeting.

### 🔴 High

**Shared data directory between Dev and Release builds risks corruption**
Location: Key decisions / Decision 1
Sharing the same data folder based on app name means Dev (unstable/experimental) and Release (stable) builds will read/write to the same database/files. If a Dev build introduces a database schema migration, the Release build may crash or corrupt the data when run subsequently.
Fix: Isolate data directories by bundle ID (e.g., use com.konradmichels.mutter vs local.mutter). Implement a one-time, one-way migration copy from the dev/legacy folder to the release folder on first launch.

### 🟡 Medium

**SSH-launched GUI applications can fail or lose TCC permissions**
Location: Pipeline design / deploy-mac.sh
Launching a GUI app via open or osascript over a raw SSH session can fail or run the app outside the active user's GUI bootstrap namespace. This often causes silent failures, inability to access the window server, or loss of TCC permissions (Accessibility/Microphone).
Fix: Wrap the remote launch command using launchctl asuser targeting the GUI user's UID (e.g., launchctl asuser <uid> open /Applications/Mutter.app) to ensure it integrates correctly with the active window server session.

### 🟢 Low

**Stapling loose app after only submitting DMG may fail**
Location: Pipeline design / Step 5
If only the DMG is submitted to notarytool, stapler staple on the loose Mutter.app (outside the DMG) may fail to find a matching ticket because the notarization service associated the ticket with the DMG container.
Fix: Notarize the .app (zipped) first, staple it, and then package it into the DMG. Alternatively, perform the deploy on the target Mac by mounting the notarized DMG rather than pushing loose files.
