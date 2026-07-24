# Mutter — Local Wispr Flow Rebuild

A fully local macOS dictation app that reproduces Wispr Flow's core loop:
**hold a key → speak → release → clean text appears at your cursor in any app.**

## How Wispr Flow works (research summary)

- **Push-to-talk:** hold `fn` (default on Mac) to dictate; release to stop.
- **Hands-free:** double-tap the dictation key to toggle recording without holding.
- **Insertion:** transcribed text is pasted at the cursor in whatever app is focused
  (Gmail, Notion, Slack, VS Code, any text field).
- **AI cleanup:** removes filler words (um/uh), auto-punctuates, capitalizes,
  understands spoken commands, formats lists.
- **Personal dictionary:** custom spellings/terms applied to output.
- **History:** past transcripts accessible from the app.
- Wispr Flow sends audio to **cloud** ASR + LLM. Our rebuild is **100% on-device**.

## Architecture (this rebuild)

Native Swift menu bar app — no Python, no model downloads from third parties,
no network. Uses Apple's on-device speech stack.

| Component | Implementation |
|---|---|
| Menu bar UI | `NSStatusItem` (mic icon, animates while recording), history menu, quit |
| Global hotkey | `NSEvent` global monitor for `flagsChanged`: hold **fn** (or right ⌥) = push-to-talk; double-tap = hands-free toggle. Needs Accessibility permission. |
| Audio capture | `AVAudioEngine` input tap → temp `.caf` file. Needs Microphone permission. |
| Transcription | `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26, fully on-device; model asset auto-downloaded by macOS once) |
| Text cleanup | Rule-based formatter: strip fillers (um, uh, you know), spoken commands ("new line", "new paragraph"), sentence capitalization, terminal punctuation, personal dictionary substitutions |
| Dictionary | `~/Library/Application Support/Mutter/dictionary.json` — `{ "spoken": "replacement" }` |
| Insertion | Save clipboard → put transcript on clipboard → synthesize ⌘V via `CGEvent` → restore clipboard |
| History | Last 50 transcripts persisted to `history.json`; menu shows recent, click to copy |
| Feedback | Sounds on start/stop, menu bar icon state |

## Project layout

```
Whisper Flow/
├── PLAN.md
├── README.md
├── Package.swift              # SwiftPM executable target
├── Sources/Mutter/
│   ├── main.swift             # entry: CLI modes + app launch
│   ├── AppDelegate.swift      # status item, wiring, permissions
│   ├── HotkeyMonitor.swift    # fn / right-option hold + double-tap detection
│   ├── AudioRecorder.swift    # AVAudioEngine → temp audio file
│   ├── Transcriber.swift      # SpeechAnalyzer wrapper + asset install
│   ├── TextFormatter.swift    # cleanup pipeline + dictionary
│   ├── TextInserter.swift     # clipboard + ⌘V injection
│   └── HistoryStore.swift     # persisted transcript history
└── scripts/
    └── make_app.sh            # builds Mutter.app bundle + ad-hoc codesign
```

## CLI test modes (headless verification)

- `Mutter --transcribe <audiofile>` — transcribe a file, print raw + formatted text
- `Mutter --selftest` — run TextFormatter unit checks
- (default, no args) — run as menu bar app

## Build & test sequence

1. `swift build` compiles clean.
2. `--selftest` formatter checks pass.
3. `say -o sample.aiff "..."` → `--transcribe sample.aiff` returns correct text
   (verifies the full on-device ASR path without a microphone).
4. `scripts/make_app.sh` produces `Mutter.app`.
5. Launch app; user grants **Microphone** + **Accessibility**; hold fn, speak,
   release → text pastes into focused app.

## Permissions the user must grant (one-time)

1. **Microphone** — prompted automatically on first recording.
2. **Accessibility** — System Settings → Privacy & Security → Accessibility →
   add Mutter.app (required for the global hotkey and for ⌘V injection).

## Out of scope for v1 (future)

- LLM-based tone rewriting / context awareness per app (could add via local
  Foundation Models framework later)
- Streaming partial results while speaking
- Snippets, team features, 100+ language auto-detect (locale is configurable though)
