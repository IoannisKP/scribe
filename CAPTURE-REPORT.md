# Bluetooth capture investigation and repair

Scope: the microphone-capture handoff dated 2026-08-14, plus two defects and two
UI problems found during the work. All hardware measurements were taken on the
affected Mac with the AirPods reported as `Quantum Pods Pro 3`, Core Audio input
device `131`, output device `125`.

Branch: `fix/bluetooth-microphone-capture`, pushed to `origin`.

---

## 1. What was wrong, in one paragraph

An AirPods input device whose only supported sample rate is 24 kHz reports a
complete, self-consistent 48 kHz format for roughly two to six seconds while
macOS switches it into headset mode. Two separate parts of the pipeline trusted
a rate read during that window. The microphone installed its tap against it and
silently captured nothing. The system track configured its resampler against a
related lie and wrote roughly half the samples it should. Neither failure
produced an error, and both WAV headers were correct, so every existing test and
every format-level check passed.

---

## 2. Session evidence

Durations derived from header rate and payload size.

| Session | Mic | System | Note |
| --- | --- | --- | --- |
| 2026-08-13 15.07 | 38.6s | 38.6s | last good |
| 2026-08-13 22.39 | 0.0s | 16.6s | empty microphone |
| 2026-08-13 22.41 | 0.0s | 2.7s | empty microphone |
| 2026-08-14 07.37 | 0.0s | 16.2s | empty microphone |
| 2026-08-14 08.21 | 48.2s | 26.7s | microphone fixed, system undersampled |
| 2026-08-14 08.53 | 70.9s | 73.1s | both fixed, system 9.8% short |

All six sessions carry a correct 16000 Hz, 16-bit header. The defects were never
header defects.

---

## 3. Defect A: microphone captured nothing

### Root cause

Measured with `MicrophoneRouteProbe`:

```
[3.362s] pre-tap inputNode.inputFormat = 48000 Hz   transient
[3.398s] installing tap with 48000 Hz
[4.890s] PROPERTY device nominal sample rate -> 24000 Hz   settles
[5.598s] engine.start() succeeded, isRunning true
[12.598s] RESULT callbacks 0, frames 0
```

The tap installs without error against the transient format. Once the route
settles the tap stops delivering, while `AVAudioEngine.isRunning` stays `true`.
No notification fires and no error is raised.

Two failure modes come from the same cause. If the settle lands before
`engine.start()`, start fails with `-10868`, which was the crash that commit
`8f22496` removed. If the settle lands after `engine.start()`, start succeeds
and the track is silently empty. That second mode is the reported bug.

### Why the handoff's suggested fix could not work

The handoff proposed waiting for route stability before installing the tap. That
was tried and abandoned on evidence: during the transient the device reports
nominal 48000 **and** `available [48000]`, so no static Core Audio property
distinguishes the transient state from a settled one. A fixed delay would have
to exceed the longest transition on any device and would still be a guess.

Launch-time prewarming of the microphone route, the pattern used for the system
tap, was also rejected. Binding an input device forces AirPods into headset
mode, so prewarming would degrade the user's music whenever Scribe is running.

### The fix

Evidence, not properties. The realtime sink adds every accepted frame to a
lock-free atomic counter. A watchdog polls it against `MicrophoneLivenessPolicy`
and rebuilds the input route when an installed tap delivers nothing past its
grace period, recording the rebuild as a `captureDeliveredNoAudio` route change.
Exhausting the rebuild budget fails the recording rather than retrying forever.

A working input delivers frames even in a silent room, because silence is still
samples. Absence of frames is therefore always a fault and never a quiet
speaker, which is why no signal-level heuristic is involved.

### Verification

Confirmed on hardware. To prove the watchdog itself rather than the pre-existing
configuration-change path, the run below had configuration-change recovery
temporarily disabled, reproducing the failing sessions' conditions. That patch
was reverted and is not in any commit.

```
[6.291s] state recording
[7.089s] state recovering: "Waiting for the microphone to start sending audio."
[7.343s] state recording          one rebuild, 254 ms gap
[20.247s] stopped: captured 309600 frames, dropped 0
          microphone.wav is 412822 bytes, against the 44-byte failure
```

Six probe runs, of which four exercised the transient. All four captured. The
watchdog fired and recovered in two of them. Runs that began already at 24000 Hz
did not exercise the transient and are not counted as passes.

---

## 4. Defect B: system track undersampled

### Root cause

The user's hypothesis about the mechanism was correct: a resampler configured
with a source rate higher than the hardware delivers decimates by too large a
factor. 48 kHz configured against 24 kHz delivered decimates 3:1 where it should
decimate 1.5:1, writing half the samples.

The source of the stale rate was not what either party first assumed. Measured:

```
[1.044s] tap 48000 | output 48000 | input 48000
[5.673s] device nominal sample rate -> 24000
[8.555s] tap 48000 | output 24000 | input 24000    tap still says 48000
         kAudioTapPropertyFormat listener: never fired
```

`kAudioTapPropertyFormat` reports 48000 permanently while the output device runs
at 24000, and its listener never fires. So the tap's advertised format is not
usable for configuring the resampler, and reading it at recording start instead
of at prewarm does not help, because the value is wrong at both moments.

The private aggregate clocks off the output subdevice, so the output device's
nominal sample rate is the rate the IOProc actually delivers at. That value did
change, 48000 to 24000, and is observable.

This matches 08.21 arithmetically. A post-switch loss factor of 2.0 puts the
onset at 5.2s, and the route change was recorded at 5s.

### The fix

Configure the resampler from the output device's nominal sample rate at start
and on recovery, and listen on `kAudioDevicePropertyNominalSampleRate`, the
property that demonstrably changes. The tap-format listener is retained, since a
genuine tap format change still warrants a rebuild.

### Verification

Confirmed in a real app recording, 08.53, measured on the shared sample timeline
rather than from file timestamps:

```
system spans [ 0.00, 73.11]s
mic    spans [10.14, 81.04]s
mic/sys duration ratio 0.9697        08.21 was 1.807
```

The 2x undersampling is gone. Playback speed is correct for both tracks.

---

## 5. Silent failure must not report success

The handoff's stated requirement, and the more serious of the two problems.

- The realtime watchdog surfaces a microphone fault **during** recording, not
  only at stop.
- `statusText` no longer claims both tracks are recording while the microphone
  service has failed.
- `AudioTrackCaptureResult` carries `capturedSampleCount`, and the dual-track
  coordinator fails a stop whose microphone track captured nothing. Both WAVs
  and the session metadata are finalized first, so the failure discards nothing
  that was captured.
- A silent **system** track remains a success. A meeting where the remote side
  never speaks is a valid recording, and a 44-byte `system.wav` is deliberate
  existing behaviour that was not changed.

The three empty-microphone sessions would now raise an error instead of
reporting success. This path is covered by tests, not by a device, because the
capture fix removes its trigger.

---

## 6. The coverage audit

Requested as a single assertion that would have caught both defects: written
sample count must account for the recording's duration, per track.

`CaptureCoverageAudit` expresses it once, used by tests and at runtime. It keeps
`.empty` distinct from `.undersampled` so the legitimate silent-system case
stays legal.

The strongest regression drives the real resampler and the real WAV writer:

```
testStaleSourceRateSilentlyWritesAShortTrack
  24 kHz hardware, 48 kHz configured
  header correct at 16000 Hz, ratio 0.5, verdict .undersampled
```

At runtime, both services now report canonical 16 kHz samples written, and the
coordinator audits each track against the recording's duration. A short track is
reported rather than thrown, because it still holds usable audio. The warning
reaches the status line.

Wiring this in exposed a bug in the earlier work: the microphone had been
reporting pre-resample input frames at 24k or 48k as `capturedSampleCount`,
which is not comparable to elapsed time. Auditing against it would have been
wrong.

---

## 7. Graph rebuild storm

The 08.53 session recovered correctly but still lost 7.93s of system audio,
9.8% of the session, landing exactly on the audit's 10% tolerance.

One physical event fires the nominal-rate, tap-format and aggregate-liveness
listeners together, and each rebuild re-registers all three on a fresh tap and
aggregate, so recoveries cascade. Every teardown drops the samples arriving while
the aggregate is recreated, and aggregate creation alone measures about 0.6s.

Recovery is now idempotent. A notification is ignored when the running graph
already matches the hardware: aggregate alive, default output device unchanged,
and delivered rate equal to the configured rate. Genuine changes still rebuild.

---

## 8. UI fixes

**Transparent circle while recording.** `glassEffect` defaults to a capsule. On
the tall sidebar recording control a capsule renders as a circular blob spilling
over the surrounding rows. Now shaped to a 12pt rounded rectangle. The wide
New recording pill keeps its capsule, where a capsule is correct.

**Per-track playback.** The transport button is now Play all. Each timeline lane
gains its own play button that auditions that track alone. The controller tracks
which single source is soloed, starts only the players that selection includes,
and reports playing state per mode so a track button does not light up during
Play all.

---

## 9. Commits

| Commit | Description |
| --- | --- |
| `8f6cbc7` | Recover microphone taps that deliver no audio |
| `abe3bba` | Register MicrophoneCaptureLiveness in the Xcode project |
| `b0de7b9` | Assert captured samples account for recording time |
| `2f43683` | Configure the system resampler from the output device rate |
| `74fbb30` | Stop rebuilding the system graph for changes already applied |
| `57639a0` | Shape the recording control's glass and split track playback |

25 files, 2159 insertions, 21 deletions.

`abe3bba` exists because the Xcode project lists `AudioCapture` sources
explicitly rather than synchronizing the folder, so a new file that SwiftPM
picks up by globbing is invisible to the framework target. Adding a source file
requires four separate pbxproj entries. Any future file addition needs the same
treatment plus an Xcode build to confirm it.

---

## 10. Verification status

Stated precisely, because this project has repeatedly found defects that passed
every automated test.

| Item | Status |
| --- | --- |
| Microphone transient and dead tap | Measured on hardware |
| Microphone watchdog recovery | Measured on hardware, twice, incl. an isolating run |
| Tap format does not track the headset switch | Measured on hardware |
| Output device rate does track it | Measured on hardware |
| System resampler fix end to end | Confirmed in app recording 08.53 |
| Zero-sample stop rule | Tests only; capture fix removes its trigger |
| Rebuild storm fix | Reasoned from the 7.93s gap and listener structure, not counted |
| UI: glass shape | Compiles; not visually inspected |
| UI: per-track playback | Compiles; not exercised by hand |

Gates at the final commit: 281 tests with 2 pre-existing skips and 0 failures,
arm64 SwiftPM Debug and Release both warning-free, Xcode `Scribe` scheme builds
with no compiler warnings.

---

## 11. Corrections made during the work

Recorded because each one changed the direction of the work.

1. **A settling delay cannot work.** Abandoned after measuring that the
   transient is self-consistent across every static property.
2. **Reading the tap format at recording start does not fix defect B.** This was
   committed as a partial fix, then measurement showed the tap format is wrong at
   both prewarm and start. It closes a different, real hole: launching on
   speakers and connecting a Bluetooth output before pressing Record.
3. **The "intermittent microphone" conclusion was confounded.** All three
   empty-microphone sessions predate the fix, and the app could not compile with
   it until 08:19:40. The underlying caution was still correct: one good session
   is not evidence of reliability.
4. **"Both arm64 builds pass" was narrower than it sounded.** It described
   `swift build` only. This project has two build systems and the Xcode build was
   not being checked.
5. **`capturedSampleCount` was counting the wrong thing.** Pre-resample input
   frames, not canonical samples. Found while wiring the audit.

---

## 12. Open items

1. **Microphone misses the first 10.14s** of the 08.53 recording. Timing shows
   this is dominated by slow AUHAL binding on a Bluetooth input, roughly four to
   five seconds, plus the settle. The watchdog contributed one to two seconds.
   Closing it means holding the session start until the microphone proves it is
   delivering, which delays system capture by the same amount, so it trades the
   user's own voice for the remote side's. This is a product decision and is
   deliberately unresolved.
2. **Rebuild storm fix needs a hardware run.** The next AirPods recording should
   bring the system track within a few percent of the microphone instead of 9.8%
   short. If it does not, the coverage warning now says so in the status line.
3. **No system-side route history.** `session.json` records
   `microphoneInputRouteChanges` but has no equivalent for the system graph, so
   rebuild counts are not directly observable. Adding one would have made item 2
   measurable rather than inferred.
4. **UI changes need review by eye**, particularly whether a 12pt corner radius
   sits correctly against the sidebar's other rows.

---

## 13. Salvageability of the affected recordings

Asked explicitly, answered by inspection rather than assumption.

- **22.39, 22.41, 07.37 microphone tracks:** unrecoverable. Zero samples exist.
  Nothing was written, so nothing can be reconstructed.
- **08.21 system track:** not a header repair. The discarded samples are gone.
  An attempt to localize the switch point by RMS and zero-crossing rate, so the
  affected span could be resampled, **failed**: source content variation swamps
  the 2x shift. Without a reliable boundary a targeted repair is not possible
  from the file alone.

Treat all four recordings as damaged, not intact.

---

## 14. Tooling added

`MicrophoneRouteProbe`, a SwiftPM executable alongside the existing
`ProviderEndpointProbe`. Every hardware measurement in this report came from it.

```bash
swift run MicrophoneRouteProbe                 # device inventory and tap timeline
swift run MicrophoneRouteProbe --service       # drive the real capture service
swift run MicrophoneRouteProbe --system-tap    # tap format across a route switch
swift run MicrophoneRouteProbe --settle-ms 1500
```

Run it from Terminal so the microphone TCC prompt is attributable.
