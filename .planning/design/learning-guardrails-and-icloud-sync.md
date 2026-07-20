# Learning Guardrails + iCloud Sync - Design Document

**Status**: Draft
**Created**: 2026-07-20
**Last Updated**: 2026-07-20
**Upstream**: https://github.com/janisbelozerovs-dev/murmur (default branch `main`)

## Problem Statement

Two separate problems, addressed together because the second must not ship before the first.

### Problem 1: transcript editing poisons the correction store

`LearnedStore.learn(original:corrected:)` fires whenever the user edits a transcript in
History (`AppDelegate.swift:212`). It runs a word-level LCS diff and treats *any*
substituted run as a pronunciation fix. The only rejection rule is
`isUsefulMapping()`, which discards a mapping only when `heard` is under two characters
or equals `intended`.

Consequently, editing a transcript for *wording* rather than to fix a mishearing
invents a bogus rewrite rule. Those rules are then applied globally to every future
transcript by `LearnedStore.apply(in:)` (called on the live dictation path at
`AppDelegate.swift:312`, `Main.swift:51`, `Main.swift:95`), which produces more text
the user wants to edit, which learns more bogus rules. It is a positive feedback loop.

`apply(in:)` compounds this. It loads all corrections, sorts by `heard.count`
descending, and applies each as a global case-insensitive whole-word regex over the
*same mutating string*, sequentially. Bidirectional pairs therefore collapse
deterministically:

| Stored rules | Sorted order | Net effect on any text |
|---|---|---|
| `Phocus`→`focus`, `focus`→`Phocus` | `Phocus` (6) then `focus` (5) | every "focus" **and** "Phocus" becomes "Phocus" |
| `more`→`RAW`, `RAW`→`more` | `more` (4) then `RAW` (3) | every "RAW" **and** "more" becomes "more" |

Observed on a real store after roughly one day of use: 36 corrections, of which 23 were
harmful. Single common words rewritten globally included `my`→`a`, `God`→`guide`,
`have`→`work`, `It's`→`than`, `form`→`forum`, `defeat`→`datasheet`. The word "RAW"
had become undictatable.

### Problem 2: learnings are per-machine

All state is local: `~/Library/Application Support/Murmur/*.json` plus
`~/Library/Preferences/local.murmur.plist`. Using Murmur on a second Mac means
re-teaching every correction and vocabulary term from scratch. There is no export,
import, or sync of any kind.

## Requirements

### Functional

**Fix (upstream PR):**
- A mapping whose `heard` side could plausibly occur in ordinary speech must not be
  learned automatically from a transcript diff.
- A mapping must not be learned when its reverse is already stored.
- `apply(in:)` output must be independent of correction ordering, and no region of the
  input may be rewritten more than once.
- Explicit teaching via the Voice Training page is unaffected. The user stating a
  mapping outright is not a guess and is not second-guessed.
- The existing "Learned N corrections" feedback names what was learned and what was
  skipped.
- No change to the on-disk format. Existing `learned.json` files must load unchanged.

**Sync (local branch only):**
- `learned.json`, `dictionary.json`, `snippets.json` shared between two Macs via iCloud
  Drive. History and scratchpad are explicitly excluded.
- Merging must be non-destructive: a correction present on either machine survives.
- Deleting a correction on one machine must not be undone by a merge from the other.
- iCloud Drive absent, logged out, or unreachable degrades to local-only silently.

### Non-Functional

- The fix must be small and idiomatic enough to be accepted into an hours-old repo
  (created 2026-07-20, two commits, one author, no PRs, no CONTRIBUTING guidance). It
  follows the author's existing `runSelfTest()` convention rather than introducing
  XCTest.
- The sync change must stay confined to `AppPaths` plus one new file, so the local
  branch rebases cleanly onto upstream.
- No new third-party dependencies.
- No Apple Developer account required. Verified: the app is unsandboxed with no
  entitlements, so a plain path under `~/Library/Mobile Documents/com~apple~CloudDocs/`
  is writable without a provisioning profile or CloudKit container.

## Architecture

### Branch topology

| Branch | Base | Contents | Destination |
|---|---|---|---|
| `main` | upstream | untouched tracking branch | — |
| `local/main` | `main` | design docs + fix + sync; the build we run daily | never pushed upstream |
| `fix/learning-guardrails` | `main` | fix commits only, cherry-picked | fork → PR |

Planning documents live only on `local/main`, so the PR branch cannot pick them up.

### Components - the fix

**`WordChecker`** (new, ~25 lines, `Sources/Murmur/WordChecker.swift`)

Single responsibility: answer "could this phrase occur in ordinary speech?" A protocol
with two implementations - `SystemWordChecker` wrapping `NSSpellChecker` for
production, and a fixed-word-set fake for tests.

The seam is required, not decorative: `NSSpellChecker` learns words per user, so its
verdicts differ between machines and drift over time. Self-tests asserting against the
live checker would pass on one Mac and fail on another.

**`LearnedStore.isUsefulMapping(heard:intended:)`** gains two guards:

- *Ordinary-speech guard*: reject when every whitespace-separated token in `heard` is an
  ordinary word. A token is ordinary when, after trimming surrounding punctuation and
  lowercasing, it contains no digits, is at least two characters, and is spelled
  correctly. Lowercasing is essential - spell checkers accept any capitalised token as a
  proper noun, and digit rejection preserves model names like `X2D2`.
- *Reverse guard*: reject when `intended`→`heard` is already stored.

**`LearnedStore.apply`** splits in two:

- `apply(in:)` - existing signature, loads the file, delegates. Unchanged call sites.
- `apply(in:using:)` - takes corrections explicitly. Single left-to-right pass over the
  original string; each source region is consumed at most once. Order-independent.

**`MainView`** - the learn-feedback toast reports skipped mappings alongside learned ones.

### Components - sync

**`AppPaths.syncedDirectory`** - returns
`~/Library/Mobile Documents/com~apple~CloudDocs/Murmur/` when iCloud Drive is present,
`nil` otherwise.

**`SyncedStore`** (new, `Sources/Murmur/SyncedStore.swift`) - merge on load, write both
copies on save, for the three shared files.

### Data model changes (sync branch only)

`LearnedCorrection` gains `var updatedAt: Date?`. `LearnedData` gains
`var deleted: [Tombstone]?` where `Tombstone` is `{ key: String, at: Date }`. Both
optional, so unmodified upstream builds still decode the file.

Merge algorithm for `LearnedData`:

1. Key corrections on `(heard.lowercased(), intended)`.
2. Union both sides; on collision take `max(timesSeen)` and the later `updatedAt`.
3. Union tombstones.
4. Drop any correction whose key has a tombstone at or after its `updatedAt`. A missing
   `updatedAt` (an entry written by an unmodified upstream build) is treated as
   `Date.distantPast`, so a tombstone always wins over a legacy entry.
5. Union `terms`, minus tombstoned terms.

Without step 4 a union merge silently resurrects deleted rules - the specific failure
that motivated this design, since the reference store had 23 rules pruned by hand.

## Data Flow

**Learn:** user edits transcript → `extractCorrections` diffs → each candidate passes
guards → survivors stored → toast names learned and skipped.

**Apply:** transcript produced → `apply(in:using:)` single pass → text inserted.

**Sync load (launch):** read local; read remote; merge; use merged.
**Sync save:** merge current into both; write local atomically; write remote atomically.
**iCloud absent:** local only, no error surfaced.

## API Design

```swift
protocol WordChecker {
    /// True when `word` is an ordinary word of the user's language.
    func isOrdinaryWord(_ word: String) -> Bool
}

extension WordChecker {
    /// True when every token could occur in ordinary speech.
    func isOrdinaryPhrase(_ phrase: String) -> Bool
}

enum LearnedStore {
    static func apply(in text: String) -> String
    static func apply(in text: String, using corrections: [LearnedCorrection]) -> String

    static func isUsefulMapping(heard: String, intended: String,
                                existing: [LearnedCorrection],
                                checker: WordChecker) -> Bool
}

struct Tombstone: Codable, Equatable {
    var key: String
    var at: Date
}

enum SyncedStore {
    static func merge(_ local: LearnedData, _ remote: LearnedData) -> LearnedData
    static func load() -> LearnedData
    static func save(_ data: LearnedData)
}
```

## Testing Strategy

Extends the existing `runSelfTest()` convention wired to `--selftest`. No new test
target, no new dependency.

### Guard tests (`LearnedStore`)

Corpus is 36 real mappings from an actual poisoned store, each with a known verdict,
run against the fake `WordChecker` for determinism.

Measured against the live `NSSpellChecker` during design: **20 of 23 junk mappings
rejected, 10 of 13 legitimate mappings retained.**

- Known false negatives (junk that survives): `Phocus`→`focus`,
  `Phocus standard`→`focus-stack`, `Lightroom, right`→`Lightroom`. All survive because
  they contain user-specific vocabulary a dictionary reads as distinctive. Harm is
  bounded by the single-pass `apply`, and the toast now names them so they can be
  deleted.
- Known false positives (legitimate mappings lost): `Dot force`→`.phos`, `TIF`→`TIFF`,
  `J.P`→`JPEG`. All redundant - `Dot Foss` still covers `.phos` and four other rules
  still cover JPEG.

These numbers are reported in the PR description rather than smoothed over.

### Cascade tests (`LearnedStore.apply(in:using:)`)

- Given `Phocus`→`focus` and `focus`→`Phocus`, input `"focus Phocus"` must not collapse
  to a single value, and output must be identical whichever order the rules arrive in.
- Given `more`→`RAW` and `RAW`→`more`, "RAW" must survive.
- No region rewritten twice.

### Merge tests (`SyncedStore`, local branch)

- Union of disjoint stores keeps both sides.
- Colliding entry takes the higher `timesSeen`.
- Tombstoned entry stays deleted after merge.
- Entry re-learned after its tombstone survives.
- Round-trip through JSON preserves tombstones.
- Merge is commutative: `merge(a, b) == merge(b, a)`.

These need a temporary directory, which is a larger lift than the existing pure-function
cases. They stay on the local branch and out of the PR.

### Edge cases

- Empty store, empty transcript, mapping with punctuation only.
- `learned.json` written by an unmodified upstream build (no `updatedAt`, no `deleted`).
- Remote file corrupt or truncated.
- Remote evicted to a `.icloud` placeholder.

## Error Handling

| Condition | Behaviour |
|---|---|
| iCloud Drive absent / logged out | local-only, silent |
| Remote JSON corrupt | log, keep local, **do not** overwrite remote until a clean read succeeds |
| Remote evicted (`.icloud` placeholder) | request download, skip this merge cycle - never treat absent as empty |
| Local JSON corrupt | fall back to remote if readable, else empty store |
| Atomic write fails | log, keep in-memory state, retry on next save |

The "absent is not empty" rule matters most: treating a not-yet-downloaded file as an
empty store would merge to empty and then write that emptiness back, destroying both
copies.

## Logging & Observability

The app has no logging framework today and adding one is out of scope for the PR.

**Fix branch (PR): adds no logging.** Visibility into guard decisions is delivered
through the existing toast, which names both learned and skipped mappings. Introducing
`os.Logger` to a repo that has never used it would enlarge the diff and invite a
style debate on a change whose point is a bug fix.

**Sync branch (local only):** uses `os.Logger`, subsystem `local.murmur`, category
`sync`:

- `.info` on merge: counts in from local, in from remote, merged, tombstoned.
- `.error` on unreadable remote, failed write, or eviction, including the file path and
  the underlying error - not just its message.

No transcript text, correction text, or vocabulary term is ever logged. The store is a
record of how the user speaks, and log files have a different privacy lifetime than
Application Support.

## Implementation Notes (Living Section)

_Empty - populated during implementation._

## Open Questions / Accepted Limitations

- **Launch-time sync only.** A machine left running for days will not see the other's
  changes until relaunch. Acceptable given single-user, never-concurrent usage. A
  `DispatchSource` file watcher is the escape hatch if it becomes annoying.
- **`timesSeen >= 2` before applying** was considered and rejected. It would block
  legitimate one-off corrections from taking effect and make the feature feel broken.
  The ordinary-speech guard carries the load instead.
- **Phonetic-similarity scoring** was considered and rejected for the PR. More
  principled, but threshold tuning without a corpus is guesswork and the diff is too
  opinionated for a first contribution.
- **`Phocus`→`focus` residual.** The user's own vocabulary defeats a dictionary-based
  guard by construction. Mitigated, not solved.
- **Upstream may decline.** If so, `local/main` becomes a maintained fork; the fix is
  already isolated in its own commits, so nothing changes structurally.
