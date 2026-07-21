Here is the review of the iCloud Sync implementation plan, categorized by severity. 

### High
*   **Main-Thread Deadlock at Launch:** Calling `NSFileCoordinator` synchronously on the main thread *before* `NSApplication.shared.run()` is highly risky. If the `bird` (iCloud) daemon is hung, the app will bounce in the dock indefinitely and fail to launch without ever showing a UI. 
    *   *Mitigation:* Wrap the coordination in a timeout, or move `syncAll()` to run asynchronously immediately after the app finishes launching (even if it means a slight delay in data availability).
*   **Local Changes Blocked by Evicted Remote:** In `syncLearned`, if `readShared` returns `.notDownloaded`, the function returns early to protect the remote data. However, this means any *local* additions/edits are trapped on the Mac and will not upload to iCloud until the OS decides to finish downloading the remote file. 
    *   *Mitigation:* This is the safest approach for data integrity, but you should log a specific warning so debugging "why isn't my Mac syncing" is obvious.

### Medium
*   **Accidental Local Deletion Wipes iCloud:** If a user accidentally deletes `learned.json` via Finder (or if the file corrupts and loads empty), `base` will still have the old keys. The 3-way merge will interpret this as a legitimate deletion of all rules and will silently wipe the iCloud copy.
    *   *Mitigation:* Implement a "wipe guard." If the merge calculates that 100% of a non-empty store is being deleted, abort the sync and log an error.
*   **Unentitled iCloud Path Reliability:** Hardcoding the path to `com~apple~CloudDocs/Murmur` works in practice, but without the `com.apple.developer.icloud-container-identifiers` entitlement, macOS does not guarantee immediate sync priority for this folder. `bird` may occasionally ignore or delay syncing it.
    *   *Mitigation:* Acceptable given the constraints (no paid signing identity), but document this limitation for users.
*   **Coordinated Write Temp File Behavior:** `Data.write(to:options: .atomic)` inside an `NSFileCoordinator` block using `.forReplacing` can sometimes confuse the coordinator because `.atomic` writes to a temporary file and renames it, bypassing the exact URL the coordinator locked. 
    *   *Mitigation:* Drop `.atomic` when writing inside a `.forReplacing` coordination block; the coordinator already handles the safe replacement semantics.

### Low
*   **Data Duplication in `SyncBase`:** `SyncBase` duplicates the entire state of all three stores on disk. While fine for small JSON files, if the user's personal dictionary grows to tens of thousands of words, this doubles the memory and disk footprint during launch.
    *   *Mitigation:* Acceptable for now, but keep in mind if performance degrades.
*   **Upstream Schema Fragility:** `SyncBase` relies on `LearnedCorrection` and `Snippet` conforming to `Codable`. If upstream adds a new non-optional field to these models in the future, `sync-base.json` will fail to decode, falling back to an empty base (union mode). 
    *   *Mitigation:* Acceptable since it degrades safely to a union, but worth noting for future maintenance.
*   **Case-Only Edits May Revert:** Because `key(for:)` lowercases the trigger/heard phrase, if a user edits a snippet trigger locally from "sig" to "SIG", the merge logic will see it as the same key. Depending on the resolution order, the casing change might be discarded. 
    *   *Mitigation:* Acceptable cosmetic loss to maintain strict 1:1 parity with `LearnedStore.merging`.
