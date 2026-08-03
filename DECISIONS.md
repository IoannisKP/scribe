# Technical decisions

## 2026-07-29 — Native Xcode project plus local Swift package

**Decision:** Keep an Xcode workspace and native application/framework targets,
while also exposing `AudioCapture` through a local `Package.swift` manifest for
isolated tests.

**Alternatives:** Generate the project with XcodeGen or Tuist; use only a Swift
package executable; manually add a local package product to the app project.

**Reasoning:** A native app target produces the correct macOS bundle and signing
configuration. The package manifest provides fast module tests. A project
generator would add an unapproved dependency, while a package executable is not
an adequate replacement for a macOS application target.

## 2026-07-29 — Add modules only with working behavior

**Decision:** Create `AudioCapture` in Milestone 1A and add the remaining module
targets during the milestones that first implement them.

**Alternatives:** Create empty targets for the entire final module graph.

**Reasoning:** Empty targets would be placeholders without testable behavior.
Incremental creation keeps every target meaningful while preserving the final
architecture.

## 2026-07-29 — C17 atomics for the realtime FIFO

**Decision:** Implement sample storage and atomic indices in a minimal C target,
wrapped by a small Swift API.

**Alternatives:** Add Swift Atomics; use `NSLock` or `OSAllocatedUnfairLock`;
write an unsynchronized Swift ring; rely on a newer OS-only synchronization
module.

**Reasoning:** No unapproved dependency is needed, the macOS 14.4 deployment
target is preserved, and the audio callback remains free of locks and
allocations. C11/C17 atomics provide the release/acquire semantics required by a
single-producer, single-consumer queue.

## 2026-07-29 — Backpressure starts at the ring boundary

**Decision:** A full ring accepts only the samples that fit and returns the
written count. It never overwrites unread samples.

**Alternatives:** Overwrite oldest samples; dynamically grow the buffer; block
the producer.

**Reasoning:** Growing or blocking is invalid on a realtime audio thread.
Returning a short write makes loss measurable so the session coordinator can
surface an overrun and apply later backpressure policy.

## 2026-07-29 — Stateful AVAudioConverter wrapper

**Decision:** Give each source's serial consumer one `AudioResampler` that
preserves `AVAudioConverter` state across input blocks.

**Alternatives:** Recreate or reset the converter per callback; implement a
custom sample-rate conversion filter.

**Reasoning:** Converter continuity avoids block-boundary artifacts, while
Apple's converter supplies production-quality rate conversion. Allocation and
conversion happen after the realtime ring, never inside capture callbacks.

## 2026-07-29 — Synchronize WAV headers after every append

**Decision:** Rewrite and synchronize RIFF sizes after each writer append.

**Alternatives:** Write lengths only at orderly shutdown; periodically
checkpoint; use a custom container and convert after recording.

**Reasoning:** The straightforward implementation favors recoverability. The
cost is acceptable on the non-realtime writer actor and can be measured before
considering a less frequent checkpoint interval.

## 2026-07-29 — Mix microphone channels inside the C realtime primitive

**Decision:** Add a planar-channel mix operation to the C17 ring implementation.
It averages channels, clamps the result, and writes directly into available ring
slots.

**Alternatives:** Allocate an intermediate mono buffer per callback; keep a
mutable Swift scratch array; ask `AVAudioEngine` to negotiate a mono tap format.

**Reasoning:** Hardware input can expose multiple channels and format
negotiation varies by device. Direct C mixdown has deterministic storage
behavior and keeps allocation, copy-on-write checks, and resampling outside the
audio callback.

## 2026-07-29 — Poll the ring from one high-priority consumer

**Decision:** A detached high-priority task checks the ring every five
milliseconds when idle and sends batches through one actor-isolated converter
and writer.

**Alternatives:** Signal the consumer from the realtime callback; use an
`AsyncStream`; write or resample in the callback.

**Reasoning:** Locks, continuations, stream yields, and dispatch operations can
allocate or contend. Short polling keeps the producer callback limited to
atomic ring operations. The ten-second ring absorbs ordinary scheduling jitter,
and overruns remain measurable.

## 2026-07-29 — Preserve one WAV across microphone route changes

**Decision:** On engine configuration changes or wake, stop the tap, drain old
samples, replace the resampler for the new input rate, and restart capture into
the same canonical WAV.

**Alternatives:** End the recording; silently discard buffered samples; keep the
old converter after a hardware-rate change.

**Reasoning:** The output contract remains 16 kHz mono regardless of hardware
rate. Draining before replacing the converter preserves ordering and prevents
old-rate samples from being interpreted at the new rate. Recovery failures are
surfaced and the valid portion of the WAV is finalized.

## 2026-07-29 — Represent the process tap as an AudioSubTap dictionary

**Decision:** Put a dictionary containing `kAudioSubTapUIDKey` and drift
compensation in `kAudioAggregateDeviceTapListKey`.

**Alternatives:** Put the tap UUID string directly in the tap list.

**Reasoning:** The brief uses “tap UID in the tap list” as shorthand, but the
current Core Audio header defines that list as an array of dictionaries
describing AudioSubTap objects. Encoding the dictionary matches the SDK
contract and makes drift compensation explicit.

## 2026-07-29 — Use a physical output device as aggregate clock source

**Decision:** Include the current default output device as a real subdevice and
main subdevice, while overriding its aggregate input-channel contribution to
zero.

**Alternatives:** Create a tap-only aggregate; allow input streams from a
combined input/output device into the callback.

**Reasoning:** The physical output provides the required real clock and route.
Suppressing its input channels ensures the IOProc input consists only of the
process tap, even when headphones or an interface expose microphone streams on
the same device.

## 2026-07-29 — Direct nil-queue aggregate IOProc

**Decision:** Register `AudioDeviceCreateIOProcIDWithBlock` with a `nil`
dispatch queue and feed the callback's `AudioBufferList` directly to the C17
ring mixer.

**Alternatives:** Retarget `AVAudioEngine`; supply a dispatch queue; construct
`AVAudioPCMBuffer` objects in the callback.

**Reasoning:** The SDK specifies that a nil queue invokes the block directly.
This avoids the known `AVAudioEngine` aggregate-device trap and keeps the
realtime callback free of allocation, locks, logging, conversion, and disk I/O.

## 2026-07-29 — Start microphone before the global process tap

**Decision:** The dual coordinator starts microphone capture first and system
capture second.

**Alternatives:** Start in the opposite order or concurrently.

**Reasoning:** The process tap excludes Scribe by its Core Audio process object.
Starting the microphone ensures that process object exists before the tap is
created. Sequential startup also makes partial-failure cleanup deterministic.

## 2026-07-29 — Probe system-audio permission with a disposable process tap

**Decision:** Treat system-audio authorization as a last-observed state. On an
explicit first-run button press, start an all-process tap graph briefly, discard
its ring contents, and tear it down without creating a WAV.

**Alternatives:** Claim an exact preflight state; inspect the TCC database; call
private TCC framework symbols; wait until the first real recording to explain
the permission.

**Reasoning:** Unlike microphone capture, Core Audio process taps expose no
public authorization-status or request API. Apple's contract says the system
prompts when recording starts from an aggregate that contains a tap. The
disposable graph exercises that public path without retaining audio. Persisting
only the observed result makes the UI useful across launches without
misrepresenting it as a live TCC query.

## 2026-07-29 — Deep-link to the audio-only privacy route

**Decision:** Use the `Privacy_AudioCapture` System Settings route for system
audio and `Privacy_Microphone` for microphone access.

**Alternatives:** Link system audio to `Privacy_ScreenCapture`; open only the
top-level Privacy & Security pane.

**Reasoning:** The installed macOS privacy extension defines separate
AudioCapture and ScreenCapture routes. Scribe uses a process tap and requests
only system audio, so the audio-only route is the narrow, accurate destination.

## 2026-07-30 — Persist monotonic per-track offsets beside the WAV files

**Decision:** Write a small versioned `capture-session.json` containing the
microphone and system WAV paths plus each track's offset from a shared
`ContinuousClock` origin. Measure the offset between the successful completion
of microphone and system activation.

**Alternatives:** Treat both WAV files as starting at zero; use wall-clock
dates; add a database before the Persistence milestone; pad one file with
estimated silence.

**Reasoning:** Sequential startup is required for reliable self-exclusion, so
assuming both sources start together would misorder early transcript results.
A monotonic offset is immune to wall-clock adjustments and keeps the recording
self-describing without prematurely introducing the database layer. If the
manifest cannot be written, both capture services are stopped and finalized.

## 2026-07-30 — Bound batch input to 14-second canonical chunks

**Decision:** Read each WAV through an actor-owned `AVAudioFile` and allocate at
most 14 seconds of Float32 samples per chunk by default.

**Alternatives:** Load both complete WAVs into arrays; make the engine protocol
file-URL-specific; implement VAD and overlapping windows during batch
foundation work.

**Reasoning:** The approved engine protocol accepts sample arrays, but a
one-hour two-track meeting should not require both full recordings in memory.
Fourteen seconds fits the intended Parakeet batch window. VAD, overlap, and
de-duplication remain a separate Milestone 3 concern.

## 2026-07-30 — Make engine cleanup a batch-pipeline invariant

**Decision:** `BatchTranscriptionPipeline` calls `unload()` after success,
preparation failure, transcription failure, validation failure, or
`finish()` failure.

**Alternatives:** Let each caller manage model lifetime; unload only after
successful transcription.

**Reasoning:** Large Core ML models must not remain resident after a failed
session. Central lifecycle ownership is deterministic and mock-testable, while
the engine abstraction remains independent of UI and model implementation.

## 2026-07-30 — Pin FluidAudio exactly at 0.15.5

**Decision:** Use FluidAudio `0.15.5` with an exact Swift Package Manager
requirement in both the package manifest and Xcode project.

**Alternatives:** Track a branch; use a compatible minor-version range; copy
FluidAudio source into the project; implement Parakeet Core ML orchestration
directly.

**Reasoning:** FluidAudio is an approved dependency and supplies the tested
Parakeet model registry, compilation, TDT decoder, token timing, and Apple
Silicon Core ML path. An exact pin protects the strict-concurrency build and
offline contract from an unreviewed package update.

## 2026-07-30 — Separate explicit acquisition from offline preparation

**Decision:** Give model download and inference different entry points.
`ParakeetModelStore.download` is the only operation that permits network
access. `ParakeetTranscriptionEngine.prepare` requires a complete cache,
enables FluidAudio offline mode, and only then loads models.

**Alternatives:** Call FluidAudio's combined `downloadAndLoad` from
`prepare()`; automatically download the selected model on first transcription;
ship models inside the application bundle.

**Reasoning:** Combined loading can make a missing or damaged artifact trigger
network access at an unexpected time. A separate Download Model action makes
the one network operation visible, keeps recording and transcription
independently usable offline, and produces an actionable missing-model state.
Bundling both 0.6B models would make the application impractically large.

## 2026-07-30 — Map one Parakeet result per fixed batch chunk

**Decision:** Aggregate FluidAudio token timings into words, shift their
chunk-local times onto the capture-session timeline, and emit one nonempty
segment per 14-second chunk.

**Alternatives:** Infer sentence boundaries from punctuation now; discard word
timings; expose FluidAudio result types directly; implement overlapping
VAD-aware segments during batch work.

**Reasoning:** The mapping preserves precise source and word timing without
coupling the public engine contract to FluidAudio. Punctuation-only splitting
would be unreliable across 25 languages. Fixed batch segments meet Milestone 2
and keep VAD, overlap, and seam de-duplication scoped to Milestone 3.

## 2026-07-30 — Commit canonical audio before live fan-out

**Decision:** Emit each source-indexed `CanonicalAudioBlock` only after the
matching samples have been appended and synchronized in its WAV.

**Alternatives:** Fan out directly from the realtime callback; send the block
before WAV persistence; make live-pipeline success a requirement for recording.

**Reasoning:** The realtime callbacks keep their existing allocation-free,
lock-free contract. WAV-first ordering makes the durable track authoritative
and ensures a failed live stage cannot corrupt or abort an otherwise valid
recording.

## 2026-07-30 — Use per-source append-only files for live backpressure

**Decision:** Give the shared `LiveAudioTransport` actor one sequential spool
file per source, with source-relative sample indices and hysteretic backlog
states. Retain only counters and the block currently crossing the actor.

**Alternatives:** Grow an in-memory array or `AsyncStream` buffer; discard old
speech; block the realtime producer; switch models before a VAD/ASR consumer
exists.

**Reasoning:** Disk capacity, rather than RAM, absorbs ASR stalls without
dropping captured speech. Separate files preserve source ordering for per-source
VAD. A ten-second high threshold and two-second recovery threshold avoid UI
state flapping. Milestone 3C later chose to preserve the explicitly selected
model rather than use silent fallback; disk spooling provides the safe behavior
independently of a particular engine.

## 2026-07-30 — Keep the Milestone 3A spool transient

**Decision:** Remove `LiveSpool` on orderly stop or failed startup while keeping
the synchronized WAV files as the recording of record.

**Alternatives:** Persist both formats indefinitely; treat the live spool as
crash-recovery storage; delete the spool only on next launch.

**Reasoning:** Before VAD and live ASR consume these records, retaining a second
complete audio copy would waste disk and complicate data retention. The
recoverable WAV already owns durability. Later submilestones can evolve spool
recovery atomically if finalized live transcript segments require it.

## 2026-07-30 — Separate Silero acquisition from offline VAD loading

**Decision:** Install Silero only from an explicit **Download Live VAD**
action. During recording, require the compiled local bundle, enable FluidAudio
offline mode, load it manually with `MLModel`, and inject it into
`VadManager`.

**Alternatives:** Use FluidAudio's convenience VAD initializer; download
automatically when recording begins; bundle the model in the application.

**Reasoning:** The convenience path can acquire a missing model. Manual loading
keeps the recording path offline and makes missing-model behavior predictable.
Recording remains useful without VAD because the independently synchronized
WAV files continue as the source of truth.

## 2026-07-30 — Use independent recurrent VAD state and hard segmentation limits

**Decision:** Give microphone and system audio separate Silero recurrent state,
apply 0.85/0.70 entry/exit hysteresis, and finalize continuous speech at an
exact 30-second sample boundary.

**Alternatives:** Share detector state across tracks; use a single probability
threshold; wait indefinitely for silence; concatenate both sources before VAD.

**Reasoning:** Shared state would leak one source's acoustic history into the
other. Hysteresis avoids boundary flapping, while a sample-count ceiling
guarantees bounded inference units during uninterrupted speech.

## 2026-07-30 — Spool overlapping speech windows and de-duplicate by source

**Decision:** Emit 14-second windows stepped by 12.5 seconds, serialize them
per source, and remove the longest matching transcript seam only between
timeline-adjacent results from that same source.

**Alternatives:** Keep windows in an unbounded array; omit overlap; compare
across sources; remove a fixed number of words.

**Reasoning:** A 1.5-second overlap protects words at model boundaries.
Disk-backed output preserves bounded memory until live ASR catches up.
Source-aware longest-boundary matching removes repeated text without merging
independent speakers or assuming a fixed speech rate.

## 2026-07-30 — Represent live text as replaceable segment rows

**Decision:** Use one stable row identity per source and VAD speech-segment
index. Overlapping nonfinal windows extend that row, and its final window
replaces the row with a finalized value.

**Alternatives:** Append every window result; mutate arbitrary SwiftUI array
indices; wait for all speech to finish before showing any text.

**Reasoning:** Stable identity gives SwiftUI a small deterministic update,
makes the partial-to-final transition visible, and prevents overlap windows
from appearing as duplicate rows. The source plus segment index remains unique
without introducing persistence identifiers before Milestone 5.

## 2026-07-30 — Buffer live ASR lag to disk without silent model fallback

**Decision:** Consume the selected Parakeet model for the entire session. When
three or more VAD windows are pending, expose **buffering to disk**, then
**catching up** until one remains.

**Alternatives:** Grow an in-memory queue; drop speech; automatically replace
the selected model with Parakeet v2; block audio capture.

**Reasoning:** The existing per-source window spool already provides bounded
memory and preserves every speech sample. Silently changing models would alter
language support and accuracy, contradicting explicit model selection.
Recording remains authoritative and continues independently if live ASR fails.

## 2026-07-30 — Gate append-only spool reads with pending counts

**Decision:** Track complete pending records per source inside each transport
actor and call the corresponding file reader only when that count is nonzero.
Treat a missing record after a positive count as malformed storage.

**Alternatives:** Repeatedly probe an empty append-only `FileHandle`; reopen or
seek the file on every poll; delay consumer startup until capture has produced
data.

**Reasoning:** Production consumers start before the first capture block and
poll concurrently with writers. Avoiding empty reads prevents a reader from
remaining at a stale end-of-file position, while the actor-owned count provides
a deterministic availability check without extra filesystem work.

## 2026-08-01 — Evaluate EOU as an optional live capability, not a replacement

**Decision:** Keep FluidAudio pinned to `0.15.5` and retain the existing
Silero/window/TDT path. Treat Parakeet Realtime EOU as a possible future
English-only low-latency live-preview capability behind a refined streaming
engine protocol.

**Alternatives:** Upgrade FluidAudio before evaluation; replace Milestone 3B
globally; force the cache-aware streaming model through the existing bounded
request/response method; reject streaming entirely.

**Reasoning:** The pinned release already contains the EOU streaming API, so an
upgrade adds no capability today. EOU can reduce partial latency and eliminate
Silero/window segmentation for its own path, but it supports only English and
does not emit punctuation or capitalization. TDT v3 remains necessary for the
required multilingual coverage and higher-quality durable transcript text.
Whisper and other window-based engines also continue to need a segmentation and
backpressure path.

## 2026-08-01 — Commit a synthetic ASR regression fixture

**Decision:** Commit a 19.6-second Samantha-voice fixture generated by macOS
`say`, converted to canonical 16 kHz mono Float32 WAV, together with its source
text. Run it in the ordinary suite whenever the chosen Parakeet model is already
installed, and keep real recorded audio as a separate opt-in fixture.

**Alternatives:** Require environment-provided audio for every golden run;
commit real speech without a clear redistribution grant; let tests download a
model; replace real-model testing entirely with a mock.

**Reasoning:** A committed deterministic fixture turns the real adapter into a
repeatable regression guard without network activity or licensing ambiguity.
Skipping names the exact missing local model. Synthetic speech cannot represent
room noise, accents, disfluency, or meeting cross-talk, so it is not presented
as an accuracy benchmark and the optional recorded fixture remains available.

## 2026-08-01 — Let each transcription engine own window geometry

**Decision:** Add `preferredWindowDuration` and `preferredOverlap` to the
transcription-engine contract. Batch WAV reads and live VAD windowing resolve
their geometry from the selected engine; Parakeet declares 14 seconds with a
1.5-second overlap.

**Alternatives:** Keep values independently hardcoded in both pipelines; make
the UI select geometry; infer the engine type with runtime casts.

**Reasoning:** Window requirements are model capabilities. Keeping them on the
engine prevents batch and live behavior from drifting and allows a later
Whisper engine to request its required 30-second window without model-specific
conditionals in either pipeline.

## 2026-08-01 — Overlap and stitch batch transcription windows

**Decision:** Advance canonical batch reads by engine window duration minus
engine overlap, then run produced segments through the existing source-aware
overlap deduplicator before the final timeline merge.

**Alternatives:** Keep nonoverlapping batch chunks; concatenate overlapping
results verbatim; add a second batch-only text merger; load the complete track
into memory.

**Reasoning:** Context on both sides of a model boundary protects words split
by a batch seam. Reusing the timing-aware live deduplicator keeps each word once
without mixing microphone and system speech, while bounded reads preserve the
long-recording memory guarantee.

## 2026-08-01 — Bound timed utterances by their words

**Decision:** When Parakeet returns word timings, set each transcript segment's
start to the first mapped word and its end to the last mapped word. Use backend
duration from the chunk start only when no valid word timing is available.

**Alternatives:** Display the complete ASR window bounds; use backend duration
even when words identify a tighter interval; invent timing for untimed text.

**Reasoning:** Chunk bounds describe inference input, not when the utterance was
spoken. Word-derived bounds make microphone/system interleaving and visible row
timestamps reflect speech while retaining a safe fallback for sparse backend
results.

## 2026-08-01 — Materialize documented Core Audio render gaps as silence

**Decision:** When a system-tap `AudioBuffer` has a nil data pointer but a
nonzero reported byte size, append that frame count as zero-valued samples to
the canonical fan-out. Keep an actually empty, header-only system track valid.

**Alternatives:** Compress gaps out of the WAV; add per-gap corrections to the
manifest; reject an empty remote-side track; generate silence from a wall-clock
timer independently of Core Audio.

**Reasoning:** Core Audio documents nil data with retained byte size for a
disabled input stream. That byte count is the render timeline information the
old mixer discarded. Materializing it before WAV/live fan-out preserves one
linear sample-index mapping for persistence, VAD, and transcription without a
second timing model. A timer would race the device clock, while manifest gap
records would leave the durable audio itself temporally compressed.

## 2026-08-01 — Order equal transcript starts by capture source

**Decision:** Sort transcript segments first by absolute start, then microphone
before system, then by end and text. Reuse the same comparator for live rows and
batch timeline merges; continue applying each track's manifest start offset
before sorting.

**Alternatives:** Compare end time before source; rely on insertion or dictionary
order; sort by the displayed whole-second timestamp; always put the shortest
utterance first.

**Reasoning:** The microphone capture starts first and the system track carries
its measured positive offset. At a genuinely equal absolute start, source order
is the stable tie-breaker; utterance length must not reverse the speaker order.
Comparing full-precision times avoids manufacturing ties from UI rounding.

## 2026-08-01 — Carry the observed unavailable component into status text

**Decision:** Give live-transcription's unavailable state an explicit reason:
missing Silero voice-activity model or missing Parakeet transcription model.
Centralize live transport, speech, and transcription wording in a tested
formatter.

**Alternatives:** Infer the reason from whichever model is usually missing;
keep one generic unavailable message; let each view independently reconstruct
pipeline state.

**Reasoning:** The previous shared state blamed Parakeet even when the branch
had directly observed missing Silero. The audit found one related issue: raw
live-audio transport buffering was labelled an ASR backlog even though it can
occur before ASR. It also found idle batch status claiming readiness without a
recording or selected model. Explicit inputs ensure messages report observed
state rather than a plausible cause and keep degradation understandable.

## 2026-08-01 — Quantize only durable session audio to Int16 PCM

**Decision:** Keep capture, live fan-out, VAD, and transcription in Float32,
but stream each durable 16 kHz mono session track as signed 16-bit PCM. Continue
accepting both Int16 PCM and the legacy Float32 format in the transcription
reader.

**Alternatives:** Retain Float32 WAV storage; quantize inside realtime capture;
convert old sessions in place; introduce a compressed-audio dependency.

**Reasoning:** Int16 halves the durable sample payload without changing model
input or realtime behavior. Quantizing on the existing non-realtime consumer
preserves callback safety. Read-time compatibility keeps existing recordings
usable and avoids modifying user session data.

## 2026-08-01 — Reserve disk capacity before and during recording

**Decision:** Before either audio service starts, require enough free capacity
for a configurable expected duration plus a configurable reserve. Estimate the
two Int16 WAVs and worst-case simultaneous Float32 live-transport and speech
window spools. Recheck periodically during recording and, at or below the
reserve—or if capacity can no longer be queried—stop through the ordinary
two-track finalization path.

**Alternatives:** Check only when a file write fails; budget only durable WAVs;
monitor in the UI; delete prior sessions automatically; continue recording when
the capacity provider fails.

**Reasoning:** Write failure is too late to guarantee valid headers, while the
temporary bounded-memory queues can dominate disk use under sustained backlog.
Keeping policy and monitoring in the capture coordinator guarantees preflight
before capture, applies equally outside the UI, and is deterministic under an
injected provider. Automatic deletion would violate local-data ownership.

## 2026-08-03 — Establish a dependency-free model catalogue boundary

**Decision:** Add a `ModelManager` framework that owns validated model
identifiers, provider/task metadata, language coverage, safe installation folder
names, live-processing capability, and transcription window geometry. Seed it
with the two current Parakeet variants and Silero before migrating storage or
download behavior.

**Alternatives:** Keep extending milestone-specific stores in `SpeechPipeline`;
introduce the framework only when WhisperKit is added; make catalogue entries
unvalidated dictionaries; add speculative Whisper entries immediately.

**Reasoning:** A dependency-free catalogue prevents the future Whisper package
from becoming the owner of application-wide identity and policy. Validating
identifiers, paths, and geometry at construction catches unsafe or contradictory
metadata before it reaches storage or inference. Starting with models Scribe
already supports keeps the first checkpoint factual; Whisper entries wait for
measured source metadata and the exact dependency pin.
