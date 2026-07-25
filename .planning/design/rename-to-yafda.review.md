The implementation plan is exceptionally thorough, demonstrating a strong grasp of macOS-specific pitfalls like TCC caching, LaunchServices, and iCloud propagation. However, it introduces minor risks regarding background launch agents, headless test automation on the bot-mini, and the timing of the defaults migration version bump.

### 🟡 Medium

**Headless TCC Hangs on bot-mini**
Location: Phase 2 / bot-mini setup
Changing the bundle ID to 'local.yafda' will reset TCC permissions. If bot-mini runs automated integration tests that invoke microphone or accessibility APIs, the tests will hang or fail silently waiting for a GUI prompt that cannot be approved on a headless machine.
Fix: Ensure the test suite mocks or bypasses TCC-dependent APIs when running with the '--selftest' flag, or document the exact VNC/remote commands needed to pre-authorize the bot-mini.

**Background Launch Agents and Login Items Race**
Location: Phase 3 — Step 1
If YAFDA/Mutter is configured as a login item or has a background helper agent, it may automatically relaunch during Phase 3 (iCloud folder rename), triggering a background sync and corrupting the directory structure mid-rename.
Fix: Explicitly disable 'Launch at Login' in the app settings and unload any associated launchd agents on both Macs before starting Phase 3.

### 🟢 Low

**Migration Version and Bundle ID Desynchronization**
Location: Phase 1 vs Phase 2 transition
If the migration version is bumped to 3 in Phase 1 while the bundle ID remains 'local.mutter', an interim build launch will execute the migration logic prematurely within the old bundle's container, potentially corrupting or duplicating preferences.
Fix: Keep the migration version bump (currentMigrationVersion = 3) strictly coupled to the Phase 2 commit where the bundle ID actually changes.

**Stale Local Automation and Cron Paths**
Location: Phase 4 — Step 6
Local scripts, cron jobs, or launchd plists on mac-mini-pro or bot-mini might reference hardcoded paths like '/Applications/Mutter.app' or '~/scripts/projects/mutter', causing automation to break post-rename.
Fix: Add an explicit step in Phase 4 to grep the entire home directory of all three machines for the string 'Mutter' to catch external automation scripts.
