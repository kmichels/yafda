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

Four sandbox violations. The first is airtight on its own:

1. **`TextInserter.sendKeystroke`** (`TextInserter.swift:68-78`) posts `CGEvent`s to
   `.cghidEventTap` to synthesize ⌘V into whatever app has focus. A sandboxed process cannot
   post events to other processes. This is the whole "text appears at your cursor" feature,
   and it is gated on `AXIsProcessTrusted()` at `AppDelegate.swift:356`.
2. **`Process()` spawning `/usr/bin/tccutil`** (`AppDelegate.swift:179-185`). Arbitrary
   subprocess execution is flatly denied by the sandbox and is a guaranteed review rejection.
3. **Direct path access to `~/Library/Mobile Documents/com~apple~CloudDocs/`**
   (`AppPaths.swift:93-96`). Sandbox-denied.
4. **Two global event monitors**, not one — `HotkeyMonitor.swift:60` (`.flagsChanged`) and
   `TransformManager.swift:56` (`.keyDown` for the ⌥1/⌥2 transforms), plus
   `TextInserter.copySelection()` synthesizing ⌘C.

**Correction to an earlier draft of this document**, which claimed global hotkeys inherently
require Accessibility and cited Karabiner, Alfred and TextExpander as precedent. That was
wrong twice over. Carbon's `RegisterEventHotKey` provides a sandbox-legal hotkey with both
press and release events, so hold-to-talk *is* expressible — what it cannot register is a
**bare modifier** (fn / right-⌥ alone), which is Mutter's specific design
(`HotkeyMonitor.swift:22-26`). And the three cited apps were decorative rather than evidence:
Karabiner is a DriverKit extension, a different mechanism entirely. Those examples are
removed; the conclusion does not need them and was weakened by them.

A sandbox-legal Mutter is: open a window, click, speak, copy the result yourself. That is a
worse product than the dictation already in macOS. **Drop the App Store goal** rather than let
it shape decisions.

## What direct distribution requires

### Tier 1 — installable by a stranger (~1 day)

1. **Create a Developer ID Application certificate.** Needs Account Holder/Admin on the
   `kodner consulting, inc.` team. Blocks everything else.
2. **Change the bundle id** to a real reverse-DNS identity, e.g. `com.kodnerconsulting.mutter`.
   **This is free, not a cost.** An earlier draft billed it as "another TCC re-grant" and
   posed it as a decision. It isn't: moving from the self-signed `WhisperFlow Dev` cert to a
   Developer ID cert changes the designated requirement *by itself*, so the re-grant is
   already unavoidable at step 1. The bundle-id change rides along for nothing — and doing it
   later, after other people have installed, would orphan *their* permissions too.

   **A latent bug here was found and fixed during review** (`Settings.swift:30`).
   `legacySuiteNames` did not include `local.mutter`, so a bundle-id change would have
   migrated settings from the *stale* `local.murmur` domain — silently restoring this
   morning's `hotkey`, `engine`, `whisperModel` and `inputDeviceUID` rather than carrying
   today's forward. Worse than resetting to defaults, because it looks deliberate. The list
   is now newest-first with a comment explaining why order is load-bearing.

   What survives the change correctly, verified: the data folder keys on the *app name*, not
   the bundle id (`AppPaths.swift:11`), so `learned.json`, `vocabulary.json`, `snippets.json`,
   history, `sync-base.json` and `whisper-models/` all carry over; and the iCloud folder is a
   plain path, not a ubiquity container, so it is unaffected.
3. **Enable hardened runtime.** `--timestamp` is mandatory for notarization and was missing
   from an earlier draft:
   ```
   codesign --force --options runtime --timestamp \
     --entitlements Mutter.entitlements \
     --sign "Developer ID Application: kodner consulting, inc. (Q8DWKP2B6L)" "$APP"
   ```
   Entitlements: `com.apple.security.device.audio-input` only — and make sure the file does
   **not** accidentally contain `com.apple.security.app-sandbox`. Reviewed and *not* needed:
   `com.apple.security.automation.apple-events` (hardened runtime does not propagate to child
   processes, and `NSWorkspace.openApplication` goes through LaunchServices, not AppleEvents)
   and `disable-library-validation` (everything third-party is statically linked).
4. **Notarize and staple** — `notarytool submit --wait`, then `stapler staple`. One
   submission, nothing nested to sign recursively.
5. **Prove the ML stack survives hardening.** This is unverified today and is the step most
   likely to surprise: sign with hardened runtime, delete `whisper-models/`, then force a cold
   download, prewarm and transcribe. Do the same for FoundationModels (Styles/Transforms) and
   SpeechAnalyzer. All three work right now *only* because there is no hardened runtime.
   Reading WhisperKit's source suggests it should be fine — it loads pre-compiled `.mlmodelc`
   (data, not Mach-O) with no `MLModel.compileModel` call anywhere, and ANE/Metal compilation
   happens out-of-process — so `allow-jit` and `allow-unsigned-executable-memory` should not
   be needed. That is an inference from code, not a test. Test it.
6. **Package as a signed, notarized DMG** with an Applications symlink, *plus* the
   translocation guard above.
7. **Verify the way a stranger would**: download over HTTPS so the quarantine bit is actually
   set, then `spctl -a -vvv -t install`, and launch from a *fresh user account*. Grant
   Accessibility, quit, relaunch, and confirm the grant **survived** — that is the
   translocation test. Testing on the build machine proves nothing; local files are never
   quarantined.

### Tier 2 — maintainable (~2 days on top)

7. **Updates.** An earlier draft both called Sparkle "the single biggest complexity jump" and
   priced it at 2-3 days. Those contradict each other, and review caught it. Sparkle 2.x ships
   `Autoupdate.app`, `Updater.app` and XPC services that need independent hardened-runtime
   signing in inside-out order, plus EdDSA key generation and custody, plus an appcast and
   hosting. It also destroys the single-static-binary property that makes step 4 trivial.

   **Recommendation: do not use Sparkle for a handful of users.** An in-app "Check for
   updates" that opens the GitHub releases page is a tenth of the work and adequate for a
   named group. Revisit Sparkle only at Tier 3.
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

## App Translocation — the finding that reorders this document

**A DMG is the most reliable way to make the Accessibility grant silently evaporate.**

When a quarantined app is launched from a mounted DMG — or from `~/Downloads` without being
*moved in Finder* — macOS runs it from a randomized read-only path under
`/private/var/folders/.../AppTranslocation/<UUID>/d/`. That path changes every launch.

For this code specifically:

- TCC records the path. The user grants Accessibility to the translocated instance, quits,
  relaunches from the DMG, gets a new UUID, and **the grant is gone.**
- `AppDelegate.swift:196` — `relaunch()` opens `Bundle.main.bundleURL`, so it relaunches the
  *translocated* copy rather than an installed one.
- `resetAccessibilityGrant()` (`AppDelegate.swift:178-188`) compounds it: wipes the grant,
  relaunches the translocated copy, and leaves a second dead row in the Accessibility list.

This produces exactly the symptom this document predicts — "granted it, nothing happens" —
but from a different cause. The danger is that the plan tells Konrad to expect an
Accessibility problem, so he would debug the grant while the actual cause is a path moving
underneath TCC. That is a week of chasing the wrong bug, landing on the one step that *is*
the plan.

**Fix, and it belongs in Tier 1, not Tier 3:** a first-run guard that refuses to continue
unless the bundle path is under `/Applications` (at minimum, that it does not contain
`/AppTranslocation/`), with a "Move to Applications" button. Ship the Applications symlink in
the DMG *and* enforce it in code — the symlink is an invitation, not a guarantee.

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

## The irreversible decision nobody was tracking

**Custody of the Developer ID private key.** Developer ID certificates are limited per team,
and the private key must be backed up somewhere durable. If it is lost, the replacement cert
has a different leaf — which changes the designated requirement — which **breaks the
Accessibility grant for every user who ever installed the app**, with no way for Konrad to fix
it on their machines. `make_signing_cert.sh` already warns about exactly this failure at a
scale of one Mac; distribution raises the blast radius to everyone.

For an app whose entire value depends on a persistent Accessibility grant, this is the
highest-consequence irreversible choice in this document, and the first draft gave it zero
lines. Export the `.p12` and back it up before signing anything.

Related, from the same review: **Developer ID certs can generally only be created by the
team's Account Holder.** The first draft said "Account Holder or Admin"; do not rely on Admin
being sufficient. If Konrad is not the Account Holder on `kodner consulting, inc.`, Tier 1 is
blocked on a person, not on work — which changes "~1 day" to "1 day of work, 2-5 days of
calendar time."

## Smaller things that will bite

- **The app exits silently on any unrecognized argument.** `Main.swift` falls through to
  `usageAndExit()`, which prints usage and calls `exit(0)`. Launched from Finder that is an
  app that vanishes with a success code and no window. Default to `.app` mode on unknown
  input instead of exiting.
- **No launch-at-login, and this is worse than it sounds.** Zero hits for `SMAppService`
  across `Sources/`. Combined with `LSUIElement` (no Dock icon), after a reboot Mutter is
  simply *not running*, there is no window and no Dock icon, and the user holds the key and
  gets nothing — with no affordance explaining why. **This failure is more likely than the
  Accessibility one** and is a two-line fix (`SMAppService.mainApp.register()`). It also
  triggers a system notification the user should be warned about.
- **Nothing stops two copies running at once.** `LSMultipleInstancesProhibited` is absent and
  `relaunch()` sets `createsNewApplicationInstance = true`. An old copy in `~/Downloads` plus
  a new one in `/Applications` gives two status items, two global monitors, **two ⌘V pastes
  per dictation**, and two processes racing on the same `sync-base.json`. The three-way merge
  was designed for two Macs, not two processes on one Mac sharing a file.
- **`resetAccessibilityGrant` becomes a footgun once shipped.** It exists because self-signed
  rebuilds change the signature; on a stable Developer ID cert the grant survives updates, so
  the button's only remaining effect is to break a working install — and it tends to leave a
  stale row in the Accessibility list that the user must remove by hand. Hide it behind a
  debug flag before shipping.
- **The Accessibility prompt fires on every launch.** `AppDelegate.swift:44` calls
  `refreshPermissions(promptAccessibility: true)` unconditionally, so a user who deliberately
  declined is asked again forever.
- **`NSHumanReadableCopyright` still says "Local build — no data leaves this Mac."** Shows in
  Finder's Get Info, and is arguably inaccurate for a shipped build given the Hugging Face and
  Apple asset downloads.
- **Anyone already holding an ad-hoc-signed build must start over.** Ad-hoc signatures have no
  stable designated requirement, so their Accessibility grant is tied to that exact binary and
  dies on first update. They need to delete the app and remove the stale row by hand.
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

1. **Confirm Konrad is Account Holder** on the team, then create the Developer ID cert and
   **back up the private key**. Blocks everything, and the key custody is irreversible.
2. Change the bundle id, once, now. (Free — the cert change forces the re-grant anyway.)
3. **Translocation guard** — refuse to run from outside `/Applications`, with a move button.
4. **Launch-at-login** via `SMAppService`, and `LSMultipleInstancesProhibited`.
5. Fix the silent-exit-on-unknown-argument bug.
6. Hardened runtime + entitlements + notarize + staple + DMG, then **cold-test the ML stack**
   with the models deleted.
7. Make iCloud sync opt-in; hide `resetAccessibilityGrant`.
8. Build first-run Accessibility onboarding.
9. Hand it to **one** non-technical person. Watch. Do not help. Fix what actually breaks.

Step 9 is the plan; 1-8 are preparation for it. Items 3 and 4 were absent from the first
draft and are both more likely to break a stranger's install than the Accessibility grant the
document was originally built around.

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
3. Is Konrad the **Account Holder** on `kodner consulting, inc.`? If not, Tier 1 is blocked on
   another person and the timeline is not his to control.
4. Tell upstream before shipping a renamed fork to real users?

*(Question 3 in the first draft — "accept a third TCC re-grant to fix the bundle id?" — is
withdrawn. Review established the re-grant is forced by the certificate change regardless, so
there was never a choice to make.)*
