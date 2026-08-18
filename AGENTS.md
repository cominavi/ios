# Development Workflow

- Commit completed work incrementally without waiting for the user to request a
  commit explicitly. Keep each commit focused and leave coherent checkpoints as
  work progresses.
- After completing a feature, complete and verify its localization automatically
  before handing it off, using nearby translations and existing project
  terminology as the reference.
- When integrating branches, prefer rebasing over squash merging so the
  individual commit history is preserved. Only squash when the user explicitly
  requests it or the target repository requires it.
- Always use `gh attach` to upload screenshots of the relevant changed screens
  so reviewers can see the actual visual result. Place the attached images at
  the very top of the pull request description, before any summary or other
  content.
