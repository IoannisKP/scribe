# Post-acceptance report 02

**Scope:** Work items 1–10 plus Milestone 4 checkpoints 1–9
**Baseline:** Milestones 1–3 accepted; commit `e645a24`  
**Result:** Items 1–10 are committed green; Item 11 is green through checkpoint 9.
**Dependency invariant:** FluidAudio remains pinned exactly to `0.15.5`.

## Item 1 — FluidAudio streaming evaluation

**Changed:** Added `FLUIDAUDIO-STREAMING-EVALUATION.md` (`1a48351`). The pinned
release already contains the 160/320/1280 ms EOU API, so no upgrade is needed.
Recommended an optional future English low-latency preview, while retaining TDT
v3/Silero for multilingual and punctuation-preserving output. Estimated a future
pin migration at 23–42 hours and EOU integration at another 32–52 hours. An
EOU-only design could delete 1,821–1,961 production lines, but those lines remain
needed by multilingual TDT and future window-based engines.

**Tested:** Inspected the exact checked-out `0.15.5` API and upstream model/release
documentation. The unchanged full suite and arm64 Debug/Release builds passed.

**Unverified:** No EOU model was downloaded or run; meeting latency, WER,
end-of-utterance behavior, punctuation impact, and future upgrade effort remain
unmeasured in Scribe.

## Item 2 — Default committed golden fixture

**Changed:** Committed a 19.6-second Samantha `say` fixture and reference text;
the ordinary suite now runs it when local Parakeet v3 exists and otherwise names
the missing model/path (`a8d8ff9`). The caller-supplied real-recording fixture
remains opt-in.

**Tested:** Real local Parakeet v3 inference ran in the ordinary suite. Final
measured synthetic WER was **0.0196** against a 0.20 ceiling. Full suite and both
app builds passed.

**Unverified:** Synthetic speech has no room noise, cross-talk, disfluency,
accent variation, or microphone chain. This is a regression guard, not a
real-world accuracy benchmark. The optional real fixture was not supplied.

## Item 3 — Engine-owned window geometry

**Changed:** Added `preferredWindowDuration` and `preferredOverlap` to
`TranscriptionEngine`; Parakeet declares 14 seconds and 1.5 seconds. Batch and
live paths now consume engine values (`24e3c12`).

**Tested:** Mock engines with non-Parakeet geometry drive batch and live
chunking tests. Full suite and both builds passed.

**Unverified:** No non-Parakeet production adapter has yet exercised the contract.

## Item 4 — Batch seam word preservation

**Changed:** Batch reads overlap by the engine amount and reuse the source-aware
`TranscriptOverlapDeduplicator` before timeline merge (`117740d`).

**Tested:** A real Parakeet regression places the golden boundary inside
“transcription” at 9.640 seconds. It retained at least the one-window word count,
deduplicated the overlap, and passed at WER **0.1765**. Mock seam tests, the full
suite, and both builds passed.

**Unverified:** The originally reported real meeting seam was not reprocessed or
modified; its recordings were deliberately left untouched.

## Item 5 — Utterance-level timestamps

**Changed:** Timed segments now start at their first mapped word and end at their
last; backend duration remains only the no-word fallback (`8b286e4`).

**Tested:** Adapter tests distinguish word bounds from chunk bounds and cover the
fallback. Full suite and both builds passed.

**Unverified:** Human review of timestamp usefulness in a long, overlapping real
meeting remains outstanding.

## Item 6 — System render gaps

**Changed:** Core Audio buffers with nil data but reported bytes now contribute
zero samples, preserving linear sample time. A genuinely empty/header-only
system track remains valid (`b89d07d`).

**Tested:** C/Swift mixer tests preserve a deliberate 30-second system gap and
align post-gap timestamps with microphone time; silent-system batch processing
also passes. Full suite and both builds passed.

**Unverified:** Actual Core Audio devices/process taps must confirm that macOS
reports retained byte counts for every relevant no-render condition.

## Item 7 — Stable equal-time speaker ordering

**Changed:** Shared batch/live ordering is absolute start, then microphone
(You), system (Others), end, and text. Manifest offsets are applied first
(`faa34d2`).

**Tested:** Equal starts, positive system offsets, different utterance lengths,
and batch/live ordering are deterministic in tests. Full suite and both builds
passed.

**Unverified:** Real device startup-offset distribution and UI perception under
simultaneous speech require target-hardware observation.

## Item 8 — Observed-component status messages

**Changed:** Unavailable live state now records whether Silero or Parakeet is
missing; wording is centralized (`17b3cd1`). The audit also fixed raw transport
buffering being called an ASR backlog and idle batch status claiming readiness
without a recording/model.

**Tested:** Formatter tests cover every transport, VAD, ASR, batch, and missing-
component branch. Full suite and both builds passed.

**Unverified:** Human comprehension and accessibility of the messages in the
running app have not been usability-tested.

## Item 9 — Durable Int16 session audio

**Changed:** Capture/inference/live audio remains Float32; new sessions stream
durable 16 kHz mono Int16 PCM WAVs (`895967f`). Readers accept both Int16 and
legacy Float32, so no existing session needs conversion or mutation. Implemented
now—not deferred to retention work—because it immediately halves retained audio
without changing realtime code.

**Tested:** Header, quantization, clamping, payload-size, Int16 read conversion,
legacy Float32 reads, header-only audio, and batch paths pass. Golden WER is
**0.0196** for both legacy Float32 and its durable Int16 copy. Full suite and
both builds passed.

**Unverified:** Long real capture/playback in third-party audio tools and noisy
meeting accuracy after quantization need human acceptance.

## Item 10 — Recording disk floor

**Changed:** Added an injected free-space provider, configurable expected
duration/reserve/poll interval, preflight before either track starts, and clean
automatic two-track stop (`493c38f`). Defaults are two hours, 512 MiB reserve,
and five-second checks. The conservative 320,000 B/s budget includes both Int16
WAVs and worst-case raw/speech Float32 spools: about 1.15 GB/hour; retained WAVs
alone are about 230 MB/hour. Source `.build` and Xcode DerivedData caches may
also grow, but models/sessions are outside the checkout.

**Tested:** Injected-capacity tests verify exact estimates, overflow capping,
refusal before either service starts, threshold detection, both finalizers, and
the stopped reason. Final full suite: **87 tests passed, 1 intentional opt-in
skip, 0 failures**. Final quiet arm64 Debug and Release builds passed.

**Unverified:** No real disk was filled. APFS capacity reporting, simultaneous
external disk pressure, actual five-second polling, user notification, and WAV
playability after a real low-space stop need target-hardware acceptance.

## Item 11 — Milestone 4, checkpoints 1–9
**Changed:** Added the general catalogue, canonical model paths, managed staged
downloads with pause/resume/cancel and SHA-256 verification, measured disk/RAM
safety, shared FluidAudio registry, exact WhisperKit 1.0.0 pin, an explicit
offline Whisper adapter, a single-resident coordinator, and unified model UI
with safety/storage facts, lifecycle controls, deletion, and explicit fallback.
**Tested:** Full suite: **131 tests, 1 intentional skip, 0 failures**; quiet
arm64 Debug/Release builds passed. The M4 Pro fixture measurements use logical
installed bytes and conservative first-load process peak RSS:
| Catalogue model | WER | Disk bytes | Peak RSS bytes |
|---|---:|---:|---:|
| Tiny | 0.0588 | 79,398,546 | 229,294,080 |
| Tiny English | 0.0000 | 155,399,288 | 302,841,856 |
| Base | 0.0392 | 149,482,602 | 344,489,984 |
| Small | 0.0000 | 489,250,614 | 895,385,600 |
| Medium | 0.0000 | 1,532,417,382 | 2,553,430,016 |
| Large v3 | 0.0000 | 3,093,083,359 | 4,440,883,200 |
| Large v3 Turbo | 0.0000 | 1,622,294,723 | 3,020,783,616 |
| Distil Large v3 | 0.0392 | 1,517,298,160 | 2,907,111,424 |
| Turbo 4-bit | 0.0000 | 629,481,698 | 1,173,094,400 |
| Turbo optimized 4-bit | 0.0000 | 648,432,373 | 1,477,410,816 |
| Large v3 optimized compressed | 0.0000 | 1,055,612,340 | 1,828,929,536 |
| Distil optimized compressed | 0.0392 | 609,877,791 | 1,376,993,280 |
**Unverified/remaining:** This fixture is synthetic. Checkpoint 10 remains: mock
and real end-to-end switching/comparison verification, including UI acceptance.

## Requires human acceptance on target hardware
- Prototype EOU separately before claiming subsecond latency, acceptable EOU,
  punctuation quality, two-source isolation, or meeting-room WER.
- Run the optional real-audio golden fixture across accents, noise, overlap,
  disfluency, microphones, Swedish, Greek, and English; synthetic WER is not
  evidence for those conditions.
- Re-transcribe a disposable copy of a real meeting with speech crossing a
  batch seam and listen for both omissions and duplicated words.
- Inspect word-derived timestamps and equal-time You/Others ordering in long,
  overlapping real conversations.
- Record real system-audio render gaps across speakers, headphones, output
  changes, sleep/wake, and silent remote participants; confirm post-gap linear
  timing and valid header-only tracks.
- Exercise every unavailable/backpressure state in the app with VoiceOver and
  confirm the wording names the component users actually need to act on.
- Make a long two-source recording, verify both Int16 WAVs in independent audio
  tools, compare against a legacy Float32 session, and judge audible/ASR parity.
- On a disposable volume, reduce free space during capture (including external
  writers), confirm preflight thresholds and automatic stop timing, play both
  finalized WAVs, and confirm live-spool cleanup and understandable UI status.
- Confirm source checkout, DerivedData, models, transient spools, and retained
  sessions grow as documented during repeated real builds and meetings.
- Compare all supported Whisper variants on noisy, accented, overlapping real
  meetings and judge word timing, quality, latency, thermals, and memory pressure.
