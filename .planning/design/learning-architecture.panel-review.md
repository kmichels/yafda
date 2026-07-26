# Review Panel: learning-architecture.md

**Reviewers:** Security, Architecture, Correctness
**Date:** 2026-07-26

## Moderated Findings

The design document is exceptionally thorough and well-reasoned, addressing key sync, learning, and telemetry limitations. However, critical risks remain regarding data loss from manual copying during sync, legacy client compatibility stripping metadata, and potential prompt injection in LLM rewriting.

### 🔴 High

**Exhaustive Copying in syncLearned Migration Risk**
Location: Target architecture / A. Provenance metadata, additively
The document notes that syncLearned constructs a fresh LearnedData() and writes it whole, risking silent data loss for any new fields not explicitly copied. Reviewers disagree slightly on severity (Architecture rates it High, Security rates it Low), but both agree manual copying is highly error-prone and prone to regression when new fields are added.
Fix: Instead of manual field-by-field copying in syncLearned, use Swift's Codable synthesis, automated reflection, or a compiler-enforced mapping pattern, backed by a unit test that asserts all properties are copied.
Flagged by: Security, Architecture

### 🟡 Medium

**Legacy clients will strip shared termMeta during sync cycles**
Location: Section A: Provenance metadata, additively (no one-way doors)
While the document addresses the risk of new builds dropping fields during syncLearned copying, it does not address legacy (un-upgraded) clients. If termMeta is stored in the shared sync file, active legacy clients will decode the file (ignoring termMeta), modify it, and write it back, silently stripping the metadata.
Fix: Either make termMeta local-only, sync it via a separate sidecar file that legacy clients do not touch, or explicitly document that co-existence with legacy clients will result in metadata loss.
Flagged by: Correctness

**Legacy HistoryEntry UUID migration requires immediate persistence to prevent regeneration**
Location: Section E: Observability and the feedback loop
The document proposes migrating HistoryEntry.id from a dynamic hash to a stored UUID by assigning UUIDs to legacy entries at first load. If these newly assigned UUIDs are not immediately persisted back to disk, subsequent app launches will regenerate different UUIDs for the same legacy entries, defeating the goal of stable identity.
Fix: Ensure that the one-time migration path explicitly triggers a save/write of the HistoryStore to disk immediately after assigning UUIDs to legacy entries during the first load.
Flagged by: Correctness

**Prompt Injection Risk in Free-Form LLM Rewriting**
Location: Section D: Symmetric guards + gated rewriting
RewriteEngine.rewrite uses free-form LLM output directly without a structural gate. If an attacker can influence the input text, they could manipulate the LLM's rewriting behavior (Prompt Injection), potentially leading to unauthorized data modification or unexpected application behavior.
Fix: Ensure the 'Style rewrite bound' (P4) includes strict output validation, length constraints, and structural sandboxing to prevent prompt injection from altering application behavior or leaking sensitive data.
Flagged by: Security

**Potential Drift Between SyncBase.terms and termKeys**
Location: Target architecture / C. Lifecycle: deletions that stick
Storing terms as [String] and a separate termKeys collection in the local-only SyncBase introduces a redundancy where the two collections can drift if one is updated without the other during local modifications or sync merges.
Fix: Define a unified local-only representation or ensure that termKeys is the single source of truth for the base state during sync, deriving the list of terms from its keys when needed.
Flagged by: Architecture

---

**Verdict:** Address the exhaustive copying risk in syncLearned first, as silent data loss during sync is the most critical failure mode for user data integrity.

---

<details>
<summary>Individual Reviews (click to expand)</summary>



## Security Reviewer

The design document is exceptionally thorough, demonstrating a deep understanding of the system's current limitations, sync mechanics, and failure modes. It correctly identifies critical bugs (such as the syncLearned data loss risk and the lack of guards on LLM rewrites) and proposes robust, phased mitigations. Security and privacy considerations, such as using private in OS logs and gating LLM rewrites, are well-integrated but require strict enforcement during implementation.

### 🟡 Medium

**Prompt Injection Risk in Free-Form LLM Rewriting**
Location: Section D: Symmetric guards + gated rewriting
The document notes that RewriteEngine.rewrite uses free-form LLM output directly without a structural gate. If an attacker can influence the input text (e.g., via dictating specific injection payloads or processing malicious text), they could manipulate the LLM's rewriting behavior (Prompt Injection), potentially leading to unauthorized data modification or unexpected application behavior.
Fix: Ensure the 'Style rewrite bound' (P4) includes strict output validation, length constraints, and structural sandboxing to prevent prompt injection from altering application behavior or leaking sensitive data.

### 🟢 Low

**Regression Risk in Manual Exhaustive Copying during Sync**
Location: Section A: Provenance metadata, additively
The document correctly identifies that syncLearned constructs a fresh LearnedData() and writes it whole, risking dropping new fields. While the document proposes making copying exhaustive, manual copying is highly error-prone and prone to regression when new fields are added in the future.
Fix: Instead of manual exhaustive copying, use Swift's compiler-synthesized Codable or automated reflection/mapping where possible, or implement a unit test that dynamically asserts all properties of LearnedData are copied during sync.

**Potential Information Leakage in OS Logs**
Location: Section E: Observability and the feedback loop
The document states os_log mirrors outcomes with <private> content. However, metadata such as rule names, vocabulary terms, or custom dictionary entries might not be fully covered by the <private> tag and could inadvertently leak sensitive user information (e.g., medical terms, names, passwords) into public OS logs.
Fix: Ensure that any dynamic string interpolated into the public parts of the os_log (such as rule IDs or terms) is strictly sanitized or marked <private> if it can contain user-authored content.

## Architecture Reviewer

The design document is exceptionally thorough, demonstrating a deep understanding of the existing codebase's synchronization, learning, and telemetry limitations. It correctly identifies critical flaws (such as the junk-term feedback loop, unstable history IDs, and sync-deletion bugs) and proposes robust, elegant, and highly practical solutions. The phasing and testing strategies are well-structured, particularly the emphasis on an evaluation harness in P1.

### 🔴 High

**Exhaustive Copying in syncLearned Migration Risk**
Location: Target architecture / A. Provenance metadata, additively
The document notes that syncLearned constructs a fresh LearnedData() and writes it whole, risking silent data loss for any new fields (like termMeta) not explicitly copied. If developers add new metadata fields in the future, they might forget to update the manual copy constructor, leading to recurring sync-loss bugs.
Fix: Instead of manual field-by-field copying in syncLearned, use Swift's Codable synthesis or a compiler-enforced mapping pattern. Alternatively, implement a unit test that uses reflection to automatically compare all properties of LearnedData before and after sync to guarantee no fields are dropped.

### 🟡 Medium

**Potential Drift Between SyncBase.terms and termKeys**
Location: Target architecture / C. Lifecycle: deletions that stick
Storing terms as [String] and a separate termKeys collection in the local-only SyncBase introduces a redundancy where the two collections can drift if one is updated without the other during local modifications or sync merges.
Fix: Define a unified local-only representation or ensure that termKeys is the single source of truth for the base state during sync, deriving the list of terms from its keys when needed, or enforce synchronization of these fields via a private updater.

### 🟢 Low

**Performance and Caching of LearningContext Prompt Assembly**
Location: Target architecture / B. Budgeted, ranked context assembly
The LearningContext assembler will rank and tokenize terms to fit within the Whisper BPE token budget. While the dataset is small, performing tokenization and ranking on the main thread or critical dictation path for every audio chunk or session start without caching can introduce unnecessary latency.
Fix: Cache the assembled and tokenized prompt/context. Invalidate the cache only when the underlying stores (LearnedStore, VocabularyStore, etc.) are modified, rather than re-assembling on every dictation request.

---

**Verdict:** Address the exhaustive copying risk in syncLearned first, as silent data loss during sync is the most critical failure mode for user data integrity.

## Correctness Reviewer

The draft v2 design document presents a highly thorough and well-reasoned architecture for addressing the learning and sync limitations in YAFDA. It successfully refutes weaker patterns from v1 (like tombstones and spell-checker floors) in favor of robust 3-way merges and token-budgeted context assembly. However, minor gaps remain regarding legacy client sync compatibility, stable UUID migration persistence, and non-English similarity gating.

### 🟡 Medium

**Legacy clients will strip shared termMeta during sync cycles**
Location: Section A: Provenance metadata, additively (no one-way doors)
While the document addresses the risk of new builds dropping fields during syncLearned copying, it does not address legacy (un-upgraded) clients. If termMeta is stored in the shared sync file to synchronize appliedCounts across machines, any active legacy client performing a sync cycle will decode the file (ignoring termMeta), modify it, and write it back, silently stripping the metadata for all upgraded clients.
Fix: Either make termMeta local-only (accepting that counts/provenance do not sync), sync it via a separate sidecar file that legacy clients do not touch, or explicitly document that co-existence with legacy clients will result in metadata loss until all nodes are upgraded.

**Legacy HistoryEntry UUID migration requires immediate persistence to prevent regeneration**
Location: Section E: Observability and the feedback loop
The document proposes migrating HistoryEntry.id from a dynamic hash to a stored UUID by assigning UUIDs to legacy entries at first load. If these newly assigned UUIDs are not immediately persisted back to disk, subsequent app launches will regenerate different UUIDs for the same legacy entries, defeating the goal of stable identity.
Fix: Ensure that the one-time migration path explicitly triggers a save/write of the HistoryStore to disk immediately after assigning UUIDs to legacy entries during the first load.

### 🟢 Low

**Undefined mechanism for non-English detection in similarity gate**
Location: Section D: Symmetric guards + gated rewriting
The similarity gate specifies that non-English pairs get Levenshtein-only at <= 0.5 while ASCII-letter pairs use Metaphone or Levenshtein <= 0.34. However, the document does not define how non-English is detected (e.g., via keyboard locale, Whisper language metadata, or character set analysis). Without a clear detection mechanism, non-English pairs might incorrectly fall into the ASCII/Metaphone path, leading to poor phonetic matching or false rejections.
Fix: Explicitly define the language detection source (such as the active dictation locale or engine language configuration) to determine when to apply the non-English Levenshtein-only threshold.

**Potential actor isolation mismatch for background decay maintenance**
Location: Section C: Lifecycle: deletions that stick, pruning with consent
The document states that decay is an explicit maintenance step rather than a load() side effect. If this maintenance step runs on a background task or non-main executor to avoid blocking the UI, but LearnedStore is @MainActor-isolated (as is typical for UI-bound stores in this app), direct modification of the store's state from the background task will cause concurrency issues or runtime traps under Swift strict concurrency.
Fix: Ensure the decay maintenance function is either isolated to the same actor as LearnedStore (e.g., @MainActor) or safely dispatches its updates back to the main actor.

---

**Verdict:** Address the legacy client sync compatibility risk for termMeta to prevent silent metadata loss during the transition phase.

</details>
