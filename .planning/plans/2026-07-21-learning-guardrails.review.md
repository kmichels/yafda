Here is the review of the implementation plan, categorized by severity. 

### High
*   **Contraction/Apostrophe Edge Case in `apply`:** `isWordStart` and `matchEnd` use `!(isLetter || isNumber)` to define word boundaries. This treats apostrophes (`'`) and hyphens (`-`) as boundaries. A rule for "can" will match inside "can't", resulting in "intended't". 
    *   *Fix:* Expand the boundary check to consider intra-word punctuation (like apostrophes) as part of the word, or use `\b` via `NSRegularExpression` / Swift's `Regex` instead of manual character inspection.
*   **Case-Preservation Loss in `apply`:** The new `apply` method appends `correction.intended` exactly as stored. If the user speaks at the start of a sentence ("Focus is good") and the rule is `focus` -> `Phocus`, it works. But if the rule is `focus` -> `phocus`, it will output "phocus is good", losing the original capitalization of the matched text. 
    *   *Fix:* Check if the first character of the matched substring in `text` is uppercase, and if so, capitalize the first character of `correction.intended` before appending.

### Medium
*   **Legacy Rule Deadlock:** In `add()`, `isUsefulMapping` is checked *before* looking for an existing rule. If a user's `learned.json` already contains a bad rule (e.g., `have` -> `work`) from before this PR, they can never update it to `have` -> `halve`. The guard will reject the update, and the old bad rule will survive forever.
    *   *Fix:* Check if the `heard` phrase already exists in `learned.corrections` *before* applying the `isOrdinaryPhrase` guard. If it exists, allow the update so users can fix legacy poison.
*   **Complex Locale Identifiers:** `SystemWordChecker` converts `en-US` to `en_US` by replacing hyphens. This works for simple locales but fails for complex BCP-47 tags (e.g., `zh-Hans-CN` does not map to `zh_Hans_CN` in Apple's spell checker dictionaries). 
    *   *Fix:* If `NSSpellChecker` fails to recognize the language, it may default to the system language or fail open/closed. Ensure there is a fallback (e.g., `en_US`) or use `Locale.components` to safely format the identifier.

### Low
*   **Typography in Toast Summary:** `LearnOutcome.summary` uses a hyphen with spaces (` - `) instead of an em-dash (` — `) for " - too common to rewrite safely". 
    *   *Fix:* Update to `"— too common to rewrite safely"` for native macOS UI polish.
*   **Acronym Length Guard:** `isOrdinaryWord` strips non-alphanumerics and checks `token.count >= 2`. A spoken acronym like "A. B. C." might be split into "A.", "B.", "C.". Stripping punctuation makes them length 1, so they are marked as *not* ordinary. This correctly allows them to be learned (which is good), but ensure this aligns with your intended acronym behavior.
*   **Redundant Lowercasing:** In `isUsefulMapping`, `normalizedForComparison` lowercases the string, but it is called on strings that might have already been lowercased depending on the call path. Not a bug, but a minor performance redundancy.
