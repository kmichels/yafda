# Update Check - Design Document

**Status**: Approved (Konrad, 2026-07-26 — "Yes, build it" against the proposed shape)
**Created**: 2026-07-26
**Last Updated**: 2026-07-26

## Problem Statement

YAFDA ships via GitHub Releases, but nothing tells an installed copy that a newer release
exists. Today updates reach Konrad's Macs because a CC session runs `deploy-mac.sh`; anyone
else who installs the DMG never learns about 0.10.3. `distribution.md` §7 already settled the
approach: **no Sparkle** (its helper apps and XPC services are a disproportionate
signing/notarization burden for a named group of users); instead an in-app check that
compares against GitHub and opens the releases page. That recommendation is what this
implements — detection and a pointer, not self-replacement.

## Requirements

### Functional Requirements

- On launch, at most once per 24h, fetch the latest release tag from
  `https://api.github.com/repos/kmichels/yafda/releases/latest` (anonymous, no token).
- Compare the tag against the running `CFBundleShortVersionString`; when newer, surface a
  quiet indicator: a "Update available — X.Y.Z" item in the app menu that opens the
  release's `html_url` in the browser. No dialogs, no interruptions.
- A manual "Check for Updates…" menu item that ignores the throttle, performs the check
  immediately, and reports either the available version or "You're up to date" (menu-item
  state; still no modal).
- A Settings toggle `updateCheckEnabled` (default **on**) that disables the automatic
  check entirely. The manual menu item always works — an explicit click is consent.
- Never auto-download, never auto-install, never relaunch. Opening the page is the whole
  action.

### Non-Functional Requirements

- **Privacy**: this adds YAFDA's first non-Apple network request. README's privacy claim
  must be updated in the same change (GitHub API, anonymous, version string only, daily,
  off-switch). The request sends no identifying payload; it is a plain GET.
- **Resilience**: network failure, rate-limiting (403), malformed JSON, or an unparsable
  tag must all degrade to "no update known" silently (log, never surface). A hung request
  must never block launch — the check runs detached off the launch path with a 10s
  timeout.
- **No new entitlements**: the app is unsandboxed; outgoing HTTPS needs nothing. The
  release pipeline is untouched.
- **Testability**: all decision logic (version compare, throttle, JSON parse, state
  transitions) must be pure and covered by selftests; the network call is injected.

## Architecture

### Components

- `Sources/YAFDA/UpdateChecker.swift` (new, self-contained):
  - `struct ReleaseInfo { let version: String; let url: URL }`
  - `parse(latestReleaseJSON:) -> ReleaseInfo?` — extracts `tag_name` (strips a leading
    `v`) and `html_url`. Pure.
  - `isNewer(_ remote: String, than local: String) -> Bool` — numeric dotted-component
    compare, missing components are 0, non-numeric components compare as unequal-safe
    (fall back to false — never nag on garbage). Pure.
  - `shouldAutoCheck(now:lastCheckAt:enabled:) -> Bool` — the 24h throttle. Pure.
  - `check(fetch:) async -> ReleaseInfo?` — orchestration with injected
    `fetch: (URL) async throws -> Data`; applies parse + isNewer against
    `Bundle.main`'s version. Production fetch = `URLSession` with 10s timeout and an
    explicit `User-Agent: YAFDA-update-check` header (GitHub's API rejects UA-less
    requests; URLSession's default UA happens to satisfy it, but don't depend on that).
- `Settings`: `updateCheckEnabled` (Bool, default true, in `migratedKeys`),
  `lastUpdateCheckAt` (Date; ephemeral, NOT migrated).
- `AppDelegate`: `@Published var availableUpdate: ReleaseInfo?`; kicks the throttled check
  from `applicationDidFinishLaunching` in a detached task.
- `MainMenu`: "Check for Updates…" item (always enabled) and a conditional
  "Update available — X.Y.Z" item bound to `availableUpdate`, action = `NSWorkspace.open`.

### Data Flow

launch → shouldAutoCheck(defaults) → GET releases/latest → parse → isNewer vs bundle
version → set `availableUpdate` (main actor) → menu shows the item → click → open URL.
Failures at any step → nil, log at `.info`, done.

## Testing Strategy (selftest suite, TDD)

- [ ] parse: valid JSON → version + URL; `v` prefix stripped
- [ ] parse: missing `tag_name`/`html_url`, non-JSON, empty data → nil
- [ ] isNewer: 0.10.3 > 0.10.2; 0.11.0 > 0.10.9; 1.0.0 > 0.99.99; equal → false;
      older → false; `0.10.2.1 > 0.10.2`; garbage ("abc", "") → false
- [ ] throttle: never-checked → true; 23h ago → false; 25h ago → true; disabled → false
- [ ] check(): injected fetch returning newer/equal/older/throwing → ReleaseInfo? matches;
      URL requested is the pinned kmichels/yafda endpoint
- [ ] Settings: `updateCheckEnabled` defaults to true when unset (the
      `bool(forKey:)`-returns-false trap, same as `appendTrailingSpace`)

## Logging & Observability

`Logger(subsystem: "local.yafda", category: "UpdateChecker")`. One `.info` line per check
(outcome: up-to-date / update found / skipped-throttle / failed + error). No log on the
happy menu path.

## Alternatives considered

- **Sparkle**: rejected in `distribution.md` §7; unchanged.
- **Auto-download the DMG**: more moving parts (quarantine, disk, partial downloads) for a
  user base that can click a link; rejected.
- **Manual-only check (no launch check)**: preserves README's "no network" claim
  verbatim, but silently defeats the feature's purpose (nobody checks manually). Default-on
  with an off-switch and an honest README is the better trade.

## Implementation Notes (Living Section)

*Updated during implementation.*

### 2026-07-26 - Implemented as specified, three deviations

- **`check(fetch:)` also takes an injectable `localVersion` parameter**
  (default `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`). The
  design's signature only mentioned `fetch:`, but the bare SPM debug binary
  (`.build/debug/YAFDA`, used by `--selftest`) has no embedded Info.plist —
  `CFBundleShortVersionString` only exists in the packaged `.app` that
  `scripts/make_app.sh` produces. Without an injectable local version, the
  `check()` self-tests couldn't control the comparison and would silently
  compare against `"0.0.0"`.
- **`MainMenu.build()`/`install()` gained an `appDelegate: AppDelegate?`
  parameter** (default nil). The design specified `MainMenu.swift` for both
  update items but `build()` was previously a pure, stateless builder with no
  way to reach live state or trigger a check. The update items' actual
  behavior (running the check, opening the URL, refreshing on menu-open) now
  lives in a small `@MainActor NSObject`/`NSMenuDelegate`
  (`MainMenu.UpdateMenuController`) created inside `build()`; a
  `MainMenu.liveUpdateController` static retains it, since `NSMenuItem.target`
  is unretained and nothing else would keep the controller alive between
  clicks (or, for the self-test build, between `build()` returning and the
  self-test inspecting `target != nil`).
- **Manual check shows "Checking for Updates…" (disabled) while in flight**,
  addressing the plan review's Medium finding that a silent multi-second
  network round trip on a menu item reads as broken. Still menu-item state
  only, no dialog.
- **`AppDelegate.swift` is 511 lines**, 11 over the repo's 500-line hook
  warning (`~/.claude/hooks/verify-code.sh`). The addition is one `Task`
  block in `applicationDidFinishLaunching` plus a 7-line `runUpdateCheck()`
  helper; splitting the file is a separate, larger refactor out of scope for
  this change. Flagging here rather than silently exceeding it.

## Open Questions

None — shape approved in conversation 2026-07-26.
