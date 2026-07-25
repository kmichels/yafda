# Main menu: Cmd-Q and the standard edit shortcuts - Design Document

**Status**: Approved (Konrad reported the bug 2026-07-25, "let's fix")
**Created**: 2026-07-25
**Ticket**: S3-5

## Problem Statement

Cmd-Q does not quit Mutter; only the menu-bar pill's Quit works. Root cause:
the custom `@main` entry point never sets `NSApp.mainMenu`, and Cmd-Q is not
a system-level kill - it is an ordinary key equivalent dispatched through
the main menu. The accessory era masked this (an accessory app is rarely
frontmost); the Cmd-Tab change made the app focusable and exposed it. Same
root cause silently breaks Cmd-C/V/X/Z/A in the app's own text fields
(Dictionary, scratchpad, History edit) and Cmd-W.

## Requirements

- Cmd-Q quits from anywhere in the app. Quit runs the normal termination
  path (`applicationWillTerminate` -> bounded final sync).
- Standard Edit menu (undo/redo/cut/copy/paste/select all) so text fields
  behave like a Mac app's.
- Window menu with Close (Cmd-W) and Minimize (Cmd-M); closing the window
  keeps the app running, as today.
- Menu-bar pill behavior unchanged.

## Architecture

Files: new `Sources/Mutter/MainMenu.swift` - `build() -> NSMenu` as a pure
builder (App menu: About, Hide/Hide Others/Show All, Quit Cmd-Q; Edit menu:
standard first-responder selectors, nil targets; Window menu: Close,
Minimize) plus `install()` setting `NSApp.mainMenu` and `windowsMenu`.
`Sources/Mutter/AppDelegate.swift` calls `install()` in
`applicationDidFinishLaunching`. `Sources/Mutter/Main.swift` wires
`MainMenu.runSelfTest` into `--selftest`.

## Testing Strategy

Self-test over the pure builder, red first: Quit item exists with key
equivalent "q"+command targeting `terminate(_:)`; Edit menu contains Paste
("v") and Select All ("a") with the standard selectors and nil targets;
Window menu contains Close ("w"). Live Cmd-Q behavior is dogfood-verified.

## Implementation Notes (Living Section)

### 2026-07-25 - Implemented as designed

- `MainMenu.build()` pure builder + `install()`; installed right after the
  instance guard in `applicationDidFinishLaunching`. Suite 186 PASS (three
  new cases). NSMenuItem's default modifier mask is already `.command`, so
  only Hide Others and Redo set masks explicitly.
- `undo:`/`redo:` use string selectors - they are first-responder actions
  with no typed Swift selector to reference.
- Ships in 0.9.2 together with nothing else - a one-cause release so the
  fix is easy to bisect if menu behavior ever regresses.
