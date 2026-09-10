# Agent Log

## 2026-09-10 — v1.4.9: shortcut launch opened the app hidden

### Goal
Fix: clicking the desktop/Start-menu shortcut (or double-clicking the exe) opened the app hidden in the tray — the window only appeared after clicking the tray icon. Manual launches should always show the window; only the auto-start boot launch should honor "start minimized".

### Root cause
With `StartMinimized: true` (confirmed in the installed settings.json), every launch skipped `$win.Show()` — including manual launches from a shortcut. There was no way to distinguish a manual launch from the automatic Startup launch.

### Done
- `Launcher.cs`: when the app is not already running, it now appends `--show` to the script invocation unless `--autostart` was already passed; user-supplied args are forwarded. Version bumped to 1.4.9.
- `DailyTasks.ps1`: `$script:AutoStart = $args -contains '--autostart'` at top; window shown unless (`AutoStart` AND `StartMinimized`): `if (-not ($script:AutoStart -and $script:StartMinimized)) { $win.Show() }`.
- `Set-AutoStart` creates the Startup shortcut with `--autostart`; new `Ensure-AutoStartArgs` repairs existing Startup shortcuts created without args (called in `Init-App` after `Load-Settings`).
- `Show-MainWindow` reordered: restore from Minimized before Show/Activate.
- Rebuilt `DailyTasks.exe` (csc via build_setup.ps1, only the launcher step used); repo-root exe replaced.

### Files
- daily-tasks/Launcher.cs
- daily-tasks/DailyTasks.ps1
- daily-tasks/DailyTasks.exe (rebuilt)
- daily-tasks/CHANGELOG.md
- daily-tasks/docs/AGENT_LOG.md

### Tests
- PowerShell parser check: clean.
- Runspace harness mirroring the launcher's exact invocation: `--show` delivered on plain launch, `--autostart` passed as-is — passed. Show-decision matrix (AutoStart × StartMinimized → show/hide) — 4/4 passed.
- Confirmed the running installed instance holds the `DailyTasksApp_Show` event (launcher's already-running path works); the reported bug is the hidden-start path, fixed via `--show`.

### Status
Complete (code + docs + build). Local install update + manual verification left to the user (or on request).

---

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

---

## 2026-09-06 — v1.4.8: toast X button did not close the popup

### Goal
Fix: clicking the ✕ on a toast notification did not close it.

### Root cause
`Build-ToastWindow` wired the close button with `$closeBtn.Add_Click({ Close-Toast $win })`, capturing the function-local `$win` inside the delegate. PowerShell delegates do not reliably close over function locals — verified empirically: identical code closed the toast in 1 of ~4 harness runs (flaky), while every other toast handler (`בוצע`/`דחה`/rows) already used `$this` + `[Window]::GetWindow($this)`. With a dead `$win`, `Close-Toast` got `$null` and the silent try/catch swallowed the failure.

Also investigated (and ruled out as primary): RTL input-coordinate theory; multiple SendMessage/SendInput harnesses proved unreliable in a dot-sourced context and were abandoned.

### Done
- X button click now resolves the window from `$this`: `{ $w = [Window]::GetWindow($this); if ($null -ne $w) { Close-Toast $w } }` — same pattern as the working buttons.
- Defensive close on the toast content root: any `MouseLeftButtonDown` not handled by a functional button (done/snooze/task rows mark it handled) dismisses the toast — covers misrouted clicks that never reach the X.
- Version bump 1.4.7 → 1.4.8; CHANGELOG updated; repo-root mirrors re-synced.

### Files
- daily-tasks/DailyTasks.ps1
- daily-tasks/CHANGELOG.md
- daily-tasks/docs/AGENT_LOG.md
- Repo-root mirrors: DailyTasks.ps1, CHANGELOG.md

### Tests
- Deterministic harness raised the X `Click` and an unhandled header `MouseLeftButtonDown` across 6 rounds × 2 paths = 12/12 passed (pre-fix the X-Click path was flaky, failing most runs).
- Full-file PowerShell parser check after edits.

### Status
Complete; runtime verification of the real toast click left for the user.

---

## 2026-09-06 — v1.4.8 (extended): studio credit + first-run sample task

### Goal
1. Show in-app credit "נוצר על ידי לב טוב דיגיטל" linking to https://digital.levtov.uk/.
2. Seed one default sample task on first run: "הצטרפות לפורום העורכים התורניים" + https://editorforum.levtov.uk/.

### Done
- Settings popup footer: thin separator + credit line with a clickable `Hyperlink` (`CreditSiteLink`) resolved through `SettingsPopup.FindName` and opening the homepage via `Start-Process` (only wired if found).
- `Ensure-FirstRunSample`: adds the sample task only when the task list is empty AND a persisted flag (`SampleAdded` in settings.json) is unset, so it appears exactly once even after the user deletes it, and never for users who already have tasks. Sample: `Repeat='Once'`, `Date`=today, `Time`=now+30 min, `Notify=$false` (quiet by design — no surprise toasts).
- Flag persisted: default `$script:SampleAdded=$false` at top, read in `Load-Settings`, written in `Save-Settings`.
- Called in `Init-App` right after `Load-Tasks` (before missed-task detection / list render).
- Version stays 1.4.8 (unreleased toast-fix entry extended with these bullets); CHANGELOG updated.

### Files
- daily-tasks/DailyTasks.ps1
- daily-tasks/CHANGELOG.md
- daily-tasks/docs/AGENT_LOG.md
- Repo-root mirrors: DailyTasks.ps1, CHANGELOG.md

### Tests
- Full main-window XAML parsed via XamlReader (credit block + hyperlink resolve through the popup namescope).
- Seeding logic harness against temp files: 14/14 checks — sample added once, correct title/description/date/quiet flag, flag persisted across restart, not re-added after delete, not added for existing users.

### Status
Complete (code + docs); runtime visual check (credit in settings, sample in list) left for the user.
