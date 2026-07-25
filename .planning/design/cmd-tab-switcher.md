# Cmd-Tab reaches the dashboard - Design Document

**Status**: Approved (Konrad, 2026-07-25, "let's fix that first")
**Created**: 2026-07-25
**Ticket**: S3-4

## Problem Statement

WhisperFlow was a regular app: Cmd-Tab reached it. The Murmur rewrite set
`LSUIElement=true` in the Info.plist template (scripts/make_app.sh, present
since the first commit), which removes the app from the switcher and the
Dock. Reaching the dashboard now requires mousing to the menu-bar mic pill.

## Requirements

- Mutter appears in Cmd-Tab and the Dock while running.
- Cmd-Tab to Mutter always lands on the dashboard: activating with the
  window closed reopens it; a miniaturized window deminiaturizes.
- Menu-bar status item behavior unchanged.

## Rejected alternative

Dynamic activation policy (.accessory when the window is closed, .regular
while open) keeps the Dock clean but drops the app from Cmd-Tab exactly when
the user wants to summon the closed dashboard - the reported complaint.
Trade-off accepted: a permanent Dock icon, same as WhisperFlow.

## Architecture

Files: `scripts/make_app.sh` (remove the LSUIElement key from the Info.plist
template, keep a comment explaining why it must stay absent),
`Sources/Mutter/Main.swift` (the `.app` startup path calls
`setActivationPolicy(.accessory)`, which overrides the plist - it becomes
`.regular`, kept explicit so the bare dev binary gets UI capability too),
`Sources/Mutter/AppDelegate.swift` (`applicationDidBecomeActive`: if the
window is miniaturized, deminiaturize; else if no visible window,
`showMainWindow()`; idempotent when the window is already frontmost),
`Sources/Mutter/LoginItem.swift` (doc-comment only: its rationale text
described the LSUIElement menu-bar behavior this change removes).

The existing `applicationShouldHandleReopen` keeps handling Dock-icon
clicks; the mic-gate window observers (MicMonitor) already handle reopen and
deminiaturize transitions.

## Testing Strategy

Cmd-Tab activation is OS-level and not drivable from --selftest; the
delegate method is a guard plus two existing calls. Covered by the
dogfooding loop (`Sources/Mutter/.tdd-optional`). Full suite must stay
green: `swift build && .build/debug/Mutter --selftest`.

## Implementation Notes (Living Section)

### 2026-07-25 - Implemented as designed

- make_app.sh: LSUIElement removed from the plist template, replaced by a
  comment stating it must stay absent. LSMultipleInstancesProhibited and the
  bundle id are untouched, so TCC grants survive.
- AppDelegate: applicationDidBecomeActive deminiaturizes a miniaturized
  window, else reopens a closed one, else no-ops (already-visible window
  keeps focus; the method also fires right after showMainWindow's own
  NSApp.activate, where the visible-window check makes it idempotent).
- Suite 172 PASS, 0 FAIL after the change. Cmd-Tab behavior itself is only
  observable in the running app; verified by dogfooding on the laptop.

### 2026-07-25 - Round 2: the plist was only half the mechanism

Field-tested on mac-mini-pro: the rebuilt app (plist correctly missing
LSUIElement) still did not appear in Cmd-Tab or the Dock. Root cause of the
incomplete fix: `Main.swift`'s `.app` startup path calls
`setActivationPolicy(.accessory)`, which overrides the plist at runtime; the
first-round investigation checked the plist and AppDelegate but never
searched the code for a policy call. Changed to `.regular`, kept explicit so
the bare `.build` dev binary gets UI capability too. LoginItem's doc comment
still described the LSUIElement behavior and was rewritten.
