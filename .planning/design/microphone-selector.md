> **Historical document.** Written while the app was called Murmur; it was renamed to
> Mutter in July 2026. Names here are left as written on purpose — see
> `.planning/design/rename-to-mutter.md`.

# Microphone Selector - Design Document

**Status**: Draft
**Created**: 2026-07-21
**Upstream**: https://github.com/janisbelozerovs-dev/murmur (default branch `main`)

## Problem Statement

`AudioRecorder` records from `AVAudioEngine().inputNode` (`AudioRecorder.swift:32`), which
follows whatever macOS has set as the system default input. Murmur never says which
microphone it is using and offers no way to change it.

This is not cosmetic. On the machine this was found, the system default was a **Studio
Display XDR Microphone** - a far-field array roughly an arm's length away - while a
**Sennheiser Profile** close-mic condenser sat connected and idle. Dictation quality was
poor in a way that looked like a model problem: dropped leading words, and short
function-word runs mangled ("come out" heard as "command"). Two engines and a vocabulary
system were investigated before the input device was.

An app whose entire value is transcription accuracy should not silently record from an
arbitrary device.

## Requirements

### Functional
- List every input-capable audio device, by name.
- Let the user pick one, or explicitly choose "System default".
- Default to system default, preserving today's behaviour for anyone who never opens the
  setting.
- Show which device is actually in use, including when following the system default.
- If the chosen device is absent at record time (unplugged, powered off), fall back to
  the system default rather than failing to record, and say so.

### Non-Functional
- The preference must survive reboots and replugs. **Persist the device UID string, not
  the `AudioObjectID`** - IDs are ephemeral handles. Verified: the input node reported
  `deviceID 167` while the enumerated input devices were 93, 83, 109 and 113.
- No new third-party dependencies.
- Small enough to be an upstream PR against a repo we already have one open on.
- Tests extend the existing `runSelfTest() -> Bool` convention wired to `--selftest`.

## Architecture

### Components

**`AudioDevices`** (new, `Sources/Murmur/AudioDevices.swift`)

Pure CoreAudio enumeration and lookup. No AVFoundation, no UI.

- `struct AudioInputDevice: Identifiable, Equatable { let id: AudioObjectID; let uid: String; let name: String }`
- `static func inputDevices() -> [AudioInputDevice]` - every device with at least one
  input channel.
- `static func device(uid: String) -> AudioInputDevice?` - resolves a stored preference
  to a current handle, `nil` when absent.
- `static func systemDefaultInput() -> AudioInputDevice?` - for display.

A device counts as an input when its `kAudioDevicePropertyStreamConfiguration` on the
input scope reports any buffer with `mNumberChannels > 0`. Checking the name or the
transport type is not sufficient - output-only devices appear in the same list.

**`Settings.inputDeviceUID: String?`** (modify `AppDelegate.swift`)

`nil` means follow the system default. Stored under key `inputDeviceUID`.

**`AudioRecorder`** (modify `AudioRecorder.swift`)

Before starting the engine, if a UID is stored and resolves to a present device, set it
on the input unit:

```swift
try engine.inputNode.auAudioUnit.setDeviceID(device.id)
```

Verified working: pointing a live `AVAudioEngine` at device 109 succeeded and the unit
reported 109 afterwards.

Order matters - the device must be set **before** reading `outputFormat(forBus:)`
(`AudioRecorder.swift:33`), because the format belongs to the selected device. Setting it
afterwards would record at the wrong sample rate.

**Settings UI** (modify `MainView.swift`)

A picker listing "System default" plus each device, and a line naming the device actually
in use.

## Data Flow

Record → read `Settings.inputDeviceUID` → resolve via `AudioDevices.device(uid:)` →
if resolved, `setDeviceID` → read format → install tap → record.
Unresolved or unset → leave the input node alone, which follows the system default.

## Error Handling

| Condition | Behaviour |
|---|---|
| No UID stored | Follow the system default. Today's behaviour. |
| Stored UID not currently present | Fall back to system default, and surface it in the UI rather than failing silently - a user whose mic is unplugged should be told, not left wondering why quality dropped. |
| `setDeviceID` throws | Log, fall back to system default, still record. Never let device selection prevent capture. |
| No input devices at all | The picker shows only "System default"; recording behaves as today. |

## Testing Strategy

Extends `runSelfTest()`. CoreAudio enumeration is environment-dependent, so assert
contracts rather than specific hardware:

- Every returned device has a non-empty `uid` and `name`.
- UIDs are unique within the returned list.
- `device(uid:)` round-trips: every enumerated device resolves back to itself by UID.
- `device(uid:)` returns `nil` for a UID that does not exist.
- Enumeration is stable: two consecutive calls return the same UID set.
- Tolerate a machine with zero input devices - assert the contract holds vacuously
  rather than requiring hardware.

## Implementation Notes (Living Section)

_Empty - populated during implementation._

## Input level meter

**Added 2026-07-21.** Originally excluded to keep an upstream PR small; that constraint
went away when this became a fork, and "is this microphone actually hearing me" is the
question a picker alone cannot answer. Choosing the right device from a list is
guesswork if nothing confirms sound is arriving.

**`MicMonitor`** (new, `Sources/Murmur/MicMonitor.swift`) - a lightweight `AVAudioEngine`
that taps the selected input and publishes a smoothed level, writing nothing to disk.

- `@Published private(set) var level: Float` - 0...1, suitable for a bar.
- `func start(deviceUID: String?)` / `func stop()`.
- Level is RMS over each buffer, converted to dBFS and mapped from -60...0 dB onto 0...1,
  because linear RMS looks dead for normal speech.
- Smoothed with an asymmetric filter - fast attack, slow decay - so the bar tracks speech
  instead of flickering.

Runs only while the microphone settings view is on screen. Two engines must not tap the
same device at once, so **the monitor stops whenever dictation starts** and does not
restart until the settings view reappears.

## Open Questions / Deliberate Exclusions
- **No automatic switching** when a preferred device appears or disappears mid-session.
  Resolution happens per recording, which covers the realistic case without a device
  listener.
- **No per-app device preference.** Styles are per-app; microphones are not.
