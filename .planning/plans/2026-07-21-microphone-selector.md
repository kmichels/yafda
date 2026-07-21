# Microphone Selector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user choose which microphone Murmur records from, see which one is actually in use, and confirm it is hearing them.

**Architecture:** `AudioDevices` enumerates CoreAudio input devices as pure data. `Settings.inputDeviceUID` stores a chosen device by its stable UID string. `AudioRecorder` resolves that UID and points the input unit at it before reading the audio format. `MicMonitor` runs a separate tap that publishes a live level so the picker is verifiable rather than hopeful.

**Tech Stack:** Swift 6.2 (language mode v5), SwiftPM, CoreAudio, AVFoundation, SwiftUI. No new dependencies.

**Spec:** `.planning/design/microphone-selector.md`

## Global Constraints

- Branch `local/main` (the fork's development line). This one may also be offered upstream later, so keep it self-contained.
- Persist the **device UID string**, never the `AudioObjectID` — IDs are ephemeral. Verified: the input node reported `deviceID 167` while enumerated input devices were 93, 83, 109, 113.
- `nil` UID means "follow the system default", which is today's behaviour and must remain the default.
- Device selection must never prevent recording. Any failure falls back to the system default and still captures.
- No new third-party dependencies.
- Tests extend the existing `runSelfTest() -> Bool` convention wired to `--selftest`.
- Build and test with: `swift build -c release && ./.build/release/Murmur --selftest`
- Baseline before this plan: **57 PASS / 0 FAIL**. The four `LearnedStore` `diff(...)` invariants must stay green throughout.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/Murmur/AudioDevices.swift` (create) | CoreAudio enumeration and UID lookup. Pure data, no AVFoundation, no UI. |
| `Sources/Murmur/MicMonitor.swift` (create) | Live input level for the settings view. |
| `Sources/Murmur/AudioRecorder.swift` (modify) | Point the input unit at the chosen device before reading its format. |
| `Sources/Murmur/AppDelegate.swift` (modify) | `Settings.inputDeviceUID`. |
| `Sources/Murmur/MainView.swift` (modify) | Picker, active-device line, level bar. |

---

### Task 1: Enumerate input devices

**Files:**
- Create: `Sources/Murmur/AudioDevices.swift`
- Modify: `Sources/Murmur/LearnedStore.swift` (self-test only)

**Interfaces:**
- Produces: `struct AudioInputDevice: Identifiable, Equatable { let id: AudioObjectID; let uid: String; let name: String }`; `AudioDevices.inputDevices() -> [AudioInputDevice]`; `AudioDevices.device(uid: String) -> AudioInputDevice?`; `AudioDevices.systemDefaultInput() -> AudioInputDevice?`

- [ ] **Step 1: Write the failing test**

Add to `LearnedStore.runSelfTest()`, immediately before `return passed`:

```swift
        // MARK: Audio device enumeration
        // CoreAudio results depend on what is plugged in, so assert contracts
        // rather than specific hardware. A machine with no inputs must pass too.
        let devices = AudioDevices.inputDevices()
        let wellFormed = devices.allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty }
        if !wellFormed { passed = false }
        print("\(wellFormed ? "PASS" : "FAIL"): \(devices.count) input device(s), " +
              "all with a uid and name")

        let uniqueUIDs = Set(devices.map(\.uid)).count == devices.count
        if !uniqueUIDs { passed = false }
        print("\(uniqueUIDs ? "PASS" : "FAIL"): device UIDs are unique")

        // The stored preference is a UID, so this round trip is the contract
        // that makes the setting survive a reboot or a replug.
        let roundTrips = devices.allSatisfy { AudioDevices.device(uid: $0.uid)?.uid == $0.uid }
        if !roundTrips { passed = false }
        print("\(roundTrips ? "PASS" : "FAIL"): every device resolves back by UID")

        let unknownIsNil = AudioDevices.device(uid: "no-such-device-uid") == nil
        if !unknownIsNil { passed = false }
        print("\(unknownIsNil ? "PASS" : "FAIL"): unknown UID resolves to nil")

        let stable = AudioDevices.inputDevices().map(\.uid) == devices.map(\.uid)
        if !stable { passed = false }
        print("\(stable ? "PASS" : "FAIL"): enumeration is stable across calls")
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build -c release 2>&1 | tail -5`
Expected: FAIL to compile — `cannot find 'AudioDevices' in scope`

- [ ] **Step 3: Write the implementation**

Create `Sources/Murmur/AudioDevices.swift`:

```swift
import CoreAudio
import Foundation

/// One audio device that can capture input.
struct AudioInputDevice: Identifiable, Equatable {
    /// Ephemeral CoreAudio handle. Valid for this launch only - never persist it.
    let id: AudioObjectID
    /// Stable across reboots and replugs. This is what gets stored.
    let uid: String
    let name: String
}

/// CoreAudio input device enumeration.
///
/// Murmur previously recorded from `AVAudioEngine`'s default input, which
/// follows the system setting with no indication of which device that is. On a
/// Mac with a display microphone and a desk microphone, that silently picked
/// the wrong one.
enum AudioDevices {
    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard hasInputChannels(id),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName),
                  !uid.isEmpty, !name.isEmpty
            else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    /// Resolves a stored preference to a device present right now.
    static func device(uid: String) -> AudioInputDevice? {
        inputDevices().first { $0.uid == uid }
    }

    /// The device the system would use, for display when following the default.
    static func systemDefaultInput() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr
        else { return nil }
        return inputDevices().first { $0.id == deviceID }
    }

    // MARK: - CoreAudio plumbing

    private static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr,
              size > 0
        else { return [] }
        var ids = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    /// A device is an input when its input-scope stream configuration reports at
    /// least one channel. Name and transport type are not reliable - output-only
    /// devices appear in the same device list.
    private static func hasInputChannels(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size > 0
        else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr
        else { return false }
        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        // Unmanaged, not CFString?: this property returns a +1 retained object,
        // and binding it straight to CFString? leaks it past ARC.
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift build -c release && ./.build/release/Murmur --selftest`
Expected: 62 PASS, 0 FAIL, exit 0 (57 + 5). The device count line should name a plausible number for this Mac (4 input devices were present during design). The four `diff(...)` invariants still PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Murmur/AudioDevices.swift Sources/Murmur/LearnedStore.swift
git commit -m "Enumerate CoreAudio input devices"
```

---

### Task 2: Record from the chosen device

**Files:**
- Modify: `Sources/Murmur/AppDelegate.swift` (Settings), `Sources/Murmur/AudioRecorder.swift`

**Interfaces:**
- Consumes: `AudioDevices.device(uid:)`
- Produces: `Settings.inputDeviceUID: String?`; `AudioRecorder.activeDeviceDescription: String`

- [ ] **Step 1: Write the failing test**

Add to `LearnedStore.runSelfTest()` before `return passed`:

```swift
        // MARK: Input device preference
        // Round-trip the setting without disturbing whatever is really stored.
        let savedUID = Settings.inputDeviceUID
        Settings.inputDeviceUID = nil
        let defaultsToSystem = Settings.inputDeviceUID == nil
        Settings.inputDeviceUID = "test-uid-12345"
        let storesUID = Settings.inputDeviceUID == "test-uid-12345"
        Settings.inputDeviceUID = savedUID
        let restored = Settings.inputDeviceUID == savedUID
        let settingOK = defaultsToSystem && storesUID && restored
        if !settingOK { passed = false }
        print("\(settingOK ? "PASS" : "FAIL"): inputDeviceUID stores, clears and restores")
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build -c release 2>&1 | tail -5`
Expected: FAIL to compile — `type 'Settings' has no member 'inputDeviceUID'`

- [ ] **Step 3: Write the implementation**

In `AppDelegate.swift`, add to `enum Settings` alongside the other properties:

```swift
    /// UID of the microphone to record from, or nil to follow the system
    /// default. A UID rather than an AudioObjectID because IDs are ephemeral
    /// handles that change between launches.
    static var inputDeviceUID: String? {
        get { defaults.string(forKey: "inputDeviceUID") }
        set { defaults.set(newValue, forKey: "inputDeviceUID") }
    }
```

In `AudioRecorder.swift`, select the device **before** reading the format. Replace the
opening of the recording setup (currently `AudioRecorder.swift:32-34`):

```swift
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
```

with:

```swift
        let input = engine.inputNode
        // Select the device BEFORE reading the format: the format belongs to
        // the selected device, so choosing afterwards would record at the
        // previous device's sample rate.
        activeDeviceDescription = Self.selectInputDevice(on: input)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
```

and add to `AudioRecorder`:

```swift
    /// Human-readable name of the device the last recording used, for the UI.
    private(set) var activeDeviceDescription = "System default"

    /// Points `input` at the user's chosen microphone when one is set and
    /// present. Falls back to the system default in every failure case -
    /// device selection must never stop a recording from happening.
    /// - Returns: a description of what was actually selected.
    private static func selectInputDevice(on input: AVAudioInputNode) -> String {
        guard let uid = Settings.inputDeviceUID else {
            return AudioDevices.systemDefaultInput().map { "\($0.name) (system default)" }
                ?? "System default"
        }
        guard let device = AudioDevices.device(uid: uid) else {
            return "Chosen microphone unavailable — using system default"
        }
        do {
            try input.auAudioUnit.setDeviceID(device.id)
            return device.name
        } catch {
            // Leaving the unit on a device that failed to select would record
            // from nothing. Put it back on the system default explicitly.
            if let fallback = AudioDevices.systemDefaultInput() {
                try? input.auAudioUnit.setDeviceID(fallback.id)
            }
            return "\(device.name) unavailable — using system default"
        }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift build -c release && ./.build/release/Murmur --selftest`
Expected: 63 PASS, 0 FAIL, exit 0.

Then confirm end to end that selection actually changes the capture device:

```bash
./scripts/make_app.sh && open build/Murmur.app
```
Dictate a sentence, then check the log for the selected device:
```bash
log show --last 2m --predicate 'process == "Murmur"' 2>/dev/null | tail -20
```
Expected: recording still works with no preference set (the default path is unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/Murmur/AppDelegate.swift Sources/Murmur/AudioRecorder.swift
git commit -m "Record from the user's chosen microphone"
```

---

### Task 3: Live input level

**Files:**
- Create: `Sources/Murmur/MicMonitor.swift`

**Interfaces:**
- Consumes: `AudioDevices.device(uid:)`
- Produces: `final class MicMonitor: ObservableObject` with `@Published private(set) var level: Float`, `func start(deviceUID: String?)`, `func stop()`, and `static func normalizedLevel(rms: Float) -> Float`

- [ ] **Step 1: Write the failing test**

Add to `LearnedStore.runSelfTest()` before `return passed`:

```swift
        // MARK: Level normalisation
        // Linear RMS reads near zero for ordinary speech, so the bar maps
        // -60...0 dBFS onto 0...1. These are the boundaries that matter.
        let levelCases: [(name: String, rms: Float, expected: Float)] = [
            ("silence clamps to 0", 0.0, 0.0),
            ("full scale clamps to 1", 1.0, 1.0),
            ("below floor clamps to 0", 0.0001, 0.0),
        ]
        for testCase in levelCases {
            let got = MicMonitor.normalizedLevel(rms: testCase.rms)
            let ok = abs(got - testCase.expected) < 0.001
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): level/\(testCase.name) = \(got)")
        }
        // Quiet speech must land in the visible middle, not pinned at either end.
        let speech = MicMonitor.normalizedLevel(rms: 0.03)   // about -30 dBFS
        let speechOK = speech > 0.3 && speech < 0.7
        if !speechOK { passed = false }
        print("\(speechOK ? "PASS" : "FAIL"): level/speech is mid-scale = \(speech)")
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build -c release 2>&1 | tail -5`
Expected: FAIL to compile — `cannot find 'MicMonitor' in scope`

- [ ] **Step 3: Write the implementation**

Create `Sources/Murmur/MicMonitor.swift`:

```swift
import Accelerate
import AVFoundation
import Foundation
import os

extension Notification.Name {
    /// Posted around dictation so the settings-view meter releases the device.
    /// Two AVAudioEngines must not tap the same microphone at once.
    static let murmurRecordingWillStart = Notification.Name("murmur.recordingWillStart")
    static let murmurRecordingDidStop = Notification.Name("murmur.recordingDidStop")
}

/// Live input level for the microphone settings view.
///
/// A picker alone cannot answer "is this microphone actually hearing me",
/// which is the question that matters when several are connected. This taps
/// the selected device and publishes a level, writing nothing to disk.
@MainActor
final class MicMonitor: ObservableObject {
    /// 0...1, suitable for a bar.
    @Published private(set) var level: Float = 0

    private let engine = AVAudioEngine()
    private var running = false
    private var suspended = false
    private var deviceUID: String?
    private var poll: Timer?
    private var observers: [NSObjectProtocol] = []

    /// Written on the audio render thread, read on the main thread.
    ///
    /// A lock rather than hopping to the main actor per buffer: spawning a
    /// Task inside the tap allocates on a real-time thread and invites
    /// priority inversion and dropouts.
    private let latestRMS = OSAllocatedUnfairLock(initialState: Float(0))

    /// dBFS window the bar spans. Speech sits near -30 dBFS, so a linear RMS
    /// scale would look dead.
    private static let floorDB: Float = -60

    static func normalizedLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        guard db > floorDB else { return 0 }
        return min(1, db / -floorDB + 1)
    }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .murmurRecordingWillStart, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspendForRecording() }
            })
        observers.append(center.addObserver(
            forName: .murmurRecordingDidStop, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeAfterRecording() }
            })
        // Unplugging the active microphone changes the engine's topology.
        // Without this the engine can fault while the settings view is open.
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    let uid = self.deviceUID
                    self.stop()
                    self.start(deviceUID: uid)
                }
            })
    }

    deinit {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
    }

    func start(deviceUID: String?) {
        self.deviceUID = deviceUID
        guard !running, !suspended else { return }
        let input = engine.inputNode
        if let deviceUID, let device = AudioDevices.device(uid: deviceUID) {
            try? input.auAudioUnit.setDeviceID(device.id)
        }
        let format = input.outputFormat(forBus: 0)
        // vDSP below reads one deinterleaved channel; bail rather than
        // misread an interleaved buffer as mono.
        guard format.sampleRate > 0, format.channelCount > 0, !format.isInterleaved
        else { return }

        let store = latestRMS
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            // Render thread: no allocation, no actor hops, no logging.
            guard let channel = buffer.floatChannelData?[0] else { return }
            let frames = vDSP_Length(buffer.frameLength)
            guard frames > 0 else { return }
            var rms: Float = 0
            vDSP_rmsqv(channel, 1, &rms, frames)
            store.withLock { $0 = rms }
        }
        do {
            try engine.start()
            running = true
            startPolling()
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        poll?.invalidate()
        poll = nil
        guard running else { level = 0; return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        level = 0
    }

    // MARK: - Recording coordination

    private func suspendForRecording() {
        suspended = true
        stop()
    }

    private func resumeAfterRecording() {
        suspended = false
        // Only resume if a view still wants a meter; `deviceUID` is set by start.
        if poll == nil, deviceUID != nil || Settings.inputDeviceUID != nil {
            start(deviceUID: deviceUID)
        }
    }

    /// Reads the shared value on a timer instead of pushing from the tap, so
    /// UI updates happen at a display-friendly rate rather than per buffer.
    private func startPolling() {
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let rms = self.latestRMS.withLock { $0 }
                let target = MicMonitor.normalizedLevel(rms: rms)
                // Fast attack, slow decay: track speech, do not flicker.
                self.level = target > self.level
                    ? target
                    : self.level * 0.85 + target * 0.15
            }
        }
    }
}
```

**`AudioRecorder` must post the notifications** so the meter yields the device. Post
`.murmurRecordingWillStart` immediately before `engine.start()` and
`.murmurRecordingDidStop` after the tap is removed in the stop path
(`AudioRecorder.swift:60`).

- [ ] **Step 4: Run to verify it passes**

Run: `swift build -c release && ./.build/release/Murmur --selftest`
Expected: 67 PASS, 0 FAIL, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/Murmur/MicMonitor.swift Sources/Murmur/LearnedStore.swift
git commit -m "Add a live input level monitor"
```

---

### Task 4: Microphone settings UI

**Files:**
- Modify: `Sources/Murmur/MainView.swift`

**Interfaces:**
- Consumes: `AudioDevices`, `Settings.inputDeviceUID`, `MicMonitor`

- [ ] **Step 1: Build the view**

There is no self-test for SwiftUI here; verification is Step 2, running the app. Add a
microphone card to the settings area, following the surrounding card style
(`Palette.card`, `RoundedRectangle(cornerRadius: 16)`, `.padding(20)`):

```swift
    @StateObject private var micMonitor = MicMonitor()
    // @AppStorage, not @State: a @State copy seeded from Settings silently
    // diverges if the preference changes anywhere else.
    @AppStorage("inputDeviceUID") private var inputDeviceUID: String?

    private var microphoneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Microphone").font(.headline)
            Text("Murmur records from the system default unless you choose a device.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Input", selection: $inputDeviceUID) {
                Text("System default").tag(String?.none)
                ForEach(AudioDevices.inputDevices()) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
            .labelsHidden()
            .onChange(of: inputDeviceUID) { _, newValue in
                // @AppStorage already persisted it; just re-point the meter.
                micMonitor.stop()
                micMonitor.start(deviceUID: newValue)
            }

            // The picker alone cannot tell you the device is working.
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(micMonitor.level))
                    .progressViewStyle(.linear)
                Text("Say something — the bar should move.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if inputDeviceUID != nil, AudioDevices.device(uid: inputDeviceUID!) == nil {
                Label("That microphone isn't connected. Using the system default.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        .onAppear { micMonitor.start(deviceUID: inputDeviceUID) }
        .onDisappear { micMonitor.stop() }
    }
```

Place `microphoneCard` in the settings page alongside the existing cards.

- [ ] **Step 2: Verify by running the app**

```bash
swift build -c release && ./.build/release/Murmur --selftest && ./scripts/make_app.sh && open build/Murmur.app
```

Check by hand, and report what you observe rather than assuming:
1. The picker lists the machine's input devices plus "System default".
2. Selecting **Sennheiser Profile** makes the level bar respond to speech.
3. Selecting **Studio Display XDR Microphone** also responds, at a visibly lower level for the same speaking distance — that difference is the whole point of the feature.
4. Dictation after switching records from the newly chosen device.
5. Quitting and relaunching preserves the selection.

- [ ] **Step 3: Confirm the monitor releases the device**

`MicMonitor` yields on `.murmurRecordingWillStart` and resumes on
`.murmurRecordingDidStop`, so verify that handshake actually fires rather than assuming:

1. Open the microphone settings so the meter is running and moving.
2. Without closing it, hold the dictation key and speak.
3. The dictation must transcribe normally — if it produces silence or fails, the monitor
   did not release the device.
4. After release, the meter should start moving again.

Two engines tapping one device is the failure this guards against, and it only appears
when the settings view happens to be open, which is exactly when a user is testing mics.

- [ ] **Step 4: Commit**

```bash
git add Sources/Murmur/MainView.swift
git commit -m "Add microphone picker with a live level meter"
```

---

### Task 5: Review

- [ ] **Step 1: Full suite**

```bash
swift build -c release && ./.build/release/Murmur --selftest; echo "exit=$?"
```
Expected: every line PASS, `exit=0`, including the four `diff(...)` invariants.

- [ ] **Step 2: Gemini panel review**

```bash
git diff main..HEAD -- Sources/ > /tmp/murmur-mic.diff
~/.claude/tools/review panel /tmp/murmur-mic.diff
```
Read `/tmp/murmur-mic.diff.panel-review.md`. Fix findings that are ours. Note that
`LearnedStore` architecture findings are now in scope for the fork, but out of scope for
*this* change — record them rather than acting on them here.

- [ ] **Step 3: Adversarial review**

Dispatch a reviewer over the same diff, focused on: CoreAudio memory handling in
`hasInputChannels` (a raw allocation with manual `deallocate`), whether `setDeviceID`
before `outputFormat` is genuinely the correct order, and whether the monitor can
deadlock or hold the device against the recorder.

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| List input-capable devices by name | 1 |
| Pick a device or "System default" | 2, 4 |
| Default to system default, preserving today's behaviour | 2 |
| Show which device is actually in use | 2 (`activeDeviceDescription`), 4 |
| Fall back when the chosen device is absent | 2, 4 (warning) |
| Persist by UID, not AudioObjectID | 2 (test asserts the round trip) |
| Level meter confirms the mic is live | 3, 4 |
| Monitor must not fight the recorder for the device | 3 (`stop()`), 4 step 3 |

**Review findings addressed (Gemini, round 1 — 0 Blocker, 2 High, 4 Medium, 3 Low):**

| Finding | Resolution |
|---|---|
| **High: spawning a `Task { @MainActor }` per buffer inside the audio tap violates real-time constraints** | Adopted. The tap now writes RMS into an `OSAllocatedUnfairLock` and a 30 Hz timer reads it on the main actor. No allocation and no actor hop on the render thread. |
| **High: monitor and recorder can fight over the same device** | Adopted, with a mechanism rather than a warning. `AudioRecorder` posts `.murmurRecordingWillStart` / `.murmurRecordingDidStop`; `MicMonitor` suspends and resumes on those. Task 4 step 3 now verifies the handshake by hand. |
| Medium: `stringProperty` leaks a +1 retained `CFString` | Adopted — `Unmanaged<CFString>?` plus `takeRetainedValue()`. |
| Medium: `@State` seeded from `Settings` diverges from the stored preference | Adopted — `@AppStorage("inputDeviceUID")`, which also removes the manual write-back. |
| Medium: a failed `setDeviceID` leaves the unit pointing at a device that did not select | Adopted — the catch resets to the system default before returning. |
| Medium: unplugging the active mic while monitoring can fault the engine | Adopted — an `.AVAudioEngineConfigurationChange` observer restarts the monitor. |
| Low: manual RMS loop is heavy for a render thread | Adopted — `vDSP_rmsqv` from Accelerate, a system framework, so no new dependency. |
| Low: `floatChannelData?[0]` assumes deinterleaved audio | Adopted — the monitor refuses to start on an interleaved format rather than misreading it. |
| Low: `installTap` buffer size is a suggestion | No change needed; the code already uses `buffer.frameLength` rather than assuming 1024. |

**Known gaps, deliberate:**
- No device-change listener; a device appearing or disappearing mid-session is picked up on the next recording or when the settings view is reopened.
- The level meter runs only while its view is visible, so it costs nothing during normal dictation.
- SwiftUI has no self-test coverage — Task 4 is verified by hand, which is why its steps say what to look for rather than asserting success.
