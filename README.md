# Mutter 🎙️

> **This is a fork** of [janisbelozerovs-dev/murmur](https://github.com/janisbelozerovs-dev/murmur)
> by Janis Belozerovs, MIT licensed, with thanks. It follows its own roadmap and is not
> affiliated with upstream. Fixes that apply to both are sent back as pull requests.
>
> Named **Murmur** until July 2026, after upstream. Renamed to **Mutter** to
> stop the fork and its parent sharing a name.

**Private, unlimited voice dictation for macOS — 100% on-device.**

Hold `fn`, speak, release — clean text appears at your cursor in any app.
No cloud, no subscription, no word limits. Your audio and transcripts never
leave your Mac.

![Mutter dashboard](Resources/screenshot.png)

Mutter is an open-source, fully local take on the modern AI dictation app
(in the spirit of Wispr Flow), built natively in Swift on Apple's on-device
speech and language models, with an optional local Whisper engine.

## Features

- **Push-to-talk dictation** — hold `fn` (or right ⌥) anywhere; release to
  paste at your cursor. Double-tap for hands-free mode.
- **Two recognition engines**, both offline:
  - **Apple** — instant, built into macOS (SpeechAnalyzer, macOS 26).
  - **Whisper** — optional precision engine via
    [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML on the
    Neural Engine). Your vocabulary is fed into the decoder prompt.
- **Pronunciation learning** — a Voice Training page learns how *you* say
  tricky words; corrections you make to transcripts are diffed and learned
  automatically; everything biases future recognition.
- **Cleanup pipeline** — filler-word removal, spoken "new line"/"new
  paragraph", auto-capitalization, personal dictionary, snippets
  (say a trigger phrase → paste a saved block).
- **Styles** — per-app tone rewriting (formal / casual / very casual) using
  Apple Intelligence's on-device model.
- **Transforms** — select text in any app, press ⌥1 to polish grammar or ⌥2
  to turn rough notes into a structured AI prompt, rewritten in place.
- **Dashboard** — history with search and correction-learning, usage stats
  (words, WPM, day streak), insights chart, a Voice Profile persona derived
  locally from what you dictate, scratchpad.

## Requirements

- macOS 26 (Tahoe) or newer
- Apple Silicon Mac
- Xcode 26 command-line tools (`xcode-select --install`)
- For Styles / Transforms / Voice Profile: Apple Intelligence enabled
- For the Whisper engine: a one-time model download (150 MB – 1.6 GB)

## Build & run

```bash
git clone <this-repo>
cd murmur
./scripts/make_app.sh     # builds build/Mutter.app
open build/Mutter.app
```

Optional: run `./scripts/make_signing_cert.sh` once to create a local
self-signed signing certificate — this keeps macOS permission grants valid
across rebuilds. Without it the app is ad-hoc signed and you'll need to
re-grant Accessibility after each rebuild.

### One-time permissions

1. **Microphone** — allow when prompted on first dictation.
2. **Accessibility** — allow when prompted (needed for the global hotkey and
   for pasting). If the app still shows it as missing, use *Settings →
   Reset Grant & Relaunch* inside Mutter.

## CLI test modes

```bash
.build/debug/Mutter --selftest                          # formatter + learning tests
.build/debug/Mutter --transcribe audio.wav              # Apple engine
.build/debug/Mutter --transcribe audio.wav --engine whisper
.build/debug/Mutter --format "um hello new line hi"     # cleanup pipeline only
.build/debug/Mutter --transform "fix this grammer pls"  # on-device LLM polish
```

## Privacy

Everything runs on this Mac: recognition (Apple SpeechAnalyzer or local
Whisper), cleanup, tone rewriting (Apple Intelligence), and the Voice
Profile analysis. Mutter makes no network requests except the one-time
model downloads by macOS itself (Apple speech assets) and, if you opt into
the Whisper engine, the model fetch from Hugging Face. Dictation data is
stored only in `~/Library/Application Support/Mutter/`.

## Architecture

Swift Package, one third-party dependency (WhisperKit, only if you use the
Whisper engine):

```
HotkeyMonitor  →  AudioRecorder  →  Transcriber (Apple) / WhisperEngine
                                        ↓
     TextFormatter → LearnedStore → SnippetStore → RewriteEngine (Styles)
                                        ↓
                        TextInserter (clipboard + ⌘V)
```

See [PLAN.md](PLAN.md) for the original design document.

## License

[MIT](LICENSE). Not affiliated with Wispr Flow, OpenAI, or Apple.
