Here is the review of the implementation plan, categorized by severity.

### High
*   **Lost Update Race Condition:** Although you snapshot `local` *after* the blocking iCloud read, there is still a CPU-bound window between `local = LearnedStore.load()` and `LearnedStore.save(merged)`. If the user teaches a new word or snippet via the UI during this exact window, the background thread’s `save(merged)` will silently overwrite and destroy that new data.
*   **All-or-Nothing Base Snapshot:** `saveBase(base)` is called only once at the very end of `syncAll()`. If the app quits, crashes, or is killed after `syncLearned` completes but before `syncSnippets` finishes, the base snapshot is never saved. On the next launch, the stale base will cause the merge to misinterpret the already-synced remote data, leading to data resurrection or unintended deletions. *Fix: Save the base incrementally after each store successfully syncs.*

### Medium
*   **Concurrent Save Collisions:** While `.atomic` file writes prevent torn reads, they do not prevent lost updates at the file level. If the background sync calls `LearnedStore.save()` at the exact millisecond the main thread calls it, one will overwrite the other. The architecture lacks a serial queue or actor to serialize disk writes for these stores.
*   **Hardcoded iCloud Path:** Relying on `Library/Mobile Documents/com~apple~CloudDocs` is an undocumented macOS implementation detail. If iCloud Drive is disabled, this folder might still exist locally (acting as a black hole), or macOS updates could change the path, breaking sync silently.
*   **App Termination Mid-Sync:** `syncAll` runs on a `DispatchQueue.global`. If the user launches the app and quits immediately, the sync will be terminated mid-flight. While `NSFileCoordinator` protects the file integrity, the sync cycle will abort unpredictably.

### Low
*   **Redundant Conflict Resolution:** In `SyncMerge.merge`, the `(true, true)` case does not check if `localValue == remoteValue`. If both machines independently make the exact same edit, it still invokes the `resolve` closure. This is functionally harmless but logically redundant.
*   **Flaky Verification Scripts:** Task 5 relies on `sleep 5` to wait for the background sync to finish. iCloud daemon response times are highly variable; this will occasionally fail during manual verification if `bird` is sluggish.
*   **Memory Overhead on Merge:** `SyncMerge.merge` creates a `Set` of all keys from base, local, and remote, then iterates through them. For very large vocabularies, this creates temporary memory spikes, though likely negligible given the current single-digit KB file sizes.
