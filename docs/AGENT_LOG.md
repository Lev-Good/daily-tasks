# Agent Log

## 2026-09-16 — v1.4.12: two UI bugs from the reminder toast and the edit dialog

### Goal
Two reports from the developer: (1) clicking an empty part of the floating reminder toast dismissed the reminder, which should never happen; (2) editing an existing task whose title is longer than the text field cut the text off instead of wrapping it onto more lines inside the field.

### Root cause
1. **Toast auto-dismiss on a stray click** — v1.4.8 fixed the dead ✕ handler and, as a "safety net" for misrouted input, added `$wrap.Add_MouseLeftButtonDown(...)` which called `Close-Toast` for *any* click the action buttons did not mark as handled. The ✕ handler alone (anchored via `$this` + `Window.GetWindow`) is the reliable close path the v1.4.8 investigation actually proved; the net only ever made the card disappear under a click on its header, its text row or its padding.
2. **Clipped title while editing** — each row in the task dialog was a horizontal `StackPanel` containing the title `TextBox`. A horizontal StackPanel measures children with unlimited width, and the TextBox had the default `TextWrapping = NoWrap`, so the box asked for the full single-line width of the text (measured: 748.6 px for the 103-character reported title) inside a card capped by `DlgCard MaxWidth="310"`. The card stayed 310 px and the overflow was clipped by the dialog ScrollViewer — exactly the cut-off text in the screenshot.

### Done
- `DailyTasks.ps1`: removed the toast's card-level `MouseLeftButtonDown` auto-close and left a NOTE explaining why it must not come back; the toast now closes only via ✕, `בוצע ✓` / `דחה` (which close after acting), and the auto-close timer after all rows are marked done. Version 1.4.11 -> 1.4.12.
- `DailyTasks.ps1`: `Add-DialogRow` now builds the row as a `Grid` (star column for the title + auto column for the remove button), sets `TextWrapping = 'Wrap'`, `AcceptsReturn = $false`, `MinLines = 1` on the title box and aligns the remove button to the top; the row-removal handler walks `$btn.Parent.Parent` instead of the old `$stack` naming. The row's `Children[0]`/`Children[1]` order and the save path's `boxes[0].Text` contract are unchanged, so `Show-TaskDialog` (existing title, hidden remove button, focus, save) needed no edits.
- `CHANGELOG.md`: v1.4.12 section (Hebrew) documenting both fixes, including that the v1.4.8 click-to-close behaviour was a regression and is gone.
- The released version is 1.4.12: `Launcher.cs` and `DailyTasks-Setup/SFX.cs` version metadata (assembly/file/informational + the `Version` const) bumped from 1.4.11 to 1.4.12 so the shipped launcher and installer report the same version as the app, the payload mirror `DailyTasks-Setup/` was re-synced from the repo root, and `build_setup.ps1` rebuilt both `DailyTasks-Setup/DailyTasks.exe` and `DailyTasks-Setup/DailyTasks-Setup.exe`; the rebuilt launcher was copied over the tracked repo-root `DailyTasks.exe`.

### Files
- daily-tasks/DailyTasks.ps1
- daily-tasks/Launcher.cs, daily-tasks/DailyTasks.exe (rebuilt)
- daily-tasks/DailyTasks-Setup/SFX.cs
- daily-tasks/CHANGELOG.md
- daily-tasks/DailyTasks-Setup/DailyTasks.ps1, Launcher.cs, DailyTasks.exe, DailyTasks-Setup.exe (gitignored payload mirror / build output)
- daily-tasks/docs/AGENT_LOG.md

### Tests
- PowerShell parser on the full script: clean (0 errors).
- Temporary harness that loads the REAL script with only the startup tail neutralized, then calls `Add-DialogRow` itself (the running user instance was kept out of the way by rewriting the two mutex/event names to test-only names; the harness file was deleted afterwards). Results, driven by real WPF `Measure`/`Arrange` on the dialog's actual card width (310 px):
  - row type `Grid`, 2 children, 2 column definitions; title box `TextWrapping=Wrap`, `AcceptsReturn=False`, `MinLines=1`.
  - 3-character title -> 242 x 36.6 px; the reported 103-character title -> 242 x 92.5 px (grew onto more lines) inside the same bounded width.
  - the same text needs 722.6 px on one line; the **old** structure (horizontal StackPanel, no wrapping) asked for 748.6 px inside the 310 px card and was clipped - the reported bug reproduced.
  - edit-existing-task path (remove button collapsed): box 310 x 73.9 px, i.e. two lines, and the save path still collects the full, untruncated title.
- Static check of the toast builder: no `$wrap.Add_MouseLeftButtonDown` remains in `Build-ToastWindow`, while the `$closeBtn` click handler is still wired.
- Not executed: clicking the real toast / typing in the real dialog (I cannot drive the user's live GUI from here) - the layout and wiring evidence above is what the harness could prove.
- Built installer checked before releasing: `DailyTasks.exe` and `DailyTasks-Setup.exe` both report FileVersion 1.4.12.0 / 1.4.12, and the embedded payload matches the synced copy (same hit counts for `MinLines`, `TextWrapping = 'Wrap'` and `Add-DialogRow`, and no `wrap.Add_MouseLeftButtonDown` anywhere) - i.e. the installer built from these sources embeds the fixed script, not a stale one. The published release artifact is verified separately below.

### Notes
- The user's app was running during this session and holds `Global\DailyTasksApp_Hebrew`, so the harness used test-only mutex/event names and never touched the live instance; a naive harness run silently loaded nothing (the app's single-instance guard calls `exit`) until the names were rewritten.
- The stale non-repo copy at the parent folder (`../DailyTasks.ps1`, still v1.4.10) was left untouched - updates are made in the git checkout.

### Release
- Commit `1f7d811` on `main` (6 files, 88 insertions), annotated tag `v1.4.12` pushed; the `Build and Release` workflow (run 35126223285) completed successfully and published `DailyTasks-Setup.exe` (381,952 bytes) + `DailyTasks-Setup.zip` (185,584 bytes), with the v1.4.12 `CHANGELOG.md` section as the release notes.
- Published artifact re-verified: the launcher shipped inside `DailyTasks-Setup.zip` is 1.4.12.0, its `DailyTasks.ps1` starts with `EF BB BF` (the UTF-8 BOM), is content-identical to HEAD and carries both fixes (`AppVersion = '1.4.12'`, `TextWrapping = 'Wrap'`, `MinLines`) with no `wrap.Add_MouseLeftButtonDown`; the downloaded `DailyTasks-Setup.exe` embeds the same payload (identical marker counts) - so the fix really reached the downloads, not just the source tree.
- The `Deploy Landing Page` workflow also ran green on the same push (landing page unchanged).

### Status
Released as v1.4.12 for all users. Clicking the real toast and typing in the real dialog in the user's own window remains the only unverified part (I cannot drive the live GUI from here).

---

## 2026-09-15 — v1.4.11: the new error reporter immediately found a real crash

### Goal
The developer installed v1.4.10 on their own machine and got a new error dialog ("You cannot call a method on a null-valued expression"). Diagnose and fix it.

### What the evidence showed
- `error.log` from the installed copy:
  `09:10:02 boot v1.4.10 args=[--show] ...` / `09:10:03 boot: window ready` / `09:10:04 Unhandled UI error: You cannot call a method on a null-valued expression.` with the stack running through `System.Windows.Threading.DispatcherTimer.FireTick`.
- Root cause: the entrance-animation failsafe timer captured a LOCAL variable (`$fs`) inside its tick delegate. PowerShell does not keep a function/handler local alive for a delegate that fires later, so `$fs.Stop()` was called on `$null` 500ms after the window loaded - on **every** launch. Until v1.4.10 the error was discarded by the launcher, which is why nobody ever saw it. Exactly the same class of bug as the toast X button from v1.4.8.
- The same defect existed in `Launch-Installer` (`$t.Stop()`): the 2-second timer of "install now" threw before `Exit-App`, so the app never quit to let the installer replace its files.
- A third bug was in the new error dialog itself: `MessageBox.Show(..., 'DefaultDesktopOnly', $opts)` passed a `MessageBoxOptions` value where a `MessageBoxDefaultButton` is expected, so the call threw and silently fell back to an LTR box with the English caption "DailyTasks error" (visible in the screenshot the user sent).

### Done
- `DailyTasks.ps1`: failsafe timer -> `$script:EntranceTimer`, installer-exit timer -> `$script:InstallExitTimer` (both stopped inside try/catch); `Show-FatalError` rewritten with the correct 6-argument overload, a typed `MessageBoxDefaultButton`, RTL options and a `$lead` parameter; the dispatcher-unhandled handler logs every error and shows the dialog only once per session (`$script:UiErrorShown`) with accurate wording. Version 1.4.11.
- `Launcher.cs`: the error dialog is now shown only when the window never came up (startup phase); errors logged after the window was ready go to `launcher.log` without nagging on exit. Version 1.4.11.
- Rebuilt launcher + installer, synced all mirrors.

### Files
- daily-tasks/DailyTasks.ps1
- daily-tasks/Launcher.cs
- daily-tasks/DailyTasks.exe (rebuilt)
- daily-tasks/DailyTasks-Setup/SFX.cs
- daily-tasks/CHANGELOG.md, daily-tasks/docs/AGENT_LOG.md

### Tests
- Parser check: clean.
- 9/9 end-to-end checks running the app from an isolated payload copy with test-only object names (the user's running instance was never touched): `boot v1.4.11` logged, `boot: window ready`, **no "Unhandled UI error"**, no fatal startup, `sounds/`, `settings.json` and `tasks.json` written, no `.tmp` left behind, instance closed. The crash that reproduced before the fix no longer appears.

### Notes
- Cold start on this machine takes ~5s from `boot` to `boot: window ready` (13 notification sounds are generated on first run) - not a bug, but the reason a first launch feels slow.
- The two users who reported "installed but never opens" have not sent a report yet; the BOM/ANSI finding remains the leading hypothesis and the diagnose tool is the way to confirm it.

### Release
- Commit `b45c83a` on `main` (6 files, 102 insertions), annotated tag `v1.4.11` pushed; `Build and Release` completed successfully and published `DailyTasks-Setup.exe` (380,416 bytes) + `DailyTasks-Setup.zip` (185,146 bytes).
- Published artifact re-verified: launcher inside is 1.4.11.0, `DailyTasks.ps1` starts with `EF BB BF` and is content-identical to HEAD, `diagnose.cmd` is present.

### Status
Fixed, released as v1.4.11.

---

## 2026-09-15 — v1.4.10: "installed fine but the app never opens" (silent-failure hardening)

### Goal
Two users reported that the latest installer installs successfully but the app never opens: no window, nothing in the taskbar, not even from the Start menu, and pausing the antivirus did not help. The reporter could not reproduce it on their own machine.

### Investigation (evidence, not guesses)
- Downloaded the published v1.4.9 assets from GitHub and extracted the SFX payload: `DailyTasks.ps1` is content-identical to HEAD (only CRLF vs LF), the embedded launcher is 1.4.9.0 and references `System.Management.Automation 3.0.0.0` from the GAC. The artifact that fails on those machines is the same one that works locally, so the variable is their environment.
- Found three silent-failure paths in the code:
  1. `Launcher.cs` never inspected `ps.Streams.Error` or `InvocationStateInfo`, so any script failure disappeared without a trace.
  2. The already-running branch (`Mutex.OpenExisting` -> signal the show event -> `return 0`) is a no-op for the user when the running instance is hung or an older build: no window and no taskbar entry.
  3. `SFX.cs` skipped locked files with `catch { }`, so installing while the app runs can leave an old `DailyTasks.exe` in place (mixed versions) with no notice at all.
- Reproduced a real bug from the installed machine's own `error.log`: `Save-Tasks: Exception calling "Replace" ... "The path is not of a legal form."`. `[IO.File]::Replace($tmp, $file, $null)` coerces `$null` to `""` for the [string] backup parameter. Verified with a PS 5.1 probe (fails with `$null`, succeeds with `[NullString]::Value`) - the atomic save had never worked.
- Most likely root cause of the two users' report, addressed defensively: `DailyTasks.ps1` had **no UTF-8 BOM**. Windows PowerShell 5.1 reads a BOM-less script using the machine's ANSI codepage, so on any machine whose ANSI codepage is not UTF-8 the Hebrew text and the whole XAML heredoc decode to mojibake and window creation fails before anything is visible. This dev machine runs the Windows UTF-8 beta codepage (`[Text.Encoding]::Default.WebName = utf-8`, seen in the diagnose report), which is exactly why the bug cannot be reproduced here.

### Done
- `DailyTasks.ps1`: UTF-8 BOM added; startup wrapped in try/catch that logs the failure and shows a Hebrew error dialog (`Show-FatalError`); `DispatcherUnhandledException` handler added; boot breadcrumb + leftover `.tmp` cleanup in `Init-App`; mutex creation guarded (the app still starts if single-instance is unavailable); the show-request handler now sets a `Global\DailyTasksApp_ShowAck` event so the launcher can verify a live instance; `Save-Tasks` uses `[NullString]::Value` with a copy+delete fallback. Version 1.4.10.
- `Launcher.cs`: logs every step to `%LOCALAPPDATA%\DailyTasks\launcher.log`; waits up to 3s for the ACK and, if the running instance does not answer, offers a restart and closes only instances running from its own install folder; checks that Windows PowerShell 5.1 (System.Management.Automation) is available and explains how to install it if not; captures the script error stream and shows the first error; detects an exit within 10s that never logged `boot: window ready` and reports it. Version 1.4.10.
- `DailyTasks-Setup/SFX.cs`: closes a running copy before copying (only the one running from the install folder), verifies every written file by size with one retry, writes `install.log`, shows an explicit partial-install dialog naming the failed files, and reports a failed launch.
- New `diagnose.cmd` (ASCII-only batch, CRLF): collects Windows/PowerShell/encoding/engine state, mutex state, file list + SHA256 hashes + Zone.Identifier, shortcuts, settings and log tails into `%LOCALAPPDATA%\DailyTasks\diagnose.txt`. Added to the Release workflow payload lists (both), `build_setup.ps1`, `SFX.cs` and `setup.ps1`; the installer also creates a "בדיקת תקינות" Start-menu shortcut.
- `README.txt` troubleshooting section, `.gitignore` (`sounds/`, the new build copy), rebuilt `DailyTasks.exe` + `DailyTasks-Setup.exe`.

### Files
- daily-tasks/Launcher.cs
- daily-tasks/DailyTasks.ps1
- daily-tasks/DailyTasks.exe (rebuilt)
- daily-tasks/DailyTasks-Setup/SFX.cs
- daily-tasks/DailyTasks-Setup/build_setup.ps1
- daily-tasks/diagnose.cmd (new)
- daily-tasks/setup.ps1, daily-tasks/README.txt, daily-tasks/.gitignore
- daily-tasks/.github/workflows/release.yml
- daily-tasks/CHANGELOG.md, daily-tasks/docs/AGENT_LOG.md

### Tests
- PowerShell parser check of the full script: clean.
- 20 structural checks (temporary harness, run via powershell.exe): BOM present, version, guards present, neutralized copy dot-sourced without starting a GUI, the complete main-window XAML loaded through `XamlReader`, `Save-Tasks` persisted a task with no `Save-Tasks` error logged and no `.tmp` left behind, `diagnose.cmd` present in the installer resources, launcher/installer assembly versions - all passed.
- 3 launcher behaviour cases using an isolated launcher build with test-only object names (so the running user app was untouched): (1) healthy instance answers with an ACK -> the second launch exits quietly; (2) stale instance that never answers -> detected and the user is offered a restart; (3) script that bails out instantly without reporting a ready window -> detected and reported. All passed.
- `diagnose.cmd` executed end-to-end on this machine: `diagnose.txt`, 8139 bytes, all sections populated.
- Note: the first structural run hung because the harness failed to neutralize the startup tail (indentation) and a real WPF window/message loop started; the stray `powershell.exe` was killed by PID and the harness now aborts before dot-sourcing if the tail is not neutralized.

### Issues observed but not addressed
- The installed app's `error.log` shows repeated `List drop: Exception calling "RemoveAt" ... "Collection was of a fixed size."` from the drag-reorder handler. Not related to this report, still open.
- The dev machine's installed copy came from the downloaded v1.4.9 release (CRLF payload), not from a local `setup.ps1` run - worth remembering when comparing local and released behaviour.
- The two affected users' machines could not be inspected directly; a `diagnose.txt` report from them is the next diagnostic step.

### Release
- Commit `c157c82` on `main` (12 files, 744 insertions), annotated tag `v1.4.10` pushed; the `Build and Release` workflow completed successfully and published `DailyTasks-Setup.exe` (378,880 bytes) + `DailyTasks-Setup.zip` (184,417 bytes).
- Verification of the published artifact: `diagnose.cmd` is included, the launcher inside is 1.4.10.0, and `DailyTasks.ps1` starts with `EF BB BF` (the UTF-8 BOM) and is content-identical to HEAD - i.e. the fix really shipped.
- Note: the tag was cut before this log entry existed, so the release notes come from the `CHANGELOG.md` section that shipped in `c157c82`.

### Status
Committed, tagged and released as v1.4.10. Root cause marked as very likely (BOM/ANSI), with the launcher now making any remaining failure visible and self-healing. Waiting on a `diagnose.txt` report from an affected machine (or on the fix simply working for them) to confirm.

---

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
