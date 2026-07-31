# FluidAudio streaming evaluation

**Date:** 1 August 2026  
**Scope:** Research only; no implementation or dependency change  
**Current pin:** FluidAudio `0.15.5`, revision
`19600a485baa4998812e4654b70d2bab8f2c9949`

## Executive conclusion

Scribe does not need to upgrade FluidAudio to evaluate Parakeet Realtime EOU.
Version `0.15.5` is both Scribe's current exact pin and FluidAudio's latest
published release, and the checked-out tag already contains
`StreamingEouAsrManager`, 160/320/1280 ms variants, partial callbacks, token
timestamps, and end-of-utterance callbacks.

The streaming model should not replace Scribe's current live path outright. It
is English-only and NVIDIA states explicitly that it does not output
punctuation or capitalization. TDT v3 supports 25 European languages, including
English, Swedish, and Greek, and preserves punctuation and capitalization. That
difference matters when transcript text becomes LLM input.

Recommendation: keep TDT v3 as the multilingual and punctuation-preserving
batch/re-transcription engine, retain the current Silero/window path for
non-streaming engines, and later prototype Parakeet EOU as an optional
English-only low-latency live engine at the existing pin. Do not delete the
current Milestone 3B path unless Scribe decides to drop multilingual live
transcription and future live Whisper support.

## Evidence and version correction

FluidAudio's [latest release page](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.5)
identifies `0.15.5` as the latest published version. The pinned tag contains:

- [`StreamingEouAsrManager`](https://github.com/FluidInference/FluidAudio/blob/v0.15.5/Sources/FluidAudio/ASR/Parakeet/Streaming/EOU/StreamingEouAsrManager.swift);
- [`StreamingAsrManager`](https://github.com/FluidInference/FluidAudio/blob/v0.15.5/Sources/FluidAudio/ASR/Parakeet/Streaming/StreamingAsrManager.swift);
- EOU variants at 160, 320, and 1280 ms;
- partial transcript callbacks;
- token timestamp and raw-token providers;
- configurable EOU debounce;
- explicit model-directory loading as well as FluidAudio-managed download.

FluidAudio's current benchmark reports 4.88% WER at the 320 ms tier and 8.23%
at the 160 ms tier on LibriSpeech test-clean on an M2. These numbers exclude the
messier acoustics and turn-taking of real meetings and should be treated as
upstream reference data, not Scribe acceptance evidence. See FluidAudio's
[streaming benchmark](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md#streaming-asr-parakeet-eou).

## 1. Cost of upgrading the pin

### Immediate answer

There is no pin-upgrade cost for an EOU prototype today: the API is already in
the exact version Scribe builds and tests. The pin must remain `0.15.5` under
the current work order.

### Cost if a future FluidAudio release becomes necessary

The latest release includes a breaking ModelHub download refactor and a large
ASR surface. A future pin change should be treated as a dependency migration,
not a routine version bump.

| Work | Estimated hours |
|---|---:|
| Review release notes and diff all Scribe-used APIs | 2–4 |
| Adapt model discovery/download/offline-loading APIs | 4–8 |
| Resolve source and API breakage | 4–8 |
| Revalidate Swift 6 complete strict concurrency | 4–6 |
| Run full unit, golden, Debug, and Release matrix | 3–5 |
| Real Parakeet/Silero regression on target hardware | 4–8 human hours |
| Documentation and failure-path audit | 2–3 |
| **Dependency-upgrade total** | **23–42 hours** |

This estimate does not include changing Scribe's architecture to use EOU. A
production EOU adapter, model acquisition UI, two-source streaming coordinator,
partial/final mapping, tests, and real acceptance add approximately 32–52
engineering hours. A future pin upgrade plus integration would therefore be
roughly 55–94 hours.

Swift 6 revalidation must cover callback sendability, actor isolation, model
lifecycle, cancellation, and cleanup. Compiling alone is insufficient because
streaming callbacks can introduce ordering and lifetime defects even when the
type checker is satisfied.

## 2. Milestone 3B redundancy

### If EOU becomes the only live engine

For the EOU path specifically, these elements become redundant:

- **Silero download and store:** redundant because EOU is predicted by the ASR
  model and debounced by `StreamingEouAsrManager`.
- **Per-source Silero recurrent state:** redundant; each source instead needs
  its own EOU streaming decoder/cache state.
- **0.85/0.70 hysteresis:** redundant for segmentation. EOU's learned token and
  configurable debounce replace the threshold state machine.
- **30-second continuous-speech ceiling:** redundant as an ASR input-size guard
  because cache-aware streaming processes bounded chunks continuously. A
  separate product-level maximum-open-utterance safeguard may still be useful
  for UI/persistence and must not be confused with model geometry.
- **Speech-window spool:** redundant for EOU inference. Raw canonical audio can
  be consumed incrementally. Backpressure still requires a bounded disk-backed
  transport, so `LiveAudioTransport` remains valuable.

An exclusive EOU conversion could delete approximately:

| Area | Current lines likely deleted |
|---|---:|
| `SileroVoiceActivityDetector.swift` | 235 |
| `LiveSpeechPipeline.swift` | 1,326 |
| Window-provider portions of `LiveTranscriptionPipeline.swift` | 120–180 |
| Silero/window wiring in the app UI and view model | 140–220 |
| **Production total** | **1,821–1,961** |
| Obsolete Silero/window tests, replaced by streaming tests | 450–650 |

The production estimate is based on the current checked-in line counts and
explicit references, not a claim that a replacement would have zero code. A
new two-source EOU adapter and its model-store/UI support would add roughly
500–800 production lines, so the likely net reduction is approximately
1,000–1,450 production lines.

### Why those lines are not globally redundant

Deleting them would remove capabilities Scribe still requires:

1. Parakeet EOU supports English only. Scribe explicitly requires Swedish and
   Greek live transcription through TDT v3.
2. Whisper models added in Milestone 4 use batch windows and do not supply the
   same EOU contract. They still need segmentation or a separate streaming
   strategy.
3. Silero remains useful for non-EOU engines and can reduce unnecessary batch
   inference over silence.
4. The speech-window spool is the current backpressure boundary for any
   window-based engine.

The correct architecture is therefore capability-based coexistence, not a
global deletion.

## 3. Batch and streaming behind `TranscriptionEngine`

They can coexist behind the existing protocol for identity, capability
metadata, preparation, finalization, and unloading. The existing
`supportsStreaming` flag already anticipates this distinction.

They should not be forced through exactly the same pull-based execution path.
The current `transcribe(AudioChunk)` method describes bounded request/response
inference. True streaming needs persistent per-source cache state, repeated
audio appends, partial callbacks or an async update stream, EOU events, and
reset between utterances.

Recommended shape for a future prototype:

```swift
protocol TranscriptionEngine: Sendable {
    // Shared metadata and lifecycle plus batch transcribe/finish.
}

protocol StreamingTranscriptionEngine: TranscriptionEngine {
    func append(_ chunk: AudioChunk) async throws
    var updates: AsyncThrowingStream<TranscriptUpdate, Error> { get }
    func reset(source: AudioSource) async throws
}
```

The catalogue and UI can store either as `any TranscriptionEngine`, while the
live coordinator checks the streaming capability and chooses the raw streaming
path. Saved-session re-transcription continues through TDT v3 or Whisper batch
engines. This preserves one model identity/lifecycle abstraction without
pretending that batch windows and cache-aware streaming have identical
semantics.

Using only the current protocol is technically possible by treating each
160/320 ms append as `transcribe` and returning repeated segments, but it would
hide reset/EOU semantics and make partial identity fragile. A refined protocol
is the clearer design.

## 4. Punctuation quality

The difference is categorical, not merely a small quality delta.

NVIDIA's [Parakeet Realtime EOU model card](https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1)
states that the English-only model does not output punctuation or
capitalization. Its output example is plain text followed by an optional EOU
token.

NVIDIA's [Parakeet TDT v3 model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
lists automatic punctuation and capitalization as key features and states that
its training transcriptions preserve both. FluidAudio's unified/sliding-window
TDT path also contains explicit punctuation-aware seam handling.

Consequences for Milestone 6:

- EOU text loses sentence boundaries, questions, proper capitalization, and
  much of the structure that helps an LLM reconstruct intent and turn-taking.
- An LLM can repunctuate, but that adds cost, latency, and another inference
  transformation that can change meaning.
- TDT v3 batch re-transcription is better source text for durable transcripts
  and generated meeting notes.
- A low-latency EOU preview could later be replaced by a punctuation-preserving
  batch transcript for the finalized session, provided the UI clearly explains
  the replacement.

FluidAudio's published WER values normalize punctuation away, so they do not
measure this product-relevant quality gap. Scribe would need a punctuation-aware
fixture metric before presenting EOU output as equivalent to TDT v3.

## 5. Recommendation

### Recommendation

Do not replace the current path. After the post-acceptance fixes and model
manager are complete, prototype Parakeet EOU 320 ms at the existing 0.15.5 pin
as an optional **English low-latency live preview** engine. Keep TDT v3 for:

- multilingual live sessions through the existing VAD/window path;
- saved-session re-transcription;
- punctuation-preserving durable transcript text;
- English, Swedish, and Greek coverage.

The 320 ms tier is the better initial candidate than 160 ms because FluidAudio's
published benchmark reports materially lower WER and higher throughput, while
remaining dramatically more responsive than the current 15.5-second first
partial.

Before shipping the option, require:

1. source-isolated manager state for microphone and system audio;
2. explicit offline model acquisition through Scribe's model manager;
3. punctuation-aware and WER golden results;
4. real two-source meeting acceptance;
5. an explicit policy for replacing preview text with TDT v3 batch results;
6. disk and RAM measurements;
7. confirmation that EOU debounce behaves acceptably with room noise and
   cross-talk.

### Strongest case for the recommendation

- First partial latency falls from about 15.5 seconds to subsecond updates.
- Built-in EOU removes a separate segmentation stage for this engine.
- The 120M model is smaller than TDT v3's 0.6B model.
- Persistent encoder caches match the live problem better than repeated batch
  windows.
- The current FluidAudio pin already exposes the API, avoiding dependency risk.
- Batch and streaming can be assigned to the tasks each performs best.

### Strongest case against the recommendation

- English-only streaming conflicts with Scribe's English/Swedish/Greek product
  requirement.
- No punctuation or capitalization makes the live text worse input for
  Milestone 6 summaries.
- Maintaining two live architectures increases model, UI, test, and lifecycle
  complexity.
- Two managers are required for isolated microphone/system cache state.
- Published clean-speech WER and EOU latency do not establish meeting-room
  behavior.
- Replacing preview text after batch re-transcription can surprise users and
  complicate persistence identity.
- Keeping TDT v3 resident for later re-transcription while EOU is resident would
  conflict with Milestone 4's single-large-model policy unless lifecycle is
  carefully sequenced.

### Final position

The latency gain is worth a controlled optional prototype, but not a migration
of the default architecture. The absence of punctuation and multilingual
support is too consequential to remove the working TDT v3/Silero path. No
implementation should begin until the current post-acceptance work is complete
and real fixture-based acceptance criteria are defined.
