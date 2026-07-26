# YAFDA 🎙️

> **This is a fork** of [janisbelozerovs-dev/murmur](https://github.com/janisbelozerovs-dev/murmur)
> by Janis Belozerovs, MIT licensed, with thanks. It follows its own roadmap and is not
> affiliated with upstream. Fixes that apply to both are sent back as pull requests.
>
> Formerly Mutter, formerly Murmur. Renamed to **YAFDA** (Yet Another Fine
> Dictation App) after "Mutter" turned out to collide with another Mac
> dictation app of the same name.

**Private, unlimited voice dictation for macOS — 100% on-device.**

Hold `fn`, speak, release — clean text appears at your cursor in any app.
No cloud, no subscription, no word limits. Your audio and transcripts never
leave your Mac.

![YAFDA dashboard](Resources/screenshot.png)

YAFDA — Yet Another Fine Dictation App — is an open-source, fully local take
on the modern AI dictation app (in the spirit of Wispr Flow), built natively
in Swift on Apple's on-device speech and language models, with an optional
local Whisper engine.

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
cd mutter
./scripts/make_app.sh     # builds build/YAFDA.app
open build/YAFDA.app
```

### Code signing (read this before copying the app anywhere)

Run `./scripts/make_signing_cert.sh` once to create a local self-signed
signing certificate. This keeps macOS permission grants valid across
rebuilds; without it the app is ad-hoc signed and you'll re-grant
Accessibility after every rebuild.

Two consequences worth knowing up front:

- **The certificate is per-machine.** Each Mac creates its own, and although
  they share a name they are different keys. macOS ties a permission grant to
  the specific certificate, so **a build from one Mac will not carry its
  permissions to another** — copying `YAFDA.app` across machines gets you an
  app that has to re-request everything, or silently fails to type. Build on
  each Mac instead. It takes under a minute.
- **The certificate is called `WhisperFlow Dev` and must stay that way.** The
  app has been renamed three times since (WhisperFlow → Murmur → Mutter →
  YAFDA), so the
  name looks like leftover cruft and is a tempting thing to tidy up. Don't.
  The certificate forms half of the designated requirement macOS uses to
  recognise this app, so reissuing it under a current name invalidates the
  signature and drops every permission grant on that machine. The stale name
  is load-bearing.

### One-time permissions

1. **Microphone** — allow when prompted on first dictation.
2. **Accessibility** — allow when prompted (needed for the global hotkey and
   for pasting). If the app still shows it as missing, use *Settings →
   Reset Grant & Relaunch* inside YAFDA.

## CLI test modes

```bash
.build/debug/YAFDA --selftest                          # formatter + learning tests
.build/debug/YAFDA --transcribe audio.wav              # Apple engine
.build/debug/YAFDA --transcribe audio.wav --engine whisper
.build/debug/YAFDA --format "um hello new line hi"     # cleanup pipeline only
.build/debug/YAFDA --transform "fix this grammer pls"  # on-device LLM polish
```

## Privacy

Everything runs on this Mac: recognition (Apple SpeechAnalyzer or local
Whisper), cleanup, tone rewriting (Apple Intelligence), and the Voice
Profile analysis. Besides the one-time model downloads by macOS itself
(Apple speech assets) and, if you opt into the Whisper engine, the model
fetch from Hugging Face, the only other network request YAFDA makes is a
once-a-day anonymous GET to GitHub's API to check for a newer release - no
identifying payload, just the request itself. Turn it off in Settings if
you'd rather not; a manual "Check for Updates…" in the app menu still works
either way, since that's a request you asked for. Dictation data is stored
only in `~/Library/Application Support/YAFDA/` (migrated automatically from
the folder's earlier names on first launch).

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
