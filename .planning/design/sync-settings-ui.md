# Sync + Update-Check Settings UI - Design Document

**Status**: Approved (Konrad, 2026-07-26 — "I guess we need to build that toggle")
**Created**: 2026-07-26
**GH issue**: kmichels/yafda#2

## Problem Statement

`Settings.syncEnabled` and `Settings.updateCheckEnabled` both exist and gate real behavior,
but neither has a control in the settings UI — nothing writes them. Existing machines were
grandfathered into sync (`sync-base.json` present ⇒ enabled), so the gap surfaced only on
the first fresh install (the macOS 27 beta machine, 2026-07-26): sync silently stays off
with nothing to click. Both settings were designed as user decisions; the UI never gave the
user the decision.

## Requirements

### Functional

- **"Sync across your Macs" row** in SettingsPage (same HStack row pattern as the
  existing rows): title + dynamic caption + trailing Toggle bound to
  `Settings.syncEnabled`.
  - Caption reflects actual state, not just the toggle:
    - off → what enabling does (creates/uses `iCloud Drive/YAFDA`, syncs dictionary,
      learned corrections, snippets; first sync completes on next launch).
    - on + iCloud Drive unavailable → say so ("Waiting for iCloud Drive").
    - on + synced → "Last synced <relative time>"; "not yet this launch" before the
      first cycle.
  - Turning the toggle ON triggers an immediate `SyncScheduler.triggerUnconditional`
    cycle so the user sees an effect without relaunching (first-contact deferral still
    applies on a genuinely fresh machine — the caption's "completes on next launch"
    covers that honestly).
- **"Check for updates automatically" row**: Toggle bound to
  `Settings.updateCheckEnabled`; caption notes the daily anonymous GitHub query and that
  the manual menu item works regardless.

### Non-Functional

- No new stores, no migration changes (both keys are already in `migratedKeys`).
- Status must come from real state (`AppPaths.syncedDirectory`, last cycle time), not
  from the toggle position.

## Architecture

- `SyncScheduler.lastCycleAt`: `private` → `private(set)` so the UI can read it.
- `SyncScheduler.statusDescription(enabled:cloudAvailable:lastCycleAt:now:) -> String` —
  pure, drives the sync caption; selftested.
- `MainView.SettingsPage`: two new rows using the existing pattern. Sync row caption calls
  `statusDescription`; relative time via `RelativeDateTimeFormatter`.

## Testing Strategy (selftest, TDD)

- [ ] statusDescription: disabled → invitation text (mentions iCloud Drive)
- [ ] enabled + no cloud → waiting text
- [ ] enabled + cloud + nil lastCycleAt → "not yet synced this launch" text
- [ ] enabled + cloud + recent lastCycleAt → contains relative time ("ago")
- UI rows themselves: not structurally selftested (no existing harness for SettingsPage;
  consistent with every other row on the page).

## Implementation Notes (Living Section)

### 2026-07-26 - Implemented

- Plan review Medium (stale caption) handled with `TimelineView(.periodic(by: 30))`
  around the status text — re-reads scheduler state while the page is open.
- The sync toggle uses `@State`, deliberately breaking the page's own
  @AppStorage rule: `Settings.syncEnabled`'s unset case falls back to
  sync-base existence (grandfather clause), which @AppStorage cannot express.
  Commented at the declaration.
- 4 new selftests for `statusDescription` (207 total).
