# Development Workflow

- Commit completed work incrementally without waiting for the user to request a
  commit explicitly. Keep each commit focused and leave coherent checkpoints as
  work progresses.
- When integrating branches, prefer rebasing over squash merging so the
  individual commit history is preserved. Only squash when the user explicitly
  requests it or the target repository requires it.
