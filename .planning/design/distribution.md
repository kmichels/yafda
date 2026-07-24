# Shipping Mutter to other people — strategy

**Status**: Draft for decision
**Created**: 2026-07-24
**Reviewed**: Gemini 3-reviewer panel + direct code verification

## The short version

**The Mac App Store is closed to this app** — not hard, architecturally closed. `TextInserter`
posts synthetic `CGEvent`s into other applications, which the App Sandbox forbids and no
entitlement unlocks. That single fact ends the question.

**Direct distribution is unusually cheap here.** The bundle is one statically-linked binary:
no frameworks, no dylibs, no XPC services. The step that costs most apps days — signing nested
code for notarization — does not exist. Roughly a day of mechanical work.

**The mechanical work is not the risk.** A non-technical user has to grant Accessibility by
hand, and that has no API, no prompt that finishes the job, and no reliable way to confirm it
worked. That step decides whether this is usable by anyone who isn't Konrad.

Recommendation: **notarized DMG for a few named people**, and treat their first launch as the
real test. No website, no Sparkle, no support process until one non-technical person has
dictated a sentence unaided.

## Verified starting position

Checked against the code and the keychain, not assumed:

| | |
|---|---|
| Bundle contents | `Mutter`, `Info.plist`, `Mutter.icns`, `_CodeSignature`. Nothing else. |
| Nested code | **None** — no `.framework`, `.dylib`, `.xpc` |
| Third-party dynamic links | **None** — `otool -L` shows only system libraries |
| Dependencies | WhisperKit 1.0.0, swift-argument-parser 1.8.2, statically linked |
| Hardened runtime | **Not enabled** (`flags=0x0(none)`) |
| Sandbox | Not enabled; no `.entitlements` file exists |
| iCloud | **No entitlement, no ubiquity container** — a plain path under `CloudDocs` |
| Signing | Self-signed `WhisperFlow Dev` |
| Bundle id | `local.mutter` — not a valid distributable identity |
| Version | Hardcoded `1.0` in `make_app.sh`; no bump mechanism |
| Minimum OS | macOS 26.0, Apple Silicon |

**Certificates on this machine**: `Apple Development` ×2, `Apple Distribution: kodner
consulting, inc.`, `3rd Party Mac Developer Installer: kodner consulting, inc.`

**No `Developer ID Application` certificate exists.** The two distribution certs are App Store
certs and cannot sign for direct download. No `notarytool` credentials are stored either. Step
zero is a certificate, not code.

## Why the App Store is closed

Two independent reasons. Either alone is fatal:

1. **`TextInserter.sendKeystroke`** posts `CGEvent`s to `.cghidEventTap` to synthesize ⌘V into
   whatever app has focus. A sandboxed process cannot post events to other processes. This is
   the whole "text appears at your cursor" feature.
2. **`HotkeyMonitor`** uses `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` to
   watch a modifier held down system-wide. That needs Accessibility, which sandboxed apps
   cannot hold.

*Reviewer nuance worth recording:* reason 2 is a consequence of the push-to-talk design, not
of global hotkeys in general — Carbon's `RegisterEventHotKey` gives you a sandbox-legal
chord-style hotkey. But it cannot express "hold this modifier and talk", and **reason 1 stands
regardless**. Switching hotkey APIs would not open the App Store.

A sandbox-legal Mutter is: open a window, click, speak, copy the result yourself. That is a
worse product than the dictation already in macOS. **Drop the App Store goal** rather than let
it shape decisions.

## What direct distribution requires

### Tier 1 — installable by a stranger (~1 day)

1. **Create a Developer ID Application certificate.** Needs Account Holder/Admin on the
   `kodner consulting, inc.` team. Blocks everything else.
2. **Change the bundle id** to a real reverse-DNS identity, e.g. `com.kodnerconsulting.mutter`.
   **Do it now, not later.** It costs Konrad a TCC re-grant (his third today), but changing it
   after other people have installed would orphan *their* permissions too. The machinery for
   this already exists and was exercised today: `Settings.migrateLegacyDefaults` carries the
   preferences, `AppPaths.migrateDataDirectory` carries the data folder. Add the old id to
   `legacySuiteNames` and the old folder name to `dataDirectoryNames`.
3. **Enable hardened runtime** (`codesign --options runtime --timestamp`), with an
   entitlements file granting `com.apple.security.device.audio-input`.
4. **Notarize and staple** — `notarytool submit --wait`, then `stapler staple`. One
   submission, nothing nested to sign recursively.
5. **Package as a signed, notarized DMG** with an Applications symlink.
6. **Verify the way a stranger would**: download over HTTPS so the quarantine bit is actually
   set, then `spctl -a -vvv -t install`, and launch from a *fresh user account*. Testing on the
   build machine proves nothing — local files are never quarantined.

### Tier 2 — maintainable (~2 days on top)

7. **Sparkle 2.x**, or users are stranded on whatever they first installed.
   *Corrected after review:* an earlier draft called this the biggest complexity jump because
   of Sparkle's XPC services. That is a **sandboxed-app** requirement. Mutter is unsandboxed,
   so the standard framework integration applies and the XPC bundles can be omitted. Still
   real work — EdDSA keys, an appcast, hosting, and Sparkle becomes the first nested signed
   code in the bundle — but not the cliff it was described as.
8. **A real version scheme.** `1.0` is hardcoded. Sparkle compares `CFBundleVersion`, so it
   must increase monotonically. Drive it from a git tag.
9. **A release script.** Notarization credentials go in a keychain profile, **never in the
   script** — `make_app.sh` is in a public repo.
10. **Uninstall story.** Dragging the app to the Trash today leaves **3.3 GB** of Whisper
    models in Application Support, plus the prefs plist and the iCloud folder. For a
    distributed app that is not acceptable; ship a documented uninstall or an in-app
    "Remove all data".

### Tier 3 — public (weeks, and a standing obligation)

Landing page, docs, privacy policy, support inbox, and answering strangers forever.
Out of scope until Tier 1 has survived a real person.

## The part that actually decides this

**Accessibility.** Everything above is a checklist. This is the genuine problem.

The user must open System Settings → Privacy & Security → Accessibility, unlock, find or add
Mutter, and toggle it. The app can deep-link and prompt once, but it cannot complete the
grant, and macOS only applies it to a **new process** — which is why `relaunch()` already
exists. The failure mode for a non-technical user is: install, hold key, speak, nothing
appears, conclude it's broken.

**Mutter already handles this better than most apps.** `AppDelegate` falls back to putting the
transcript on the clipboard, says so in plain language, and plays a sound. For distribution
purposes that fallback is the most valuable code in the app. It deserves investment: a
first-run window that blocks until Accessibility is granted, with a screenshot and a recheck
button.

Two more, both from review:

- **Hardened runtime is a security requirement here, not just a notarization checkbox.** An
  app holding Accessibility with no hardened runtime and no library validation is an
  attractive injection target — anything that can write to it inherits the ability to read
  keystrokes and drive the machine. This is the strongest argument in the whole document for
  doing step 3 properly.
- **Sync should be opt-in.** The app currently creates a folder in the user's iCloud Drive
  without asking. Fine for Konrad, presumptuous for a stranger. *For accuracy:* it syncs
  `learned.json`, `vocabulary.json` and `snippets.json` — **not** audio, transcripts or
  history. A reviewer claimed otherwise; the code does not.

## Smaller things that will bite

- **The app exits silently on any unrecognized argument.** `Main.swift` falls through to
  `usageAndExit()`, which prints usage and calls `exit(0)`. Launched from Finder that is an
  app that vanishes with a success code and no window. Default to `.app` mode on unknown
  input instead of exiting.
- **No launch-at-login.** Users will expect it from a menu-bar app; macOS 13+ wants
  `SMAppService`, which also triggers a system notification the user must be told about.
- **`LSUIElement` means no Dock icon.** A non-technical user who dismisses the window may not
  find the app again. The menu-bar item is the only affordance.
- **Model download has no resume, retry, or disk-space check.** 1.6 GB over a flaky
  connection, on a laptop that may not have the space. The defaults are right — engine
  defaults to Apple (instant, no download) and Whisper is opt-in at `small` — so this only
  hits users who opt in, but it should show the size before starting.
- **Self-test fixtures contain "Phocus", "Hasselblad", "X2D II"** and a UI example string
  using `focus → Phocus`. Harmless, but idiosyncratic in a shipped product.
- **Konrad's own `learned.json` / `vocabulary.json` must not ship.** They live in Application
  Support, not the bundle, so this is safe today — worth keeping true.

## Who can actually run this

- **macOS 26 (Tahoe) or newer**
- **Apple Silicon only**
- **Apple Intelligence** for Styles, Transforms and Voice Profile; dictation and vocabulary
  work without it

A narrow slice. Right for friends on current hardware; wrong for a public launch chasing volume.

## Licensing and naming

- MIT fork; `LICENSE` already carries both copyright lines. Distribution is permitted.
- **Courtesy**: upstream is a two-commit project whose author has an unanswered PR from
  Konrad. Shipping a renamed, far more capable fork to real users without a word is a poor
  look. A short note is cheap.
- **Name**: GNOME's window manager is Mutter. No macOS or trademark conflict in any realistic
  reading, but it muddies search results for a *public* app. Irrelevant for friends-and-family.
- The README's "100% on-device" is accurate for processing; the app does fetch Whisper models
  from Hugging Face and speech assets from Apple. The README discloses this. Any landing page
  must too.

## Options

| Option | Effort | What it buys |
|---|---|---|
| **A. Stay personal** | zero | Right answer if nobody has actually asked. |
| **B. Notarized DMG, named recipients** | ~1 day | A stranger can install and run it. No updates. **Recommended.** |
| **C. B + Sparkle + release script** | +2 days | Sustainable for a small group. |
| **D. Public launch** | weeks + ongoing | A product and a support obligation. |
| **E. App Store** | impossible | Would mean deleting the hotkey and auto-insert. |

## Recommendation

**B now. C when the second update is needed. D only if demand appears.**

1. Create the Developer ID cert — blocks everything.
2. Change the bundle id, once, now.
3. Hardened runtime + entitlements + notarize + staple + DMG.
4. Fix the silent-exit-on-unknown-argument bug.
5. Make iCloud sync opt-in.
6. Build first-run Accessibility onboarding.
7. Hand it to **one** non-technical person. Watch. Do not help. Fix what actually breaks.

Step 7 is the plan; 1-6 are preparation for it.

## What the review got wrong (recorded so it isn't re-raised)

The panel's headline blocker was **iCloud entitlement failures** — missing provisioning
profile, a force-unwrap crash when iCloud is off, and no conflict resolution. All three are
false for this app: there is no iCloud entitlement (`AppPaths.swift:82` explains the plain-path
choice), `syncAll()` guards on `nil` and logs, and a tested three-way merge has existed since
2026-07-23. It also described the synced payload as "audio/transcripts"; it is corrections,
vocabulary and snippets.

## Open questions

1. Who is this for? A named person changes the plan; "someday maybe" argues for A.
2. `com.kodnerconsulting.mutter`, or its own domain?
3. Accept a third TCC re-grant today to fix the bundle id permanently?
4. Tell upstream before shipping a renamed fork to real users?
