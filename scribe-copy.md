# Scribe copy

This file inventories user-facing Scribe text that is easy to miss during
implementation reviews.

## Model storage and recovery

### Installed transcription model

- Action: **Move to Trash…**
- Confirmation title: **Move {model name} to Trash?**
- Confirm button: **Move to Trash**
- Message: **The model folder moves to Trash and can be recovered there.
  Recordings and transcripts are not affected.**

### Silero VAD

- Action: **Move to Trash…**
- Confirmation title: **Move Silero VAD to Trash?**
- Confirm button: **Move to Trash**
- Message: **The model folder moves to Trash and can be recovered there. Live
  speech detection will be unavailable until it is restored or installed
  again.**

### Unrecognized model folder

- Section title: **Unrecognized model data**
- Explanation: **These folders are not managed by the model catalogue. Review
  them before removing anything.**
- Action: **Move to Trash…**
- Confirmation title: **Move unrecognized model data to Trash?**
- Confirm button: **Move {folder name} to Trash**
- Message: **This moves the {size} folder to Trash, where it can be recovered.
  Recordings and transcripts are not affected.**

Moving a model folder to Trash removes it from Scribe's available storage and
disk total immediately. The user can restore the intact folder from macOS Trash
until Trash is emptied.
