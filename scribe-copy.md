# Scribe copy

Every user-facing string in the app. Implement as one centralized strings file,
not scattered literals. Extend from the rules below rather than inventing a new
voice per screen.

## Rules

- Sentence case everywhere. Buttons, headings, labels, menu items. Never title
  case, never all caps.
- Verb first on every action. “Download model”, not “Model download”. “Start
  recording”, not “Recording”.
- No terminal punctuation on labels, buttons, or headings. Helper text and error
  bodies do take periods.
- Errors say what happened, then what to do, in that order. One sentence each,
  two lines maximum. No “Error:” prefix. Never surface a raw OSStatus or
  exception string in the main message. Put the technical detail behind a
  “Details” disclosure for the person who wants it.
- Name the actual component that failed. Never a plausible-sounding guess. If
  Silero is missing, say Silero. This rule already exists in the pipeline; the
  copy has to honour it.
- Never blame the user and never apologise. “Couldn't reach Hugging Face”, not
  “Sorry, we were unable to complete your request.”
- Cut “please”, “simply”, “just”, “successfully”, “easy”. The success state is
  the confirmation; it does not need the word.
- Use contractions. “Couldn't”, “isn't”, “you'll”.
- The rule that matters most in this app: a transcription failure must never
  read as a recording failure. Audio is irreplaceable, text can be regenerated.
  Any message about transcription must state that the recording is unaffected.

## Permissions

### Microphone, before asking

- Title: **Record your voice**
- Body: **Scribe needs microphone access to capture your side of the
  conversation.**
- Button: **Allow microphone**

### Microphone, denied

- Title: **Microphone access is off**
- Body: **Scribe can't record your voice until you turn this on in System
  Settings.**
- Button: **Open System Settings**

### System audio, before asking

- Title: **Record the other participants**
- Body: **Scribe captures what you hear without joining the call. This uses
  audio only, never your screen.**
- Button: **Allow system audio**

### System audio, denied

- Title: **System audio access is off**
- Body: **Scribe can record you, but not the people you're talking to.**
- Button: **Open System Settings**

### Both granted

- Title: **You're set**
- Body: **Scribe records both sides separately, so you always know who said
  what.**
- Button: **Continue**

## First run, model download

### Downloading

- Title: **Downloading the transcription model**
- Body: **One time, about 600 MB. Everything after this runs offline on your
  Mac.**
- Progress: **240 MB of 600 MB**
- Cancel: **Cancel download**

### Download failed

- Message: **Couldn't reach the model server. Check your connection and try
  again.**
- Button: **Retry**

### Download cancelled

- Message: **Download cancelled. Nothing was installed.**
- Button: **Download model**

### Complete

- Title: **Ready**
- Body: **Nothing you record leaves this Mac.**
- Button: **Start your first recording**

## Persistent shell

- Primary action: **New recording**
- Import action: **Import audio or video…**
- Smart folders available now: **All sessions** · **Imported**
- Summary-capability smart folder: **Needs summary**. Keep it hidden until
  summary generation is available; do not show a permanently full destination
  before Milestone 6 gives it an action and artifact lifecycle.
- Manual-folder section: **Folders** · **New folder** · **Folder name** ·
  **Create** · **Cancel**
- Bottom item: **Settings**
- Header field: **Search** · **⌘K**
- Drop affordance: **Drop to import**
- Active capture: **Recording** · **Current recording**
- Empty library: **No recordings yet** · **Start one from the menu bar or press
  the record button above.** · **Start recording**
- Empty smart folders: **Every session has a summary** · **No imported
  sessions**
- Folder errors: **Enter a folder name.** · **A folder named “Client Calls”
  already exists.** · **“Meeting” is not a Scribe session folder.** · **The
  destination is outside the Scribe save location.**

Session counts are rendered as **3 sessions**, using the actual count.
One session is rendered as **1 session**.

## Sessions library

- Imported metadata: **Imported**
- Artifact labels: **Notes** · **Transcript** · **Summary** · **Audio**
- Artifact state for accessibility: **Present** · **Not present**
- Search empty state: **No matching sessions** · **Try another word or
  phrase.**
- Search hit sources without a timecode: **Session** · **Notes** ·
  **Transcript**
- Result counts: **1 result** · **3 results**
- Rename: **Rename…** · **Rename session** · **Session title** · **Save** ·
  **Cancel**
- Empty rename: **Enter a session title.**
- Delete action: **Move to Trash…**
- Confirmation title: **Move “Weekly review” to Trash?**
- Confirmation body: **The 84.2 MB session folder moves to Trash and can be
  recovered there. Its audio, transcript, notes, and other artifacts move
  together.**
- Confirmation buttons: **Move to Trash** · **Cancel**
- Unavailable session: **The session folder is unavailable. Reconnect its save
  location and try again.**
- Search failure: **Scribe couldn't search sessions. Session folders are
  untouched: [reason]**

Calendar group labels use the localized date, with **Today** and **Yesterday**
for the two relative headings. Live rows render **1 speaker** or **3 speakers**;
imported rows omit speaker count.

## Recording

- Start: **Start recording**
- Stop: **Stop recording**
- Menu bar idle: **Start recording**
- Menu bar active: **Recording · 12:04**
- Both tracks live: **You · Others** (level meters, no text needed)

### Recording pins

- Action: **Add pin** · **⌘⇧K**
- Confirmation: **Pin added at 12:04**
- Before captured audio starts: **Pins become available when captured audio
  starts.**
- Save failure: **Couldn't save the pin. The recording and notes are
  unaffected.**
- Shortcut conflict: **The pin shortcut couldn't be registered. Recording
  still works.**

The pin action has no prompt and no generated label. A label remains optional
data that can be added later without changing the captured sample offset. Show
**Pin added** only after the atomic `session.json` write succeeds. A failed
write uses the failure copy above in the same sidebar status position; never
acknowledge the keypress itself as a saved pin.

### Preparing system audio

- Status: **Preparing system audio before recording**
- Button after Record is pressed: **Preparing system audio…**

Recording waits for the one launch-time preparation already in progress. Do not
imply that recording has started until both capture tracks are running.

### System track silent for more than 30 seconds

**Nothing plays through your Mac right now**

This is a status line, not a warning. A quiet remote side is normal, and a
header-only system track is a valid recording. Never style this as an error.

### Live transcription waiting for the first result

**Listening. First text in about 15 seconds.**

State the actual delay. Users forgive a wait they were told about.

### Recording workspace

- Surfaces: **Notes** · **Transcript**
- Notes placeholder: **Type while you listen**
- Rail actions: **Show transcript** · **Hide transcript**
- Accessibility: **Transcript width** · **Recording controls** · **You speech
  level** · **Others speech level** · **Elapsed recording time**

### Notes couldn't be saved

**Couldn't save notes. The recording is unaffected.**

### Transcription running behind

**Catching up on transcription. Recording is unaffected.**

### Buffering to disk

**Transcription is buffering. Recording is unaffected.**

### Selected model isn't installed

- Message: **Recording without transcription. Parakeet v3 Multilingual isn't
  installed.**
- Button: **Download it**

### Selected model failed to load

- Message: **Recording without transcription. Whisper Large v3 couldn't
  load.**
- Secondary: **Details**
- Button: **Choose another model**

### Fallback offer, after a failure

- Message: **Whisper Small is installed and would fit. Switch to it?**
- Buttons: **Switch to Whisper Small** · **Keep recording without
  transcription**

Never auto-switch. The user clicks or nothing changes.

### Silero missing

- Message: **Live transcription needs Silero. Recording and the full transcript
  afterwards work without it.**
- Button: **Download Silero**

## Disk

### Preflight refusal

- Title: **Not enough space to record**
- Body: **A two hour session needs about 2.3 GB. You have 1.1 GB free.**
- Buttons: **Manage models** · **Cancel**

### Stopped mid-recording

- Title: **Recording stopped, disk full**
- Body: **Both audio files were saved and are complete up to 18:42.**
- Button: **Reveal in Finder**

The first line has to say the audio survived. That is the only thing the user
cares about in this moment.

## Transcript rows

- Source labels: **You** · **Others**
- Partial state: **Partial**
- Final state: no label. Absence of “Partial” is the signal.

### A finalized row corrects itself

No message. Animate the changed words with a brief highlight, roughly 800 ms,
then let it settle. A visible explanation would draw more attention to the
correction than the correction deserves.

### No transcript exists

- Title: **No transcript yet**
- Body: **This session was recorded without a model installed.**
- Button: **Transcribe now**

## Re-transcribing

- Button: **Transcribe again**
- Model picker label: **Transcribe with**
- In progress: **Transcribing with Whisper Large v3. About 3 minutes.**
- Complete: **Done. Your earlier transcript is kept as
  transcript-parakeet-v3.md.**
- First transcription complete: **Done. Transcript files were created.**

That sentence is the whole feature. It tells the user nothing was lost and
names the file they can go find.

## Session artifacts

- Rail labels: **Notes** · **Transcript** · **Summary** · **Audio**
- Provenance badges: **Local** · **Claude** · **GPT**
- Copy actions: **Copy notes** · **Copy transcript** · **Copy summary**
- Reveal: **Reveal in Finder**
- Drag hint: **Drag any row to Finder or another app**

### Reading view

- Navigation: **Back to sessions**
- Playback: **Play** · **Pause**
- Timeline labels: **Timeline** · **Talk time**
- Speaker action: **Rename speaker**
- Empty notes: **No notes yet** · **Create notes**
- Empty audio: **No playable audio is available**
- Revision section: **Transcriptions**

### Summary

- Title: **No summary yet**
- Actions: **Generate summary** · **Generate again**
- Revision section: **Summaries**

### Reading-view secondary failures

- Session unavailable: **Scribe couldn't read this session. Its files are
  untouched.**
- Speaker rename: **Couldn't rename the speaker. The transcript and recording
  are unaffected.**
- Notes creation: **Couldn't create notes. The recording and transcript are
  unaffected.**
- Re-transcription: **Transcription failed. The recording and earlier
  transcripts are unaffected.**

## Import audio or video

- Menu item: **Import audio or video…**
- File picker action: **Import**
- Copying: **Copying interview.mov**
- Converting: **Converting interview.mov to 16 kHz mono audio**
- Transcribing: **Transcribing interview.mov with Parakeet v3 Multilingual**
- Complete: **Imported and transcribed interview.mov**

### Selected model isn't installed

**Install Parakeet v3 Multilingual before importing. No session was created.**

### Unsupported format

**Scribe can't read “interview.xyz”. Choose an audio or video format supported
by macOS.**

### Video has no audio track

**“interview.mov” doesn't contain an audio track. Choose a file with audio.**

### File contains no playable samples

**Scribe found no audio samples in “interview.m4a”. Choose a file that contains
playable audio.**

### Copy failed

**Scribe couldn't copy “interview.mov”. The original file is untouched.**

### Decode failed

**Scribe couldn't decode audio from “interview.mov”. The original file is
untouched.**

### Transcription failed after import

**Couldn't transcribe “interview.mov”. The imported original and audio.wav are
unaffected.**

### Transcript files couldn't be saved

**Couldn't save transcript files for “interview.mov”. The imported original and
audio.wav are unaffected.**

### Live transcript files couldn't be saved

**Live transcript files couldn't be saved. The recording is unaffected and can
be transcribed again.**

The designed sessions-library drop target and its drag hint belong to the views
order. Phase 2 may accept a file dropped anywhere on the placeholder window,
but that temporary target must not determine the later library layout.

### Empty notes

- Placeholder: **Type while you listen**

Not “Start typing your notes here.” The placeholder should be the shortest true
instruction.

### Empty sessions list

- Title: **No recordings yet**
- Body: **Start one from the menu bar or press the record button above.**
- Button: **Start recording**

## Summary generation

- Button: **Generate summary**
- Template label: **Using**
- Configuration labels: **Provider** · **Model** · **Template**
- Actions: **Load models** · **Prepare summary** · **Cancel**
- Loading: **Loading models…**
- Local disclosure: **This provider runs on this Mac. Nothing leaves the
  machine.**
- Cloud disclosure: **The transcript and notes will leave this Mac when you
  confirm.**
- Local generation: **Generating summary on this Mac with [provider].**
- Token estimate: **About [count] tokens**
- Known-price estimate: **Estimated maximum cost: [amount]**

### Cloud generation, before sending

- Title: **Send to [provider]?**
- Body: **Your transcript and notes will be sent to [provider]. About [count]
  tokens. [Estimated maximum cost: [amount].]**
- Buttons: **Send** · **Cancel**

Say the destination company by name. “Send to the cloud” is vague where
vagueness is exactly what erodes trust.

### Cloud generation running

**Sending to [provider]**

### Failed

- Message: **[Provider] didn't respond. Your transcript, notes, recording, and
  earlier summary are untouched.**
- Button: **Try again**

Other failures:

- Missing transcript: **Transcribe this session before generating a summary.
  The recording and notes are unaffected.**
- Empty response: **The provider returned an empty summary. Your transcript,
  notes, recording, and earlier summary are untouched.**
- Too large for one request: **This transcript needs about [count] input
  tokens, beyond this model's single-pass allowance of [count] tokens.
  Long-transcript generation is not available yet. The session files are
  untouched.**

### Complete

No message. The summary appearing in the rail is the confirmation.

## Summary templates

- Section: **Summary templates**
- Picker label: **Template**
- Fields: **Name** · **Instructions**
- Actions: **New template** · **Duplicate** · **Save template** · **Remove
  template**
- New template name: **Untitled template**
- New template instructions: **{{transcript}}**
- Duplicate name pattern: **[original name] copy**
- Saved: **Template saved**
- Created: **Template created**
- Duplicated: **Template duplicated**
- Removed: **Template removed**
- Variables helper: **Variables: {{notes}}, {{transcript}}, {{title}}, {{date}},
  {{participants}}, {{pins}}**
- Load failure: **Scribe couldn't load summary templates. Sessions and their
  files are unaffected.**
- Save failure: **Scribe couldn't save this template. Sessions and their files
  are unaffected.**
- Remove failure: **Scribe couldn't remove this template. Sessions and their
  files are unaffected.**
- Remove title: **Remove “[template name]” template?**
- Remove body: **This removes the custom template. Sessions, transcripts,
  notes, and summaries are unaffected.**
- Buttons: **Remove template** · **Cancel**
- Missing name: **A template name is required.**
- Missing instructions: **Template instructions are required.**
- Missing template: **The template no longer exists.**
- Protected default: **Built-in templates cannot be deleted.**
- Unknown variable: **Unknown template variable: {{[variable]}}.**
- Malformed variable: **A template variable is incomplete or malformed.**

### Meeting summary

```text
Write a concise meeting summary for “{{title}}” on {{date}}.

Participants:
{{participants}}

Notes:
{{notes}}

Transcript:
{{transcript}}

Important moments marked during the meeting:
{{pins}}

Explain what was discussed, what was decided, and what remains outstanding. Do not invent facts, owners, or dates.
```

### Decisions and actions

```text
Extract decisions and action items from this meeting. For each decision, include its stated rationale. For each action, include its owner and date only when explicitly stated. Give marked moments extra attention, but do not invent missing information.

Meeting: {{title}}
Date: {{date}}
Participants: {{participants}}
Notes: {{notes}}
Marked moments: {{pins}}
Transcript: {{transcript}}
```

### Interview notes

```text
Produce interview notes organised by themes. Include notable quotations with their transcript timestamps when available, and finish with open questions. Treat marked moments as the interviewer's signals of importance.

Interview: {{title}}
Date: {{date}}
Participants: {{participants}}
Notes: {{notes}}
Marked moments: {{pins}}
Transcript: {{transcript}}
```

### One-to-one

```text
Summarise this one-to-one by topics raised, commitments made by each person, and follow-ups. Keep sensitive statements factual and do not infer motives.

Meeting: {{title}}
Date: {{date}}
Participants: {{participants}}
Notes: {{notes}}
Marked moments: {{pins}}
Transcript: {{transcript}}
```

### Lecture or talk

```text
Summarise this lecture or talk in presentation order. Capture key points, terminology introduced, examples, and references mentioned. Do not add outside information.

Title: {{title}}
Date: {{date}}
Notes: {{notes}}
Marked moments: {{pins}}
Transcript: {{transcript}}
```

### Raw cleanup

```text
Clean up the transcript without interpreting or summarising it. Remove disfluencies and obvious false starts, retain every substantive statement, preserve speaker attribution, and arrange the result into readable paragraphs. Do not add facts or conclusions.

Participants: {{participants}}
Transcript: {{transcript}}
```

## Models screen

- Title: **Models**
- Sections: **Installed** · **Available**
- Per model: name, size on disk, memory needed, languages
- Actions: **Download** · **Pause** · **Resume** · **Cancel** · **Move to
  Trash…**

### Model removal confirmation

- Title: **Move Whisper Large v3 to Trash?**
- Body: **The 3.1 GB model folder moves to Trash. You can recover it there or
  download it again later. Recordings and transcripts are unaffected.**
- Buttons: **Move to Trash** · **Cancel**

### Silero removal confirmation

- Title: **Move Silero VAD to Trash?**
- Body: **The model folder moves to Trash and can be recovered there. Live
  speech detection will be unavailable until Silero is restored or installed
  again. Recordings and transcripts are unaffected.**
- Buttons: **Move to Trash** · **Cancel**

### Memory warning before load

- Message: **Whisper Large v3 needs about 4.4 GB. You have 3.2 GB available.**
- Button: **Choose a smaller model**

### Unrecognized folder

- Section title: **Unrecognized model data**
- Body: **Scribe didn't put these here and doesn't use them.**
- Per row: folder name, size
- Actions: **Reveal in Finder** · **Move to Trash…**

### Unrecognized folder removal confirmation

- Title: **Move openai_whisper-small_216MB to Trash?**
- Body: **The 220 MB folder moves from your models folder to Trash, where it can
  be recovered. Recordings and transcripts are unaffected.**
- Buttons: **Move to Trash** · **Cancel**

## Summary providers and API keys

- Section: **Summary providers**
- Provider label: **Provider**
- Presets: **Anthropic** · **OpenAI** · **DeepSeek** · **Groq** · **Ollama** ·
  **LM Studio**
- API key label: **API key**
- Placeholder: **Paste API key**
- Helper: **Stored in your Keychain. Never written to disk or logs.**
- Stored state: **A key is stored in your Keychain.**
- Actions: **Test key** · **Remove key**
- Testing: **Testing…**
- Valid: **Key works**
- Missing: **No key provided.**
- Invalid: **That key was rejected. Check it hasn't expired.**
- Local keyless preset: **No API key needed. Requests stay on this Mac.**
- Keyless custom provider: **This provider does not require an API key.**
- Local connection action: **Test connection**
- Local connection valid: **Connection works**
- Local connection failure: **Scribe couldn't reach this provider. Check its
  address and that it is running.**

### Custom summary provider

- Actions: **Add custom provider** · **Custom provider**
- Fields: **Display name** · **Base URL** · **Model identifier**
- Toggle: **This provider uses an API key**
- Actions: **Save provider** · **Remove provider** · **Cancel**
- Saved: **Provider saved**
- Missing fields: **Enter a display name, base URL, and model identifier.**
- Invalid address: **Enter a valid provider base URL without credentials, a
  query, or a fragment.**
- Insecure address: **Remote providers must use HTTPS. HTTP is allowed only for
  localhost.**
- Save failure: **Scribe couldn't save this provider configuration. No API key
  was written to a settings file.**

## Settings

### Where sessions are saved

- Label: **Save recordings to**
- Value: **~/Documents/Scribe**
- Button: **Change**
- Helper: **Each session is a folder holding your audio, transcript, notes, and
  summary as ordinary files.**

### Session location unavailable

- Title: **Session folder unavailable**
- Body: **Reconnect the drive or server holding your session folder. Your
  indexed sessions remain listed and nothing has been deleted.**
- Buttons: **Try again** · **Choose another folder**

### Session folder access expired

- Message: **Scribe no longer has access to this session folder. Choose it
  again. Your recordings and transcripts are untouched.**

### Session index refresh failed

- Message: **Scribe couldn't refresh its session index. Session folders and
  their contents are untouched.**

### Copied session folder

- Informational message: **A copied session folder was added as a separate
  session. The original folder is unchanged.**

That sentence is doing real work. It tells the user their data isn't trapped in
the app, which is the main thing that separates this from every cloud
alternative.

## What not to write

- No “Oops” or “Uh oh”.
- No “Something went wrong” without saying what.
- No progress spinner without an estimate, wherever an estimate exists.
- No “Are you sure?” as a title. Name the thing being confirmed.
- No exclamation marks anywhere in system copy.
- No message about transcription that omits the recording's status.
