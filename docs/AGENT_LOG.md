# Agent Log

## 2026-09-06 — v1.4.7: reschedule notification fix + sound picker

### Goal
1. Fix: editing a task's time after its original time passed never fired the new alert.
2. Add: notification sound picker (multiple pleasant chimes, preview) + volume control; pleasant default.

### Root cause (bug)
`On-Tick` skips tasks listed in `$script:NotifiedIds[today]`. Once a task's time passed (or app started after it — `Initialize-Notified` marks those), the id stayed in `NotifiedIds`, so editing the time to +2 minutes was silently skipped at the next tick.

### Done
- `Reset-TaskNotificationState`: removes id from `NotifiedIds[today]` and clears snooze; called from the detailed-task save action when time / remind-before / date actually changed (previous values captured before overwrite).
- `Get-SoundProfiles`: 13 locally synthesized chimes (Write-Chime → `sounds\<id>.wav`, generated on demand at startup via `Ensure-AllSounds`). New default `chime` ("פעמון עדין"); legacy chime kept as `default` profile.
- `Play-NotifySound` via WPF `MediaPlayer` (single persistent player, volume = NotifyVolume/100, fallback to SoundPlayer/SystemSounds). `Play-TaskSound` delegates to it; respects existing SoundEnabled toggle.
- Settings popup: sound combo + preview (play/stop toggle) + 0–100% volume slider with % label; persisted as `NotifySound`/`NotifyVolume` in settings.json; loaded values normalized.
- Version bump 1.4.6 → 1.4.7; CHANGELOG updated.
- No packaging changes: sounds are self-generated at first run, so release.yml / setup.ps1 / SFX.cs stay untouched; uninstaller already removes the whole install dir (incl. `sounds\`).

### Files
- daily-tasks/DailyTasks.ps1 (all code changes)
- daily-tasks/CHANGELOG.md
- daily-tasks/docs/AGENT_LOG.md (this file)
- Repo-root mirrors synced: DailyTasks.ps1, CHANGELOG.md

### Tests
- PowerShell language-parser syntax check on the edited script (see transcript result).
- Manual UI/runtime verification (toast + preview click) not executed in this session — WPF app; left for the user's next run.

### Status
Complete (code + docs); runtime verification pending user.
