# Learning Architecture Review - Design Document

**Status**: Reviewed (3 Gemini rounds + Opus adversarial + 3-reviewer panel) — awaiting Konrad approval
**Created**: 2026-07-26
**Trigger**: the "bot mini" → "Ann mini" incident (2026-07-26). Konrad's framing, adopted
as the goal: *"the whole point of this thing is that it needs to get smarter the more it
is used."* Mandate: the right way, not the easy way.
**Method note**: v1 of this doc proposed a WordChecker-based junk floor and sync
tombstones. Independent adversarial review (Opus, fresh context, verified against live
stores and source) refuted both — the floor was empirically anti-correlated with junk on
the real data, and tombstones re-proposed a design this project already rejected on
2026-07-21 (`learning-guardrails-and-icloud-sync.md:157-164`). v2 is rebuilt on that
review plus Gemini round 1. The review log at the end records what changed and why.

## Problem Statement

YAFDA accumulates exactly the data a learning dictation app needs — explicit vocabulary,
misheard→intended pairs from user edits, per-rule fire records — and fails to deliver it
to the components that could learn from it:

- **Whisper's decoder prompt is consumed by junk.** `biasTerms()`
  (`LearnedStore.swift:439-456`) orders `learned.terms` → correction intendeds →
  vocabulary → snippet triggers; `WhisperEngine.swift:114` takes `prefix(60)` of the
  terms and `:117` additionally caps the encoded prompt at 200 BPE tokens (so the real
  budget is tokens, not 60 slots, and varies with term length). On mac-mini-pro the 61
  `learned.terms` entries alone consume the entire budget: **vocabulary AND correction
  intendeds contribute zero terms to recognition.** The user's post-incident vocabulary
  additions were inert. The junk includes `laptop` — residue of the deleted
  `Konrad → laptop` poisoned rule, still biasing recognition today.
- **The junk is manufactured by design.** `record()` (`LearnedStore.swift:144-164`), on
  *rejecting* a candidate mapping, still appends its intended side as a bias term
  (`:153-154`). Every stray content edit donates words (`by`, `hit`, `it will`,
  `are 80%`, the typo `dication`). Terms pass no guard — `appendTerm` (`:233-241`)
  checks only emptiness and duplication.
- **Term deletions do not stick.** `SyncMerge.mergeTerms` (`:50-62`) is union-only and
  never reads its `base` parameter (a dead argument). Its documented justification —
  "no delete UI exists, so removals are never inferred"
  (`learning-guardrails-and-icloud-sync.md:196`) — is a conditional whose condition
  became false when the Training page gained per-row delete (`MainView.swift:1867`).
- **Correction mappings never reach a model.** Correction *intendeds* do reach the
  recognizer as bare terms (`:452`); the heard→intended mappings — the app's most
  specific error knowledge — feed only deterministic string replacement. The
  disambiguator receives a bare word list (`AppDelegate.swift:369-370`).
- **Fire data exists but is not aggregated.** AMUX-755 already records which rules fired
  per dictation (`HistoryEntry.appliedCorrections`, `AppDelegate.swift:380-383`) — but
  nothing aggregates it onto the rule, History holds 50 entries ≈ **19 hours** at the
  user's real dictation rate (measured live), `HistoryStore.update` (`:52-57`) silently
  **drops** `appliedCorrections` on the first edit, and `HistoryEntry.id` embeds
  `text.hashValue`, which is per-process-seeded — unstable across launches and changed
  by every edit. Any feedback loop keyed on today's History breaks. (Also unresolved:
  0 of the live 50 entries carry the field — verify the deployed build actually persists
  it before building on the seam.)
- **Guards are inconsistent across stages.** The learning guard protects taught words
  per-token even inside multi-word entries (`containsTaughtWord`,
  `LearnedStore.swift:622`); the disambiguator's protects whole entries only
  (`VocabularyDisambiguator.swift:139`) — `bot mini` in vocabulary does not protect
  `bot`. Same invariant, two implementations, one correct.
- **Two rewriting paths are unguarded.** Per-app style (`RewriteEngine.rewrite`,
  free-form LLM output used directly, `AppDelegate.swift:387-398`) has no structural
  gate — dormant today, a side door once any style is set. And the vocabulary `misheard`
  side drives `TextFormatter` global rewrites with **no `WordChecker` guard at all** —
  the same class as the learned-rule poison bug, unguarded because it is user-authored.
- **A model-facing learner already exists, unaccounted for.** `VoiceProfileStore`
  feeds 30 recent transcripts to the on-device model every 250 words
  (`VoiceProfile.swift:41-85`) — unsynced (UserDefaults), silently divergent across the
  three machines, and outside every observability plan until now.

Each recent bug (`**repo**`, Neil→amux, bot→Ann) was a local symptom. The disease:
**no quality model, no budget discipline, no model-facing learning, no feedback loop —
and no way to measure whether any of it works.**

## First principles: what "learning" must mean here

Four signal classes, currently conflated or discarded:

| Signal | Example | Today | Worth |
|---|---|---|---|
| **Explicit teaching** | Dictionary entry `Phocus` (+ optional misheard) | vocabulary.json; evicted from prompt | Highest — user intent, curated |
| **Implicit correction** | History edit diff → `Amak → Amux` | learned.corrections + junk side-effect | High when guarded — real observed errors |
| **Usage feedback** | Rule fired N times in real dictations | Recorded per-dictation (AMUX-755), never aggregated, destroyed on edit | The missing loop — **valid for corrections only**; for bare terms, "the word appeared" measures frequency, not usefulness, and must not drive rank |
| **Negative signal** | User deleted a term; user marked a correction wrong; gate rejected a swap | Deletion resurrects; no marking affordance; rejections invisible | The only defense against confident junk |

An architecture "gets smarter with use" when classes 3 and 4 exist and feed back into how
classes 1 and 2 are ranked and delivered — **and when improvement is measurable.**

## Success metric (new in v2 — the biggest v1 gap)

An **eval harness ships in P1, before any tuning knob**: a fixture corpus of recorded
audio clips + expected transcripts covering the real vocabulary (Phocus, Amux, YAFDA,
bot-mini, X2D II, JPEG, Helicon Focus, …), runnable headless against both engines. Every
subsequent choice — prompt size (whether 60 terms is even right, given prompt-induced
hallucination means smaller can beat bigger), ranking variants, few-shot formats, decay
thresholds — is judged by corpus accuracy, not vibes. Without this, every knob in this
doc is unfalsifiable.

## Target architecture

### A. Provenance metadata, additively (no one-way doors)

Keep the four stores. Add metadata **without changing any existing field's shape**:

- `learned.terms` stays `[String]` (an old build must keep decoding; a shape change
  trips `preserveCorruptFile` and presents as a factory-fresh app —
  `LearnedStore.swift:91-99`). Provenance metadata lives in a **sidecar shared file**
  (`learned-meta.json` in `CloudDocs/YAFDA/`, its own three-way merge) — NOT inside
  `learned.json`: an un-upgraded client re-encoding the main file would silently strip
  any field it doesn't know (panel finding, same mechanism as the `syncLearned`
  fresh-construction footgun). The sidecar is advisory rank data with no
  existence semantics — term existence is decided solely by the main merge — so an old
  client ignoring it costs staleness, never data. Keyed by lowercased term. Lowercased keys are merge/lookup **identity only** — display and
  prompt casing always come from the `[String]` entry itself, which `appendTerm` already
  dedupes case-insensitively keeping first-seen casing; nothing case-sensitive is lost.
- All new fields everywhere are **Optional** (or hand-written `init(from:)`): synthesized
  Decodable fails the whole file on a missing key — this project has been burned before
  and documented it (`SyncedStore.swift:20-25`).
- `Provenance`: `source` (.taught / .learnedCorrection / .biasSideEffect), `createdAt`,
  and — **corrections only** (see class-3 note) — `appliedCounts: [String: Int]` keyed by
  machine plus `lastAppliedAt`. Per-machine counters make the sync merge exact and
  deterministic: each machine increments only its own key, merge is field-wise max, rank
  uses the sum. (A single shared counter would force a lossy LWW-or-double-count choice.)
  Reset applies on **normalized** intended change (lowercased, punctuation-trimmed) —
  fixing casing or punctuation on a rule keeps its earned rank; changing the word resets
  it.
- `SyncBase` gains new **optional** keys only, honoring the existing `decodeIfPresent`
  discipline (`SyncedStore.swift:26-35`).
- **Known footgun to fix in the same change**: `syncLearned` constructs a fresh
  `LearnedData()` and writes it whole (`SyncedStore.swift:237-253`) — any field not
  explicitly copied is silently dropped every sync cycle, by new builds too. Fix is
  compiler-enforced, not discipline-enforced: the merge result is built through
  `LearnedData`'s **memberwise initializer** at the merge site (adding a field becomes a
  build error there), belt-and-suspenders with a Mirror-based selftest asserting the
  handled-field count matches the type's property count.

### B. Budgeted, ranked context assembly

A single `LearningContext` assembler replaces ad-hoc `biasTerms()` /
`VocabularyStore.words()` call sites.

- **Budget in tokens, not term slots** (the real Whisper constraint is
  `promptTokens.prefix(200)`); the assembler packs ranked terms until the token budget
  is spent. The Whisper path already holds a live BPE tokenizer at prompt-build time
  (`pipe.tokenizer`, `WhisperEngine.swift:112`) — exact packing is free there; consumers
  without a tokenizer use the conservative 4-chars-per-token estimate against a 180-token
  ceiling. Whether the budget should even be fully spent is an eval question
  (prompt-induced hallucination: Whisper spuriously emits prompt terms, so junk in the
  prompt actively corrupts output).
- **Ranking = class ordering first and foremost**: taught > correction-intended >
  legacy `.biasSideEffect`. On the live data this alone moves all 22 vocabulary entries
  and 19 intendeds ahead of the ~40 junk terms — **it fixes the reported bug with no
  other mechanism**. Within-class: corrections by `appliedCount` (resets when
  `intended` changes — mirroring `merging`'s existing `timesSeen` reset,
  `LearnedStore.swift:210-215`); bare terms by recency only (frequency ≠ usefulness for
  terms).
- **No spell-checker floor.** v1's `isOrdinaryWord` floor is dead: tested against the
  live stores it excluded `Konrad`, `bot mini`, `repo`, `JPEG`, `Helicon Focus` while
  keeping `dication` and `0h` — anti-correlated with junk, because "not in the spell
  dictionary" ≠ "user vocabulary" (typos and fragments are non-words too). It also
  imported `WordChecker` semantics from a mechanism with opposite risk (global rewrite
  vs decoder bias — `LearnedStore.swift:549-559` states the rewrite rationale), was
  non-deterministic across machines (NSSpellChecker learns per-user,
  `WordChecker.swift:69-71`), and would have run synchronously on the main actor in the
  dictation hot path. Junk is handled by provenance class + lifecycle instead.
- **Exploration floor**: a fixed reserve (~15% of the token budget) for the newest
  entries regardless of counts, so established terms can never permanently starve a new
  teaching.
- **Store-level eviction becomes rank-aware**: `appendTerm`/`mergeTerms` currently evict
  oldest-first at 300 — after this redesign that would evict the *earliest-taught* terms
  first. Eviction order follows the same ranking; taught entries are exempt.
- **Consumers**: Whisper (token-budgeted prompt), Apple engine (`contextualStrings`,
  own cap), disambiguator (ranked terms; few-shot mappings arrive only in P4 — see
  amplifier/brake coupling).

### C. Lifecycle: deletions that stick, pruning with consent

- **Terms join the existing three-way base merge — no tombstones.** Tombstones were
  already evaluated and rejected in this project (2026-07-21,
  `learning-guardrails-and-icloud-sync.md:157-164`); v1 re-proposed them unknowingly and
  the adversarial review found the rejection held: expiry vs offline machines guarantees
  resurrection races, re-adds fight live tombstones (and re-adding variants is
  demonstrably this user's pattern), and expiry introduces the design's first wall-clock
  dependence. Instead: delete the `mergeTerms` special case and run terms through
  `SyncMerge.merge` with `base`, keyed by lowercased term — the same mechanism that
  already gives corrections/vocabulary/snippets sticky deletions, clock-free, inheriting
  the existing adversarial test suite. Implementation trap called out by review:
  `SyncBase.terms` stays `[String]` (written for old-build decode compatibility only);
  the merge keys land in a NEW optional `termKeys` field which, when present, is the
  **single source of truth** for base state — readers never consult both, so the two
  representations cannot meaningfully drift (changing the existing field's type makes `decodeIfPresent` throw → base lost →
  one-time resurrection union). `termKeys` is **local-only** (sync-base is never shared;
  the shared file's term list stays `[String]`, keyed on read), so old clients never
  interact with it. **Nil rule, stated explicitly**: a missing/nil `termKeys` (first run
  after upgrade, or any base loss) means "deletion history unknown" → that cycle merges
  as union (never infers deletions), then records `termKeys`; deletions stick from the
  second cycle on. Missing is unknown, never empty. **How deletion propagates without
  sharing the base** (pre-empting a recurring review confusion): each machine infers
  deletions against its OWN base — deleter: base∋X, local∌X → remove X from the shared
  file; every other machine: base∋X, remote∌X → delete locally. Absence in the shared
  file is the traveling signal; the base never travels. This is the identical mechanism
  vocabulary/corrections/snippets already use, live-verified cross-machine on
  2026-07-25.
- **Stop the factory**: `record()`'s reject path stops appending bias terms, full stop.
  (Accepted mappings keep contributing their intendeds — they passed real guards. The
  reject path was pure junk manufacture; if a rejected mapping's wording matters, the
  user teaches it.)
- **Retro-prune is user-reviewed, not automatic.** The Training page surfaces a
  "suspected junk" list (driven by provenance class + never-applied + not present in
  vocabulary or correction intendeds), with select-all convenience; nothing is deleted
  without a click, and `learned.json.prebackup-<date>` is written before the first
  deletion. A destructive one-shot migration on the primary user's only store was the
  wrong shape (and the spell-checker version of it would have deleted `Palomino`, `RAW`,
  `JPEG`, `TIFF`…). Note the prune's limit: correction intendeds re-enter the prompt via
  their rules — pruning a term does not remove its rule; rule review is the corrections
  page's job.
- **Decay is an explicit maintenance step, not a `load()` side effect** (`load()` runs
  inside sync cycles and every store op — decay there would fight the union/merge and
  self-trigger sync). It emits deletions through the same base-merge path as manual
  deletes. Thresholds are named constants, revisited once real `appliedCount` data
  exists. Taught entries never decay.

### D. Symmetric guards + gated rewriting

- One shared taught-word invariant helper (per-token, multi-word aware —
  `containsTaughtWord` semantics) used by the learning guard AND
  `VocabularyDisambiguator.sanitized()`. Fixes "bot mini doesn't protect bot".
- The vocabulary `misheard` side gets the same ordinary-phrase guard as learned rules at
  entry time (UI warns, doesn't block — user authority, but informed): it drives the
  identical global-rewrite mechanism and today has no guard at all.
- Similarity gate on disambiguator substitutions: `metaphoneKey(a) == metaphoneKey(b) ||
  normalizedLevenshtein(a,b) <= 0.34` (`<=` deliberate); Metaphone branch only for pure
  ASCII-letter pairs, non-English pairs get Levenshtein-only at `<= 0.5`. Scope stated
  plainly: blocks orthographically-unrelated hallucinations; cannot block true
  sound-alikes (`and→Ann`) — which is why `.off` stays the default on macOS 26.
- Style rewrite bound (own design doc, P4): no ungated rewriting stage survives. That
  doc's requirements include prompt-injection resistance — dictated text is untrusted
  input to the rewrite model, so output validation and length/structure bounds are gate
  requirements, not niceties.

### E. Observability and the feedback loop

Per dictation, EVERY transforming stage reports an outcome — including the two v1 forgot
(`TextFormatter` hard corrections and `SnippetStore.expand`):
`ran-unchanged | substituted(deltas) | rejected-by-gate(deltas) | timed-out | unavailable | skipped`.

- **Prerequisite fixes (P2, before any feedback logic)**: `HistoryStore.update` must
  preserve `appliedCorrections` (today it destroys the attribution data on first edit);
  `HistoryEntry.id` becomes a stored UUID (today it embeds a per-process-random hash),
  with a one-time migration assigning UUIDs to legacy entries at first load, **persisted
  to disk immediately in the same load path** (otherwise every launch regenerates
  different ids and stability is theater); History is local-only and outside the sync
  set, so the migration has no cross-machine surface;
  verify the deployed build actually persists `appliedCorrections` at all (0/50 live
  entries carry it). History cap raised (50 entries ≈ 19h measured; raw-transcript
  retention argues for a larger, size-aware cap).
- History entry carries outcomes + raw transcript (local-only file, verified outside the
  sync set); os_log mirrors outcomes with `.public` stage names and `<private>` content,
  surviving History rotation.
- **Feedback wiring (corrections only)**: `substituted` outcomes increment the rule's
  `appliedCount`; `appliedCount` resets when a rule's `intended` changes. Negative
  signal v1 is **explicit only**: a per-correction "this was wrong" affordance in
  History (decays the entry hard); the re-edit heuristic stays deferred.
- **Amplifier and brake ship together**: few-shot delivery of corrections to the
  disambiguator is P4, gated on the negative-signal affordance existing first. A
  poisoned rule today does string replacement; few-shot without a brake would also teach
  the model the wrong mapping — a strictly worse failure mode. Never ship confident junk
  to a model with no way to lose confidence.
- `VoiceProfile` joins the observability regime (its generation logged as a stage) and
  its divergence across machines is documented as accepted (persona is per-machine
  cosmetic, not correction data).

## Phasing (each phase independently shippable, reviewed, releasable)

1. **P1 — stop the bleeding + measure** (no schema changes): eval harness + fixture
   corpus; `biasTerms` → class ordering (derivable without schema: vocabulary and
   correction-intended cross-reference; array order as recency proxy — *within-class
   count ranking explicitly deferred to P3*); token-based prompt packing; `record()`
   reject-path junk factory removed; per-token taught-word protection in the
   disambiguator (shared helper); stage-outcome os_log.
2. **P2 — schema + prerequisites** (additive only): `termMeta` provenance, optional
   fields, exhaustive-copy fix in `syncLearned`; terms → base merge via `termKeys`
   (deletions stick); History fixes (stable ids, preserved attributions, raised cap, raw
   transcript + outcomes persisted); prebackup + user-reviewable prune UI.
3. **P3 — the loop**: `LearningContext` assembler for all three consumers;
   `appliedCount` aggregation with intended-change reset; explicit negative-signal
   affordance; decay as maintenance step; exploration floor; rank-aware eviction.
4. **P4 — model-facing learning + remaining gates**: few-shot corrections to the
   disambiguator (now that the brake exists); similarity gate; style-rewrite bound (own
   doc); revisit prompt size against the eval corpus.

## Testing strategy

- Every pure component lands with selftests in the established suite style; the terms
  base-merge inherits and extends the existing `SyncMerge` adversarial cases (deletion
  vs re-add, cross-machine races, missing-`termKeys` files, the fresh-construction
  exhaustive-copy property).
- Migration tests against a sanitized fixture of the real mac-mini-pro stores.
- The eval corpus is the acceptance test for every ranking/budget/gate change from P1 on.

## Risks / open questions

- [ ] Eval corpus recording effort — needs Konrad's voice for realism; how many clips is
      enough to be decision-grade?
- [ ] Decay/threshold constants are placeholders until P3 data exists.
- [ ] `appliedCorrections` absent from all 50 live entries — build-version question to
      resolve in P1 (cheap) before P2 builds on the seam.
- [ ] macOS 27 / PCC disambiguation: B and E are engine-agnostic; few-shot format (P4)
      may need revisiting per model.
- [ ] Whether the Apple engine's `contextualStrings` path has its own eviction/cap
      pathology — measure in P1 rather than assume.

## Review log

- **Gemini plan review round 1**: High — tombstones-in-band fragile against old-build
  field dropping → superseded (tombstones dropped entirely in v2). Mediums adopted:
  negative signal explicit-only; Metaphone ASCII-scoped. Low adopted: exploration floor.
- **Opus adversarial review (fresh context, live-data verification)**: refuted the junk
  floor empirically (anti-correlated with junk on the real store) and the tombstone
  design (prior 2026-07-21 rejection; convergence races; clock dependence) — both
  removed; base-merge adopted for terms with the `termKeys` decode trap honored.
  Adopted: token budgets; eval harness as P1's centerpiece; user-reviewed prune with
  prebackup; amplifier/brake coupling (few-shot moved to P4); `appliedCount` resets on
  intended change; terms not ranked by frequency; History prerequisite fixes
  (`update` dropping attributions, unstable ids, 19h window); TextFormatter/Snippet
  stages added to observability; VoiceProfile accounted; store-eviction rank-awareness;
  factual corrections (`containsTaughtWord:622`, token cap 200).
- **Gemini round 2**: High adopted with precision (explicit nil-rule for `termKeys`:
  missing = unknown → one union cycle, then sticky; noted `termKeys` is local-only).
  Mediums adopted: per-machine `appliedCounts` map (field-wise max merge, sum for rank);
  token packing uses the live Whisper tokenizer, 4-chars/token fallback. Low adopted:
  legacy History id migration.
- **Gemini round 3**: High REJECTED with receipts — it claimed local-only `termKeys`
  breaks cross-device deletion; three-way merge propagates deletion through absence in
  the shared file against each machine's own base (the mechanism every other store
  already uses, live-verified 2026-07-25); its fix contradicted the asserted
  sync-base-is-local invariant. Mediums: casing-identity clarification adopted;
  History-sync concern moot (History never syncs). Low adopted: reset on normalized
  intended change only.
- **Panel (Security/Architecture/Correctness) on v2**: High adopted — exhaustive-copy
  protection becomes compiler-enforced (memberwise init at merge site + Mirror selftest).
  Mediums adopted: provenance moves to a sidecar shared file (legacy clients would strip
  an in-band field); UUID migration persists immediately; prompt-injection named a P4
  style-gate requirement; `termKeys` declared single source of truth over the
  compatibility `terms` array.
