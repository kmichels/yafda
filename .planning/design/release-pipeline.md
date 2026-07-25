# Central release pipeline on bot-mini - Design Document

**Status**: Draft for approval
**Created**: 2026-07-25
**Depends on**: `.planning/design/distribution.md` (strategy: App Store closed,
notarized direct distribution is the path)

## Problem Statement

Every Mutter update today is built, signed, and launched per machine, by
hand: pull, `make_app.sh` in a GUI session (the per-machine self-signed cert
cannot sign from SSH without a keychain unlock), quit, relaunch. Two Macs
drift out of date, and 2026-07-25 spent four round trips on this. The
distribution doc prices a notarized DMG for strangers; this doc designs the
pipeline that produces it, with Konrad's own two Macs as the first consumers
so routine updates stop involving a terminal at all.

New fact the distribution doc lacked: bot-mini already holds a working
`Developer ID Application: Konrad Michels (85QL287QYW)` identity (verified
live in the keychain, 2026-07-25) and a validated notarytool keychain
profile (`palomino-notary`, same team, used for Palomino and ImageIntact
releases). Step zero of the distribution doc - "a certificate must be
created" - is already done, just on a different machine than it examined.

## Requirements

### Functional
- One command on bot-mini (`scripts/release.sh`) produces a signed,
  notarized, stapled `Mutter.app` and `.dmg`, headlessly.
- A companion deploy step installs/updates the app on a target Mac over SSH
  (quit, replace `/Applications/Mutter.app`, relaunch) with no GUI-session
  or keychain involvement on that Mac.
- The DMG also lands in `~/shared/files/` so an unreachable machine (laptop
  off the LAN) can be updated by hand later.
- Versioning: `CFBundleShortVersionString` stamped from a `VERSION` file in
  the repo (bumped by the release; `CFBundleVersion` = commit count or short
  hash) instead of the hardcoded `1.0`.

### Non-Functional
- The dev loop (`make_app.sh` + per-machine "WhisperFlow Dev" cert +
  `local.mutter` id) keeps working unchanged for hacking on a checkout.
- TCC grants for the release build survive updates indefinitely (stable
  Developer ID cert + stable release bundle id).

## Key decisions

1. **Release bundle id splits from the dev id.** The release build gets a
   real reverse-DNS id (recommendation: `com.konradmichels.mutter`, matching
   the personal team that signs; final say is Konrad's - the only hard rule
   is pick once, never change). Per distribution.md this rides free: the
   cert change already forces the one-time TCC re-grant, and the defaults
   domain split is already handled in code (verified 2026-07-25):
   `Settings.legacySuiteNames` leads with `local.mutter` and
   `migrateLegacyDefaults()` copies every owned key into whatever domain the
   current bundle id gives `UserDefaults.standard`. The data folder keys on the app NAME, not the bundle id
   (`AppPaths.dataDirectoryNames`), so learned/vocabulary/snippets/history
   survive untouched.
2. **Hardened runtime ON, with a minimal entitlements file.** Notarization
   effectively requires it, and the memory of Palomino's setup applies. New
   file `scripts/release.entitlements` containing only
   `com.apple.security.device.audio-input` (microphone under hardened
   runtime; without it, recording fails silently on a hardened build).
   Accessibility/CGEvent posting needs no entitlement - it stays a TCC
   grant. SPM release binaries carry no `get-task-allow`, so the
   Debug-config notary rejection Palomino hit does not apply.
3. **The data folder stays shared between dev and release builds - with one
   hardening prerequisite.** Review round 3 proposed splitting data dirs per
   bundle id to protect against schema divergence. Rejected: dogfooding IS
   the product's QA, and a dev build pointed at an empty or stale dataset
   tests nothing. The real hazard is narrower and fixable: `LearnedStore`
   and `SnippetStore` silently return an empty store when decode fails, and
   the next save would overwrite the file - a schema-divergent build could
   wipe real data. `VocabularyStore` already has the right idiom (preserve
   the unreadable file as `.corrupt`, never re-save over it). Prerequisite
   before the first release build ships: adopt that preserve-don't-overwrite
   idiom in `LearnedStore` and `SnippetStore`. Schema changes remain
   additive-optional-field only, which every change this week already
   honored.
4. **Same-name instance guard becomes required, not optional.** Dev and
   release builds now have different bundle ids, so
   `LSMultipleInstancesProhibited` no longer prevents one of each running
   together - but both share the same data folder (keyed on app name) and
   the same sync files. At launch, if another running process's bundle
   executable is also named `Mutter` with a different bundle id, show an
   alert and quit. Small, and it protects the stores from exactly the race
   the plist comment warns about.
5. **Push-based deploy first, in-app updates later.** v1 is bot-mini
   pushing to the Macs (this session already does it routinely); an in-app
   update check (serve a version JSON + DMG from R2 or GitHub Releases) is
   a later increment once the pipeline exists. Sparkle is not needed at
   this scale.

## Signing preconditions (review round 1: the High finding)

Headless keychain signing is the classic failure here - it is exactly what
blocked remote `make_app.sh` runs on both of Konrad's Macs on 2026-07-25
(`errSecInternalComponent`). On bot-mini it is a solved, and now *verified*,
precondition: a scratch binary was signed with the Developer ID identity
from this non-GUI session on 2026-07-25 and shows the full
`Developer ID Application -> Developer ID CA -> Apple Root CA` chain. The
key's partition list was configured when the cert was installed (2026-06-14,
Palomino setup).

Because that state can rot (reboot with a re-locked keychain, cert renewal
importing a fresh key), `release.sh` step 0 is a **preflight**: sign a
scratch file; on failure, abort with the remediation printed
(`security set-key-partition-list -S apple-tool:,apple:,codesign: -s
~/Library/Keychains/login.keychain-db`, run interactively). The script never
takes or stores a keychain password.

## Pipeline design

`scripts/release.sh` on bot-mini (new file; `make_app.sh` untouched):

0. Preflight: scratch-file sign with the release identity (see above).
1. `swift build -c release` (arm64; universal is `ARCHS` away if ever
   needed - current floor is Apple Silicon + macOS 26 anyway).
2. Assemble `dist/Mutter.app` - same bundle layout as `make_app.sh`, but
   Info.plist gets the release bundle id and the stamped versions.
3. `codesign --force --options runtime --timestamp \
   --entitlements scripts/release.entitlements \
   --sign "Developer ID Application: Konrad Michels (85QL287QYW)" dist/Mutter.app`
   (No nested code to sign first: the binary is statically linked, no
   dylibs/frameworks/XPC - verified in distribution.md - so hardened
   runtime's library validation has nothing to block.)
4. Stage the signed app + `/Applications` symlink, `hdiutil create
   -format UDZO dist/Mutter-<version>.dmg`.
5. `xcrun notarytool submit dist/Mutter-<version>.dmg --keychain-profile
   palomino-notary --wait` (expect Accepted). **One submission total, of the
   DMG**: notarization tickets are issued per code-signature hash, and a DMG
   submission recursively covers the nested app, so afterward BOTH artifacts
   can be stapled - `xcrun stapler staple dist/Mutter-<version>.dmg` (needs
   the DMG's own ticket, which is why app-only submission cannot produce a
   stapled DMG) and `xcrun stapler staple dist/Mutter.app` on the loose copy
   used for direct pushes. (Review rounds 1 and 2 each proposed a different
   half of this; the sequence above is the one consistent with how tickets
   and stapler actually work, and keeps offline-first-launch robustness for
   both the download path and the pushed-app path. Round 3 doubted the
   loose-app staple after a DMG-only submission; the step verifies itself -
   stapler exits nonzero when no ticket matches the app's cdhash, and the
   spctl gate follows - and the fallback if it ever fails is extracting the
   app from the mounted stapled DMG, or shipping the push path unstapled,
   which quarantine-free SSH copies never needed anyway.)
6. `spctl -a -vvv -t exec` gate on the stapled app: fail the script unless
   the verdict is "accepted, source=Notarized Developer ID".
7. Copy the DMG to `~/shared/files/`.

`scripts/deploy-mac.sh <host>` (new file, run from bot-mini):
`ditto` the stapled app to the host, then a **graceful swap** (review round
1): `osascript -e 'quit app "Mutter"'`, poll `pgrep -x Mutter` until exit
(timeout ~15s; only then fall back to `pkill` with a loud warning, since a
hard kill can interrupt an in-flight store write), replace
`/Applications/Mutter.app`, `open` it, verify the running process path and
bundle id. SSH-copied files carry no quarantine attribute, so Gatekeeper
never assesses this path; the notarization exists for the DMG/download path
and for strangers later. First run per machine: Konrad re-grants
Accessibility + Microphone once (the app's own Settings page already walks
through this).

A round-2 review finding claimed `osascript`/`open` fail from raw SSH
sessions and require root `launchctl asuser` bootstrapping. Rejected on
direct evidence: both worked repeatedly over same-user SSH against both
target Macs on 2026-07-25 (remote `open` launched Mutter on mac-mini-pro;
remote `osascript` quit it). The deploy script's pgrep/bundle-id
verification step exists so that if an environment ever does regress, the
failure is loud rather than a silently headless app.

## Testing Strategy

- `release.sh` is gated end-to-end by its own steps: notary "Accepted" and
  the `spctl` verdict are the tests; the script fails loudly on either.
- Self-test suite must pass when run from the release binary
  (`dist/Mutter.app/Contents/MacOS/Mutter --selftest`) - catches
  hardened-runtime surprises the debug binary cannot.
- First deploy per machine is the acceptance test: grant, dictate a
  sentence, confirm text lands; then one no-op re-deploy to prove grants
  survive an update.
- Instance guard: self-test covers the decision function (same name +
  different bundle id -> refuse) with injected process descriptors; the
  alert path is dogfood-verified.

## Open Questions

- [ ] Bundle id: `com.konradmichels.mutter` ok, or prefer another domain?
- [ ] Version scheme start point: `0.9.0` (pre-share) or `1.0.0`?
- [ ] Should mac-mini-pro's checkout keep a dev cert at all, or does it
      just consume releases from now on (checkout stays for CC dev work)?

## Implementation Notes (Living Section)

(fill in during implementation)
