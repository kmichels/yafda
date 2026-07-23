Here is a review of the implementation plan, categorized by risk level.

### High
*   **Swift Concurrency Thread Pool Blocking (Architecture):** In Task 4, `VocabularyStore.load()` is called synchronously inside the `Task` in `AppDelegate`. Because `load()` performs synchronous File I/O and uses an `NSLock`, it will block a thread in Swift's cooperative thread pool. In Swift 6, this is a strict anti-pattern and can lead to thread starvation.
    *   *Fix:* Convert `VocabularyStore` to a global `actor` to handle synchronization without `NSLock`, or make `load()` `async` and use `Task.yield()` / `Task.detached` for the file I/O.

### Medium
*   **State Divergence / Stale Data (Architecture):** Task 2 explicitly leaves `TextFormatter()` defaulting to the legacy `dictionary.json`. While this avoids a disk read in the default initializer, it creates a split source of truth. If the user adds a correction in the new UI, it saves to `vocabulary.json`. Any existing or future code (including `TextFormatter.runSelfTest()`) that relies on the default `TextFormatter()` will silently use stale legacy data.
    *   *Fix:* Update `TextFormatter.loadDictionary()` to pull from `VocabularyStore.correctionMap()` under the hood, ensuring the app has a single source of truth.
*   **Daemon Resource Leaks on Timeout (Risk):** In Task 3, the 3-second timeout correctly cancels the Swift `Task` running `LanguageModelSession.respond`. However, Apple's FoundationModels daemon may not immediately abort its internal generation upon task cancellation. If a user does rapid, repeated dictations while the model is hanging, it could stack up orphaned requests in the daemon.
    *   *Fix:* Acceptable for v1, but document this behavior. Ensure `LanguageModelSession` is deallocated immediately upon timeout.

### Low
*   **Main Thread File I/O (Performance):** In Task 5, `VocabularyStore.load()` and `save()` are called synchronously on the main thread inside SwiftUI (`onAppear` and button actions).
    *   *Fix:* For a tiny JSON file this will likely not cause a noticeable hitch, but wrapping the I/O in a `Task` is safer for UI responsiveness.
*   **Case-Sensitivity in Correction Map (Edge Case):** In Task 1, `correctionMap(from:)` uses the exact `misheard` string as the dictionary key. If the user inputs "Focus" (capitalized) as the misheard word, but the speech recognizer outputs "focus" (lowercase), `TextFormatter` might miss the replacement if its internal lookup isn't case-insensitive.
    *   *Fix:* Ensure `correctionMap` lowercases the `misheard` keys when building the dictionary, matching the deduplication logic in `migrate(from:)`.
*   **Punctuation Stripping in Guard (Edge Case):** In Task 3, `core(_:)` strips punctuation. If a user adds a vocabulary word that *contains* punctuation at the edges (e.g., `".NET"`), `core` will strip the `.` and compare `"NET"` against the vocabulary (which holds `".NET"`). The guard will reject the valid substitution.
    *   *Fix:* Acceptable for v1, but worth noting if users frequently add programming terms or stylized names with leading/trailing symbols.
