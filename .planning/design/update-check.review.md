The implementation plan is well-thought-out, lightweight, and aligns with the decision to avoid Sparkle. However, it lacks detail on user feedback during manual update checks and contains minor risks regarding semantic version comparison edge cases.

### 🟡 Medium

**Lack of feedback state for manual update checks**
Location: Architecture / MainMenu
If a user triggers a manual check, the network request could take several seconds. Without a temporary 'Checking...' state or an explicit failure/up-to-date state, the UI will appear unresponsive or broken during slow connections or rate limits.
Fix: Temporarily change the 'Check for Updates...' menu item text to 'Checking...' (and disable it) during the active fetch. If up-to-date, update the text to 'You're Up to Date' for a few seconds before reverting, or show a transient menu item.

### 🟢 Low

**Semantic versioning edge cases with pre-release suffixes**
Location: Sources/YAFDA/UpdateChecker.swift
The proposed dotted-component comparison may fail or behave incorrectly when encountering pre-release tags (e.g., comparing '0.10.3-beta' with '0.10.3'). If non-numeric components fall back to false, a user on a beta release might never be notified of the final release.
Fix: Explicitly handle common pre-release separators (like hyphens) or use a lightweight, tested SemVer parser instead of a custom naive dotted-component splitter.

**Future sandboxing entitlement risk**
Location: Architecture / Non-Functional Requirements
The plan notes that no entitlements are needed because the app is currently unsandboxed. If the app is sandboxed in the future (e.g., for Mac App Store distribution), the update check will silently fail without the outgoing network entitlement.
Fix: Add a brief code comment or architecture note reminding future maintainers to enable the 'com.apple.security.network.client' entitlement if sandboxing is ever adopted.
