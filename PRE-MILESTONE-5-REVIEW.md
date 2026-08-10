# Pre-Milestone 5 Review

Stopped before Milestone 5. No runtime code was changed; only stale documentation was corrected in `ARCHITECTURE.md`.

## 1. Live window geometry

Live geometry is not hardcoded to 14 seconds in production.

The configuration has 14/1.5 defaults, but both engine-aware constructors replace them with `preferredWindowDuration` and `preferredOverlap` from the selected engine (`LiveSpeechPipeline.swift`, `usingWindowGeometry` and the production constructor).

With Whisper selected:

- Window duration: 30 seconds.
- Overlap: 1.5 seconds.
- Short utterances are submitted after VAD observes the 750 ms silence boundary.
- Continuous speech reaches the 30-second VAD ceiling and produces a final 30-second window, followed by inference. It does not produce a nonfinal Whisper partial first, because partial emission requires `window + overlap`, while the VAD ceiling stops the segment at 30 seconds.
- Therefore continuous Whisper speech has roughly 30 seconds plus inference time before its first row.

The focused engine-geometry regression passed. I corrected the live and batch diagrams, Live VAD explanation, and Parakeet-specific live wording in `ARCHITECTURE.md`.

## 2. Whisper live capability

Every built-in catalogue entry is marked live-capable:

- Parakeet v3 Multilingual
- Parakeet v2 English
- Silero VAD
- All 12 Whisper variants: Tiny, Tiny English, Base, Small, Medium, Large v3, Large v3 Turbo, Distil Large v3, and the four compressed/optimized Large or Distil variants.

For Whisper this is assigned uniformly by the catalogue helper, alongside 30/1.5 geometry.

That flag currently means “compatible with the window-based live pipeline,” not “streaming” or “low latency”:

- Whisper explicitly declares `supportsStreaming = false`.
- `supportsLiveProcessing` is not consulted by the model picker or live-start path.
- All transcription cases are exposed in the picker.
- The current evidence is batch WER/resource measurement, not live-latency validation.

Consequently, Large v3 and all large-derived variants are selectable for live capture. If installed and within the memory gate, they load normally. On this 24 GB Mac, Large v3’s measured 4.44 GB peak is below the configured safe-memory budget.

The resulting experience would be:

- noticeable model preparation and inference cost;
- short phrases appearing after silence plus inference;
- continuous speech appearing approximately every 30 seconds plus inference;
- no word-by-word streaming;
- final 30-second rows rather than early partial Whisper rows.

If loading is rejected or fails, recording and VAD continue while live transcription reports the failure.

## 3. Batch seam quality

The residual is not a dropped word. It is duplicated content containing corrupted partial-word variants.

At the first forced seam:

```text
Expected:
The team will test the offline transcription workflow on Friday morning

Actual:
The team will test the offline transition. will test the offline transcription workflow on Friday morning
```

Here, `will test the offline` is duplicated and the first copy of `transcription` is corrupted to `transition`. The correct phrase follows afterward, so the optimal WER alignment treats the five extra tokens as insertions.

The forced geometry creates another seam later:

```text
Expected:
Clear timestamps help everyone understand

Actual:
Clear timestamps help every Clear timestamps help everyone understand
```

That adds four more inserted tokens, with the first `everyone` truncated to `every`.

Therefore:

- 9 insertion errors
- 0 dropped reference tokens
- WER: `9 / 51 = 0.1765`

The regression only tests one boundary: the midpoint of `transcription` at 9.640 seconds. It provides no nearby-boundary sensitivity measurement.

Also, the numerical margin is 0.0235, not 0.035:

- 9 errors: 0.1765
- 10 errors: 0.1961 — still passes
- 11 errors: 0.2157 — fails

So the test has only one additional word-error of practical headroom. Its current result should be considered boundary-sensitive and brittle, not strong evidence of seam robustness.

## 4. Orphaned model data

There are two Small folders, and their identities matter:

- `openai_whisper-small` is the supported uncompressed Small model. It is catalogued and accounted: **489,250,614 logical bytes**.
- `openai_whisper-small_216MB` is the failed compressed diagnostic folder. It is not catalogued. It uses:
  - **220,113,912 logical bytes**
  - **220,168,192 allocated bytes**
  - approximately **220.1 MB / 210 MiB**
  - 21 regular files

Current disk accounting does not see the `_216MB` orphan. Accounting starts from a known descriptor’s installation directory, while the UI total loops only through known transcription selections plus Silero. The orphan contributes zero to the displayed total.

Recommended treatment:

- Scan immediate children of the Models directory.
- Compare them with catalogue installation-directory names.
- Exclude `.Downloads` as managed temporary data.
- Show unknown folders under an “Unrecognized model data” section.
- Include their logical size in total library usage and show an unmanaged subtotal.
- Offer “Reveal in Finder” and a confirmation-protected “Move to Trash” action.
- Never silently load, adopt, rename, or delete unknown folders.

Current working tree: only `ARCHITECTURE.md` and this review document are modified. Milestone 5 has not started.
