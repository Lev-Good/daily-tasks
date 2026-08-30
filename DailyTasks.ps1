Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

# Enable DPI awareness so the WPF window is crisp on high-DPI displays (must run before any window is created)
try {
    Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public static class DailyTasksDpi {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@ -ErrorAction Stop
    [void][DailyTasksDpi]::SetProcessDPIAware()
} catch {}

try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DailyTasksFullscreen {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@ -ErrorAction Stop
} catch {}

$mutex = New-Object System.Threading.Mutex($false, 'Global\DailyTasksApp_Hebrew')
if (-not $mutex.WaitOne(0, $false)) {
    try {
        $ev = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Global\DailyTasksApp_Show')
        [void]$ev.Set()
        $ev.Dispose()
    } catch {}
    exit
}

$script:DataFile = Join-Path $PSScriptRoot 'tasks.json'
$script:SettingsFile = Join-Path $PSScriptRoot 'settings.json'
$script:SoundEnabled = $true
$script:StartMinimized = $false
$script:ShowToastsFullscreen = $false
$script:Filter = 'today'
$script:MissedShown = $false
$script:Tasks = @()
$script:Snoozed = @{}
$script:OpenToasts = @()
$script:ToastHover = @{}
$script:DlgOverlay = $null
$script:DlgContent = $null
$script:DlgMsgContent = $null
$script:DlgMsgWasOpen = $false
$script:DlgFrame = $null
$script:DlgResult = $null
$script:DlgSaveAction = $null
$script:NotifiedIds = @{}
$script:NotifiedDate = ''
$script:LastMinute = ''
$script:Exiting = $false
$script:Tray = $null
$script:App = $null
$script:AppVersion = '1.4.3'
$script:UpdateUrl = 'https://api.github.com/repos/Lev-Good/daily-tasks/releases/latest'
$script:UpdateJob = $null
$script:UpdateTimer = $null
$script:UpdateChecking = $false
$script:UpdatePhase = 'idle'
$script:UpdateMsg = $null
$script:UpdateDlBtn = $null
$script:UpdateLaterBtn = $null
$script:DownloadJob = $null
$script:DownloadTimer = $null
$script:DownloadTarget = ''
$script:SoundPlayers = New-Object System.Collections.ArrayList

function Get-TodayStr {
    (Get-Date).ToString('yyyy-MM-dd')
}

function Get-Brush([string]$hex) {
    $hex = $hex.TrimStart('#')
    $r = [Convert]::ToByte($hex.Substring(0, 2), 16)
    $g = [Convert]::ToByte($hex.Substring(2, 2), 16)
    $b = [Convert]::ToByte($hex.Substring(4, 2), 16)
    return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb($r, $g, $b))
}

# Minimal error log for diagnostics (capped size)
function Write-Log([string]$msg) {
    try {
        $p = Join-Path $PSScriptRoot 'error.log'
        [System.IO.File]::AppendAllText($p, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $msg + [Environment]::NewLine)
        $fi = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
        if ($null -ne $fi -and $fi.Length -gt 262144) {
            $tail = Get-Content -LiteralPath $p -Tail 400
            [System.IO.File]::WriteAllLines($p, $tail, (New-Object System.Text.UTF8Encoding($false)))
        }
    } catch {}
}

# Safe time parsing: returns a TimeSpan or $null when the string is invalid (legacy/corrupt data)
function Get-TimeSpanSafe([string]$s) {
    $ts = [TimeSpan]::Zero
    if ([TimeSpan]::TryParse([string]$s, [ref]$ts)) { return $ts }
    return $null
}

function Load-Tasks {
    if (Test-Path -LiteralPath $script:DataFile) {
        try {
            $raw = [System.IO.File]::ReadAllText($script:DataFile, [System.Text.Encoding]::UTF8)
            # Note: ConvertFrom-Json on '[]' returns $null in Windows PowerShell 5.1,
            # so guard explicitly instead of wrapping the result in @().
            $parsed = $raw | ConvertFrom-Json
            if ($null -eq $parsed) {
                $script:Tasks = @()
            } else {
                $script:Tasks = @($parsed)
                foreach ($t in $script:Tasks) {
                    $comp = @{}
                    if ($null -ne $t.Completed) {
                        foreach ($p in $t.Completed.PSObject.Properties) { $comp[$p.Name] = [bool]$p.Value }
                    }
                    $t.Completed = $comp
                    if (-not $t.PSObject.Properties['RemindBefore']) { $t.RemindBefore = 0 }
                    if (-not $t.PSObject.Properties['Notify']) { $t.Notify = $true }
                    if (-not $t.PSObject.Properties['Sound']) { $t.Sound = $true }
                }
            }
        } catch {
            Write-Log ('Load-Tasks: ' + $_.Exception.Message)
            $script:Tasks = @()
        }
    }
}

function Save-Tasks {
    try {
        # Keep the full completion history so the streak counter is never cut short.
        $json = $script:Tasks | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($script:DataFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Log ('Save-Tasks: ' + $_.Exception.Message) }
}

function Load-Settings {
    if (Test-Path -LiteralPath $script:SettingsFile) {
        try {
            $s = Get-Content -LiteralPath $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $s -and $null -ne $s.Sound) { $script:SoundEnabled = [bool]$s.Sound }
            if ($null -ne $s -and $null -ne $s.StartMinimized) { $script:StartMinimized = [bool]$s.StartMinimized }
            if ($null -ne $s -and $null -ne $s.ShowToastsFullscreen) { $script:ShowToastsFullscreen = [bool]$s.ShowToastsFullscreen }
        } catch { Write-Log ('Load-Settings: ' + $_.Exception.Message) }
    }
}

function Save-Settings {
    try {
        $s = [pscustomobject]@{ Sound = [bool]$script:SoundEnabled; StartMinimized = [bool]$script:StartMinimized; ShowToastsFullscreen = [bool]$script:ShowToastsFullscreen }
        $json = $s | ConvertTo-Json
        [System.IO.File]::WriteAllText($script:SettingsFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Log ('Save-Settings: ' + $_.Exception.Message) }
}

function Find-TaskById([string]$id) {
    return @($script:Tasks | Where-Object { $_.Id -eq $id } | Select-Object -First 1)
}

function Write-Chime([string]$path, [double[]]$freqs, [double[]]$durs) {
    if (Test-Path -LiteralPath $path) { return }
    try {
        $rate = 44100
        $data = New-Object System.Collections.Generic.List[byte]
        function Add-Tone([double]$freq, [double]$dur) {
            $n = [int]($rate * $dur)
            for ($i = 0; $i -lt $n; $i++) {
                $atk = [math]::Min(1.0, ($i / ($rate * 0.012)))
                $rel = [math]::Min(1.0, (($n - $i) / ($rate * 0.03)))
                $env = $atk * $rel
                $v = [math]::Sin(2 * [math]::PI * $freq * $i / $rate) * 12000 * $env
                if ($v -gt 32767) { $v = 32767 }
                if ($v -lt -32768) { $v = -32768 }
                $b = [System.BitConverter]::GetBytes([int16]$v)
                $data.Add($b[0]); $data.Add($b[1])
            }
        }
        function Add-Gap([double]$dur) {
            $n = [int]($rate * $dur)
            for ($i = 0; $i -lt $n; $i++) { $data.Add(0); $data.Add(0) }
        }
        for ($i = 0; $i -lt $freqs.Count; $i++) {
            Add-Tone $freqs[$i] $durs[$i]
            if ($i -lt ($freqs.Count - 1)) { Add-Gap 0.04 }
        }
        $dataLen = $data.Count
        $ms = New-Object System.IO.MemoryStream
        $w = New-Object System.IO.BinaryWriter($ms)
        $w.Write([byte[]]@(0x52, 0x49, 0x46, 0x46))
        $w.Write([int32](36 + $dataLen))
        $w.Write([byte[]]@(0x57, 0x41, 0x56, 0x45))
        $w.Write([byte[]]@(0x66, 0x6D, 0x74, 0x20))
        $w.Write([int32]16)
        $w.Write([int16]1)
        $w.Write([int16]1)
        $w.Write([int32]$rate)
        $w.Write([int32]($rate * 2))
        $w.Write([int16]2)
        $w.Write([int16]16)
        $w.Write([byte[]]@(0x64, 0x61, 0x74, 0x61))
        $w.Write([int32]$dataLen)
        $w.Write($data.ToArray())
        $w.Flush()
        [System.IO.File]::WriteAllBytes($path, $ms.ToArray())
        $w.Dispose()
        $ms.Dispose()
    } catch {}
}

function Ensure-SoundFile {
    Write-Chime (Join-Path $PSScriptRoot 'sound.wav') @(880, 1318.51, 1567.98) @(0.12, 0.22, 0.35)
}

function Ensure-SuccessSound {
    Write-Chime (Join-Path $PSScriptRoot 'success.wav') @(523.25, 659.25, 783.99, 1046.5) @(0.09, 0.09, 0.09, 0.35)
}

function Play-WavFile([string]$path) {
    try {
        $p = New-Object System.Media.SoundPlayer($path)
        [void]$script:SoundPlayers.Add($p)
        $p.Play()
        # Sounds are short; keep only the most recent players to avoid an unbounded list.
        while ($script:SoundPlayers.Count -gt 5) {
            $old = $script:SoundPlayers[0]
            try { $old.Dispose() } catch {}
            $script:SoundPlayers.RemoveAt(0)
        }
    } catch {}
}

function Play-TaskSound {
    $wav = Join-Path $PSScriptRoot 'sound.wav'
    if (Test-Path -LiteralPath $wav) {
        Play-WavFile $wav
    } else {
        try { [System.Media.SystemSounds]::Exclamation.Play() } catch {}
    }
}

function Play-SuccessSound {
    $wav = Join-Path $PSScriptRoot 'success.wav'
    if (Test-Path -LiteralPath $wav) { Play-WavFile $wav }
}

function Get-Streak {
    $dailyTasks = @($script:Tasks | Where-Object { $_.Repeat -eq 'Daily' })
    if ($dailyTasks.Count -eq 0) { return 0 }
    $streak = 0
    for ($i = 0; $i -lt 365; $i++) {
        $dateStr = (Get-Date).Date.AddDays(-$i).ToString('yyyy-MM-dd')
        $allDone = $true
        foreach ($t in $dailyTasks) {
            if (-not $t.Completed.ContainsKey($dateStr)) { $allDone = $false; break }
        }
        if ($allDone) { $streak++ } else { break }
    }
    return $streak
}

function Get-StartupShortcut {
    Join-Path ([Environment]::GetFolderPath('Startup')) 'DailyTasks.lnk'
}

function Set-AutoStart([bool]$on) {
    try {
        $lnk = Get-StartupShortcut
        if ($on) {
            $ws = New-Object -ComObject WScript.Shell
            $sc = $ws.CreateShortcut($lnk)
            $runner = Join-Path $PSScriptRoot 'DailyTasks.exe'
            if (Test-Path -LiteralPath $runner) {
                $sc.TargetPath = $runner
                $sc.Arguments = ''
                $sc.IconLocation = "$runner,0"
            } else {
                $sc.TargetPath = 'powershell.exe'
                $sc.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSScriptRoot + '\DailyTasks.ps1"'
            }
            $sc.WorkingDirectory = $PSScriptRoot
            $sc.Description = 'משימות יומיות'
            $sc.Save()
        } else {
            if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
        }
    } catch {}
}

function Test-TodayTask($t) {
    $today = Get-TodayStr
    if ($t.Repeat -eq 'Once') { return $t.Date -eq $today }
    if ($t.Repeat -eq 'Weekly') { return $t.Days -contains [int](Get-Date).DayOfWeek }
    return $true
}

# Whether a task falls inside the date range of the active filter (Today / Tomorrow / Week / All)
function Test-InFilter($t, [datetime]$fromD, [datetime]$toD) {
    if ($t.Repeat -eq 'Daily') { return $true }
    if ($t.Repeat -eq 'Once') {
        if (-not $t.Date) { return $false }
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParseExact([string]$t.Date, 'yyyy-MM-dd', $null, 'None', [ref]$d)) { return $false }
        return ($d.Date -ge $fromD -and $d.Date -le $toD)
    }
    # Weekly: matches if any day in the range is one of the task's weekdays
    if ($fromD -eq [datetime]::MinValue) { return $true }
    $days = @($t.Days)
    if ($days.Count -eq 0) { return $false }
    $span = ($toD - $fromD).TotalDays
    for ($i = 0; $i -le $span; $i++) {
        if ($days -contains [int]$fromD.AddDays($i).DayOfWeek) { return $true }
    }
    return $false
}

function New-TaskView($t, $today, [bool]$isToday) {
    $letters = 'א','ב','ג','ד','ה','ו','ש'
    switch ($t.Repeat) {
        'Daily' { $repeatLabel = 'כל יום' }
        'Weekly' { $repeatLabel = ($t.Days | ForEach-Object { $letters[$_] }) -join ', ' }
        'Once' { $repeatLabel = 'חד-פעמי' }
        default { $repeatLabel = $t.Repeat }
    }
    $isDone = $t.Completed.ContainsKey($today)
    if ($isDone) {
        $timeBrush = '#10B981'; $timeLeft = 'הושלם היום'; $timeLeftBrush = '#10B981'
    } elseif ($isToday) {
        $ts = Get-TimeSpanSafe $t.Time
        if ($null -eq $ts) {
            $timeLeft = ''; $timeBrush = '#6B7280'; $timeLeftBrush = '#6B7280'
        } else {
            $tgt = [datetime]::Today.Add($ts)
            $diff = $tgt - (Get-Date)
            if ($diff.TotalSeconds -gt 0 -and $diff.TotalHours -ge 1) {
                $timeLeft = 'בעוד ' + [math]::Ceiling($diff.TotalHours) + ' שעות'
                $timeBrush = '#374151'; $timeLeftBrush = '#6B7280'
            } elseif ($diff.TotalSeconds -gt 0) {
                $min = [math]::Max(1, [int][math]::Ceiling($diff.TotalMinutes))
                $timeLeft = 'בעוד ' + $min + ' דקות'
                $timeBrush = '#374151'; $timeLeftBrush = '#6B7280'
            } else {
                $timeLeft = 'הגיע הזמן / באיחור'
                $timeBrush = '#EF4444'; $timeLeftBrush = '#EF4444'
            }
        }
    } else {
        $timeLeft = ''
        $timeBrush = '#6B7280'; $timeLeftBrush = '#6B7280'
    }
    return [pscustomobject]@{
        Id = $t.Id
        Title = $t.Title
        Description = $t.Description
        Time = $t.Time
        TimeDisplay = $t.Time
        TimeLeftText = $timeLeft
        TimeBrush = $timeBrush
        TimeLeftBrush = $timeLeftBrush
        RepeatDisplay = $repeatLabel
        BellVisibility = if ($t.Notify) { 'Visible' } else { 'Collapsed' }
        DescVisibility = if ($t.Description) { 'Visible' } else { 'Collapsed' }
        IsDone = $isDone
    }
}

function Get-TaskScrollViewer {
    try { return $script:TaskList.Template.FindName('PART_ScrollViewer', $script:TaskList) } catch { return $null }
}

function Refresh-List {
    if ($null -eq $script:TaskList) { return }
    try {
        $today = Get-TodayStr
        $nowDow = [int](Get-Date).DayOfWeek
        $todayD = (Get-Date).Date
        $fromD = $todayD; $toD = $todayD
        switch ($script:Filter) {
            'tomorrow' { $fromD = $todayD.AddDays(1); $toD = $fromD }
            'week' { $toD = $todayD.AddDays(6) }
            'all' { $fromD = [datetime]::MinValue; $toD = [datetime]::MaxValue }
        }
        $q = $script:SearchBox.Text.Trim().ToLower()
        $sv = Get-TaskScrollViewer
        $offset = 0.0
        if ($null -ne $sv) { $offset = $sv.VerticalOffset }
        $views = @()
        $totalToday = 0
        $doneToday = 0
        $orderIdx = 0
        foreach ($t in $script:Tasks) {
            $isToday = $true
            if ($t.Repeat -eq 'Once' -and $t.Date -ne $today) { $isToday = $false }
            elseif ($t.Repeat -eq 'Weekly' -and $t.Days -notcontains $nowDow) { $isToday = $false }
            if ($isToday) {
                $totalToday++
                if ($t.Completed.ContainsKey($today)) { $doneToday++ }
            }
            if (-not (Test-InFilter $t $fromD $toD)) { continue }
            if ($q) {
                $hay = ($t.Title + ' ' + $t.Description).ToLower()
                if (-not $hay.Contains($q)) { continue }
            }
            $v = New-TaskView $t $today $isToday
            $v | Add-Member -NotePropertyName OrderIndex -NotePropertyValue $orderIdx
            $views += $v
            $orderIdx++
        }
        # Done tasks sink to the bottom; within each group the order is the user's manual order (drag to reorder).
        $views = @($views | Sort-Object -Property @{Expression = { $_.IsDone }; Ascending = $true}, @{Expression = { $_.OrderIndex }; Ascending = $true})
        $script:TaskList.ItemsSource = [object[]]$views
        if ($null -ne $sv -and $script:TaskList.Items.Count -gt 0) {
            $sv.ScrollToVerticalOffset($offset)
        }
        $script:EmptyMsg.Visibility = if ($views.Count -eq 0) { 'Visible' } else { 'Collapsed' }
        $script:FilterSummary.Text = "$($views.Count) משימות מוצגות"
        $pct = if ($totalToday -gt 0) { [int](100 * $doneToday / $totalToday) } else { 0 }
        $script:HeroText.Text = if ($totalToday -gt 0) { "$doneToday מתוך $totalToday הושלמו" } else { 'אין משימות להיום' }
        $cur = [double]$script:HeroBar.Value
        if ([math]::Abs($cur - $pct) -gt 0.5) {
            $anim = New-Object System.Windows.Media.Animation.DoubleAnimation($cur, $pct, [TimeSpan]::FromMilliseconds(700))
            $ease = New-Object System.Windows.Media.Animation.QuadraticEase
            $ease.EasingMode = 'EaseOut'
            $anim.EasingFunction = $ease
            $script:HeroBar.BeginAnimation([System.Windows.Controls.Primitives.RangeBase]::ValueProperty, $anim)
        } else {
            $script:HeroBar.Value = $pct
        }
        $script:HeroPct.Text = "$pct%"
        $streak = Get-Streak
        $script:HeroStreak.Text = if ($streak -gt 0) { "רצף: $streak ימים" } else { '' }
        if ($totalToday -eq 0) { $script:HeroHint.Text = 'הוסיפו משימה ותתחילו לתכנן את היום' }
        elseif ($pct -eq 100) { $script:HeroHint.Text = 'כל המשימות הושלמו - יום מצוין!' }
        elseif ($pct -ge 50) { $script:HeroHint.Text = 'עבודה טובה - ממשיכים קדימה' }
        elseif ($doneToday -gt 0) { $script:HeroHint.Text = 'התחלה טובה - ממשיכים' }
        else { $script:HeroHint.Text = 'מתחילים את היום עם המשימות' }
    } catch { Write-Log ('Refresh-List: ' + $_.Exception.ToString()) }
}

function Handle-ListClick($s, $e) {
    $src = $e.OriginalSource
    while ($null -ne $src -and -not ($src -is [System.Windows.Controls.Primitives.ButtonBase])) {
        $src = [System.Windows.Media.VisualTreeHelper]::GetParent($src)
    }
    if ($null -eq $src) { return }
    $view = $src.DataContext
    if ($null -eq $view) { return }
    $t = Find-TaskById $view.Id
    if ($null -eq $t) { return }
    if ($src -is [System.Windows.Controls.CheckBox]) {
        if ($t.Completed.ContainsKey((Get-TodayStr))) { Mark-TaskDone $t.Id $false } else { Mark-TaskDone $t.Id $true }
        return
    }
    switch ($src.Name) {
        'EditCardBtn' { Show-TaskDialog $t }
        'DelCardBtn' {
            $r = Show-MessageDialog "למחוק את המשימה '$($t.Title)'?" 'מחיקת משימה' -Confirm
            if ($r -eq 'yes') {
                $script:Tasks = @($script:Tasks | Where-Object { $_.Id -ne $t.Id })
                Save-Tasks
                Refresh-List
            }
        }
    }
}

function Mark-TaskDone([string]$id, [bool]$done = $true, [switch]$Silent) {
    $t = Find-TaskById $id
    if ($null -eq $t) { return }
    $today = Get-TodayStr
    if ($done) {
        if (-not $t.Completed.ContainsKey($today)) { $t.Completed[$today] = $true }
    } else {
        if ($t.Completed.ContainsKey($today)) { $t.Completed.Remove($today) }
    }
    Save-Tasks
    if ($done -and -not $Silent) {
        $todayTasks = @($script:Tasks | Where-Object { Test-TodayTask $_ })
        if ($todayTasks.Count -gt 0) {
            $remaining = @($todayTasks | Where-Object { -not $_.Completed.ContainsKey($today) })
            if ($remaining.Count -eq 0) {
                Celebrate-Confetti 90 'כל המשימות הושלמו!' -Dim
                Play-SuccessSound
            } else {
                Celebrate-Confetti 20 ''
            }
        }
    }
    Refresh-List
}

function Add-DialogRow {
    $rowsPanel = $script:dlgRowsPanel
    if ($null -eq $rowsPanel) { return }
    if ($rowsPanel.Children.Count -ge 20) { return }
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.Margin = New-Object System.Windows.Thickness(0, 6, 0, 6)
    $row.HorizontalAlignment = 'Stretch'

    $titleBox = New-Object System.Windows.Controls.TextBox
    $titleBox.HorizontalAlignment = 'Stretch'
    $titleBox.FontSize = 14
    $titleBox.Padding = New-Object System.Windows.Thickness(10, 8, 10, 8)
    $titleBox.VerticalContentAlignment = 'Center'
    $titleBox.ToolTip = 'שם המשימה'

    $removeBtn = New-Object System.Windows.Controls.Button
    $removeBtn.Content = '✕'
    $removeBtn.Width = 26
    $removeBtn.Height = 26
    $removeBtn.FontSize = 11
    $removeBtn.VerticalAlignment = 'Center'
    $removeBtn.Margin = New-Object System.Windows.Thickness(6, 0, 0, 0)
    $removeBtn.Style = $script:IconBtnStyle
    $removeBtn.Add_Click({
        $btn = $_.Source
        $stack = $btn.Parent
        $panel = $stack.Parent
        $panel.Children.Remove($stack)
    })

    $row.Children.Add($titleBox) > $null
    $row.Children.Add($removeBtn) > $null
    $rowsPanel.Children.Add($row) > $null
}

function Show-TaskDialog($existing, [string]$initialTitle = '', [string]$initialTime = '') {
    if ($null -eq $script:DlgContent) { return }
    $script:DlgContent.Children.Clear()
    $script:DlgResult = $null
    $script:DlgSaveAction = $null

    $outer = New-Object System.Windows.Controls.StackPanel
    $outer.Margin = New-Object System.Windows.Thickness(0)
    $outer.HorizontalAlignment = 'Stretch'

    $header = New-Object System.Windows.Controls.TextBlock
    $header.Text = if ($null -eq $existing) { 'משימה חדשה' } else { 'עריכת משימה' }
    $header.FontSize = 21
    $header.FontWeight = 'Bold'
    $header.Foreground = Get-Brush '#111827'
    $header.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
    $outer.Children.Add($header) > $null

    $sub = New-Object System.Windows.Controls.TextBlock
    $sub.Text = 'הגדירו שעה והתראה, והוסיפו כמה משימות באותו זמן במידת הצורך'
    $sub.FontSize = 12
    $sub.Foreground = Get-Brush '#6B7280'
    $sub.Margin = New-Object System.Windows.Thickness(0, 0, 0, 18)
    $outer.Children.Add($sub) > $null

    $fieldsPanel = New-Object System.Windows.Controls.StackPanel
    $fieldsPanel.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)

    function Add-FieldV([string]$labelText, $control) {
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $labelText
        $lbl.FontSize = 13
        $lbl.FontWeight = 'SemiBold'
        $lbl.Foreground = Get-Brush '#374151'
        $lbl.Margin = New-Object System.Windows.Thickness(0, 10, 0, 2)
        $fieldsPanel.Children.Add($lbl) > $null
        $fieldsPanel.Children.Add($control) > $null
        return $lbl
    }

    $timeBox = New-Object System.Windows.Controls.TextBox
    if ($null -ne $existing) { $timeBox.Text = $existing.Time }
    elseif ($initialTime -and (Get-TimeSpanSafe $initialTime)) { $timeBox.Text = $initialTime }
    else { $timeBox.Text = (Get-Date).AddMinutes(30).ToString('HH:mm') }
    $timeBox.Width = 100
    $timeBox.FontSize = 15
    $timeBox.Padding = New-Object System.Windows.Thickness(8, 6, 8, 6)
    $timeBox.VerticalContentAlignment = 'Center'

    $repeatBox = New-Object System.Windows.Controls.ComboBox
    $repeatBox.Width = 140
    $repeatBox.FontSize = 14
    $repeatBox.Padding = New-Object System.Windows.Thickness(4)
    $repeatBox.Items.Add('כל יום') > $null
    $repeatBox.Items.Add('שבועי') > $null
    $repeatBox.Items.Add('חד-פעמי') > $null
    if ($null -ne $existing) {
        switch ($existing.Repeat) {
            'Daily' { $repeatBox.SelectedIndex = 0 }
            'Weekly' { $repeatBox.SelectedIndex = 1 }
            'Once' { $repeatBox.SelectedIndex = 2 }
            default { $repeatBox.SelectedIndex = 0 }
        }
    } else {
        $repeatBox.SelectedIndex = 2
    }

    $daysPanel = New-Object System.Windows.Controls.WrapPanel
    $daysPanel.Orientation = 'Horizontal'
    $daysPanel.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
    $daysPanel.Visibility = if ($repeatBox.SelectedIndex -eq 1) { 'Visible' } else { 'Collapsed' }
    $dayLabels = @('א', 'ב', 'ג', 'ד', 'ה', 'ו', 'ש')
    $dayChecks = @()
    for ($i = 0; $i -lt 7; $i++) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $dayLabels[$i]
        $cb.FontSize = 13
        $cb.Margin = New-Object System.Windows.Thickness(0, 0, 14, 0)
        $cb.Tag = $i
        if ($null -ne $existing -and $existing.Repeat -eq 'Weekly') {
            $cb.IsChecked = $existing.Days -contains $i
        } else {
            $cb.IsChecked = ($i -eq [int](Get-Date).DayOfWeek)
        }
        $dayChecks += $cb
        $daysPanel.Children.Add($cb) > $null
    }

    $onceDate = New-Object System.Windows.Controls.DatePicker
    $onceDate.Width = 150
    $onceDate.FontSize = 14
    $onceDate.SelectedDateFormat = 'Short'
    $onceDate.Visibility = if ($repeatBox.SelectedIndex -eq 2) { 'Visible' } else { 'Collapsed' }
    if ($null -ne $existing -and $existing.Repeat -eq 'Once' -and $existing.Date) {
        try { $onceDate.SelectedDate = [datetime]::ParseExact([string]$existing.Date, 'yyyy-MM-dd', $null) } catch {}
    }
    if ($null -eq $onceDate.SelectedDate) {
        $onceDate.SelectedDate = (Get-Date).Date
    }

    $notifyCheck = New-Object System.Windows.Controls.CheckBox
    $notifyCheck.Content = 'התראה'
    $notifyCheck.FontSize = 14
    $notifyCheck.IsChecked = $true
    if ($null -ne $existing) { $notifyCheck.IsChecked = $existing.Notify }

    $remindBox = New-Object System.Windows.Controls.ComboBox
    $remindBox.Width = 140
    $remindBox.FontSize = 14
    $remindBox.Items.Add('בזמן') > $null
    $remindBox.Items.Add('5 דקות לפני') > $null
    $remindBox.Items.Add('10 דקות לפני') > $null
    $remindBox.Items.Add('30 דקות לפני') > $null
    $remindBox.SelectedIndex = 0
    if ($null -ne $existing) {
        switch ($existing.RemindBefore) {
            0 { $remindBox.SelectedIndex = 0 }
            5 { $remindBox.SelectedIndex = 1 }
            10 { $remindBox.SelectedIndex = 2 }
            30 { $remindBox.SelectedIndex = 3 }
            default { $remindBox.SelectedIndex = 0 }
        }
    }

    Add-FieldV 'שעה' $timeBox

    Add-FieldV 'התראה' $notifyCheck

    Add-FieldV 'תזכורת' $remindBox

    Add-FieldV 'חזרה' $repeatBox

    $daysLabel = Add-FieldV 'ימים' $daysPanel

    $dateLabel = Add-FieldV 'תאריך' $onceDate

    function Update-RepeatRows {
        $daysPanel.Visibility = 'Collapsed'
        $onceDate.Visibility = 'Collapsed'
        $daysLabel.Visibility = 'Collapsed'
        $dateLabel.Visibility = 'Collapsed'
        switch ($repeatBox.SelectedIndex) {
            1 { $daysPanel.Visibility = 'Visible'; $daysLabel.Visibility = 'Visible' }
            2 { $onceDate.Visibility = 'Visible'; $dateLabel.Visibility = 'Visible' }
        }
    }
    Update-RepeatRows
    $repeatBox.Add_SelectionChanged({ Update-RepeatRows })

    $rowsLabel = New-Object System.Windows.Controls.TextBlock
    $rowsLabel.Text = 'משימות לביצוע'
    $rowsLabel.FontSize = 14
    $rowsLabel.FontWeight = 'SemiBold'
    $rowsLabel.Foreground = Get-Brush '#374151'
    $rowsLabel.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)
    $outer.Children.Add($rowsLabel) > $null

    $rowsPanel = New-Object System.Windows.Controls.StackPanel
    $rowsPanel.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
    $outer.Children.Add($rowsPanel) > $null
    $script:dlgRowsPanel = $rowsPanel

    $addRowBtn = New-Object System.Windows.Controls.Button
    $addRowBtn.Content = '+ הוספת משימה נוספת באותה שעה'
    $addRowBtn.FontSize = 13
    $addRowBtn.Padding = New-Object System.Windows.Thickness(12, 6, 12, 6)
    $addRowBtn.Background = Get-Brush '#EEF2FF'
    $addRowBtn.Foreground = Get-Brush '#4F46E5'
    $addRowBtn.BorderThickness = New-Object System.Windows.Thickness(0)
    $addRowBtn.Cursor = 'Hand'
    $addRowBtn.HorizontalAlignment = 'Left'
    $addRowBtn.Add_Click({ Add-DialogRow })
    $outer.Children.Add($addRowBtn) > $null

    $outer.Children.Add($fieldsPanel) > $null

    $btnBar = New-Object System.Windows.Controls.StackPanel
    $btnBar.Orientation = 'Horizontal'
    $btnBar.HorizontalAlignment = 'Right'
    $btnBar.Margin = New-Object System.Windows.Thickness(0, 22, 0, 0)

    $cancelBtn = New-Object System.Windows.Controls.Button
    $cancelBtn.Content = 'ביטול'
    $cancelBtn.Width = 110
    $cancelBtn.Height = 38
    $cancelBtn.FontSize = 14
    $cancelBtn.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
    $cancelBtn.Style = $script:SecondaryBtnStyle
    $cancelBtn.Add_Click({ Close-DialogOverlay })
    $btnBar.Children.Add($cancelBtn) > $null

    $saveBtn = New-Object System.Windows.Controls.Button
    $saveBtn.Content = if ($null -eq $existing) { 'הוספה' } else { 'שמירה' }
    $saveBtn.Width = 130
    $saveBtn.Height = 38
    $saveBtn.FontSize = 14
    $saveBtn.Style = $script:PrimaryBtnStyle
    $saveAction = {
        $timeStr = $timeBox.Text.Trim()
        if (-not ($timeStr -match '^\d{1,2}:\d{2}$') -or $null -eq (Get-TimeSpanSafe $timeStr)) {
            Show-MessageDialog 'נא להזין שעה תקינה בפורמט HH:MM' 'שגיאה'
            return
        }
        $titles = @()
        foreach ($child in $rowsPanel.Children) {
            $boxes = @()
            foreach ($c in $child.Children) { $boxes += $c }
            if ($boxes.Count -ge 1) {
                $tl = $boxes[0].Text.Trim()
                if ($tl) { $titles += $tl }
            }
        }
        if ($titles.Count -eq 0) {
            Show-MessageDialog 'נא להזין לפחות משימה אחת עם כותרת' 'שגיאה'
            return
        }
        if ($repeatBox.SelectedIndex -eq 1) {
            $selected = @($dayChecks | Where-Object { $_.IsChecked -eq $true } | ForEach-Object { [int]$_.Tag })
            if ($selected.Count -eq 0) {
                Show-MessageDialog 'נא לבחור לפחות יום אחד לחזרה שבועית' 'שגיאה'
                return
            }
        }
        $repeat = 'Daily'
        switch ($repeatBox.SelectedIndex) {
            1 { $repeat = 'Weekly' }
            2 { $repeat = 'Once' }
        }
        $remind = @(0, 5, 10, 30)[$remindBox.SelectedIndex]
        for ($i = 0; $i -lt $titles.Count; $i++) {
            $t = $null
            if ($null -ne $existing -and $i -eq 0) {
                $t = $existing
            } else {
                $t = [pscustomobject]@{
                    Id = [guid]::NewGuid().ToString()
                    Title = ''
                    Description = ''
                    Time = ''
                    Repeat = 'Once'
                    Days = @()
                    Date = ''
                    Notify = $false
                    Sound = $true
                    RemindBefore = 0
                    Completed = @{}
                }
            }
            $t.Title = $titles[$i]
            $t.Time = $timeStr
            $t.Repeat = $repeat
            if ($repeat -eq 'Weekly') { $t.Days = @($selected) }
            elseif ($repeat -eq 'Once') {
                if ($null -ne $onceDate.SelectedDate) { $t.Date = $onceDate.SelectedDate.ToString('yyyy-MM-dd') }
                else { $t.Date = (Get-TodayStr) }
            }
            $t.Notify = [bool]$notifyCheck.IsChecked
            $t.RemindBefore = $remind
            if ($null -eq $existing -or $i -gt 0) {
                $script:Tasks += $t
            }
        }
        Save-Tasks
        Refresh-List
        Close-DialogOverlay
    }
    $saveBtn.Add_Click($saveAction)
    $script:DlgSaveAction = $saveAction
    $btnBar.Children.Add($saveBtn) > $null
    $outer.Children.Add($btnBar) > $null

    $script:DlgContent.Children.Add($outer) > $null

    Add-DialogRow
    if ($null -ne $existing) {
        $r0 = $rowsPanel.Children[0]
        $r0.Children[0].Text = $existing.Title
        $r0.Children[1].Visibility = 'Collapsed'
    } elseif ($initialTitle) {
        $rowsPanel.Children[0].Children[0].Text = $initialTitle
    }

    $script:DlgOverlay.Visibility = 'Visible'
    try { $rowsPanel.Children[0].Children[0].Focus() } catch {}
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $script:DlgFrame = $frame
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    if ($script:DlgFrame -eq $frame) { $script:DlgFrame = $null }
}

function Add-QuickTask {
    $text = $script:QuickBox.Text.Trim()
    if (-not $text) { return }
    $timeMatch = [regex]::Match($text, '\b(\d{1,2}):(\d{2})\b')
    $title = ''
    $timeStr = ''
    if ($timeMatch.Success) {
        $timeStr = $timeMatch.Value
        $title = ($text.Substring(0, $timeMatch.Index) + ' ' + $text.Substring($timeMatch.Index + $timeMatch.Length)).Trim()
    } else {
        $title = $text
        $timeStr = (Get-Date).AddMinutes(30).ToString('HH:mm')
    }
    $title = ($title -replace '\s+', ' ').Trim()
    if (-not $title) { $title = $text }
    if (-not ($timeStr -match '^\d{1,2}:\d{2}$') -or $null -eq (Get-TimeSpanSafe $timeStr)) { $timeStr = (Get-Date).AddMinutes(30).ToString('HH:mm') }
    $t = [pscustomobject]@{
        Id = [guid]::NewGuid().ToString()
        Title = $title
        Description = ''
        Time = $timeStr
        Repeat = 'Once'
        Days = @()
        Date = (Get-TodayStr)
        Notify = $true
        Sound = $true
        RemindBefore = 0
        Completed = @{}
    }
    $script:Tasks += $t
    Save-Tasks
    Refresh-List
    $script:QuickBox.Clear()
}

function Celebrate-Confetti([int]$count, [string]$text, [switch]$Dim) {
    try {
        $target = $script:Window
        if ($null -eq $target -or -not $target.IsLoaded) {
            $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $left = [double]$wa.Left; $top = [double]$wa.Top; $width = [double]$wa.Width; $height = [double]$wa.Height
        } else {
            $left = $target.Left; $top = $target.Top
            $width = $target.ActualWidth; $height = $target.ActualHeight
        }
        if ($width -le 0 -or $height -le 0) {
            $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $left = [double]$wa.Left; $top = [double]$wa.Top; $width = [double]$wa.Width; $height = [double]$wa.Height
        }

        $win = New-Object System.Windows.Window
        $win.WindowStyle = 'None'
        $win.AllowsTransparency = $true
        $win.Background = [System.Windows.Media.Brushes]::Transparent
        $win.Topmost = $true
        $win.ShowInTaskbar = $false
        $win.ResizeMode = 'NoResize'
        $win.IsHitTestVisible = $false
        $win.Left = $left
        $win.Top = $top
        $win.Width = $width
        $win.Height = $height

        $root = New-Object System.Windows.Controls.Grid
        $win.Content = $root

        if ($Dim) {
            $overlay = New-Object System.Windows.Shapes.Rectangle
            $overlay.Fill = Get-Brush '#000000'
            $overlay.Opacity = 0
            $root.Children.Add($overlay) > $null
            $dimAnim = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 0.12, [TimeSpan]::FromMilliseconds(250))
            $overlay.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $dimAnim)
        }

        $canvas = New-Object System.Windows.Controls.Canvas
        $root.Children.Add($canvas) > $null

        $palette = @('#EF4444', '#F59E0B', '#10B981', '#3B82F6', '#8B5CF6', '#EC4899', '#FBBF24')
        $rnd = New-Object System.Random
        $parts = @()
        $n = [math]::Max(10, $count)
        for ($i = 0; $i -lt $n; $i++) {
            $rect = New-Object System.Windows.Shapes.Rectangle
            $wdt = 6 + $rnd.Next(6)
            $hgt = 8 + $rnd.Next(8)
            $rect.Width = $wdt
            $rect.Height = $hgt
            $rect.Fill = Get-Brush ($palette[$rnd.Next($palette.Count)])
            $rect.RadiusX = 2; $rect.RadiusY = 2
            $tr = New-Object System.Windows.Media.TranslateTransform
            $rt = New-Object System.Windows.Media.RotateTransform
            $grp = New-Object System.Windows.Media.TransformGroup
            $grp.Children.Add($rt) > $null
            $grp.Children.Add($tr) > $null
            $rect.RenderTransform = $grp
            $x = $rnd.NextDouble() * $width
            $y = -30 - $rnd.NextDouble() * 80
            [System.Windows.Controls.Canvas]::SetLeft($rect, $x)
            [System.Windows.Controls.Canvas]::SetTop($rect, $y)
            $canvas.Children.Add($rect) > $null
            $parts += [pscustomobject]@{
                Rect = $rect
                Tr = $tr
                Rt = $rt
                Vx = (($rnd.NextDouble() - 0.5) * 3)
                Vy = (2 + $rnd.NextDouble() * 3)
                Rot = (($rnd.NextDouble() - 0.5) * 12)
            }
        }

        $popText = $null
        if ($text) {
            $popText = New-Object System.Windows.Controls.TextBlock
            $popText.Text = $text
            $popText.FontSize = 34
            $popText.FontWeight = 'ExtraBold'
            $popText.Foreground = Get-Brush '#FFFFFF'
            $popText.HorizontalAlignment = 'Center'
            $popText.VerticalAlignment = 'Center'
            $popText.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
            $shad = New-Object System.Windows.Media.Effects.DropShadowEffect
            $shad.BlurRadius = 16
            $shad.ShadowDepth = 2
            $shad.Opacity = 0.7
            $shad.Color = [System.Windows.Media.Colors]::Black
            $popText.Effect = $shad
            $st = New-Object System.Windows.Media.ScaleTransform(0.6, 0.6, 0.5, 0.5)
            $popText.RenderTransform = $st
            $popText.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
            $root.Children.Add($popText) > $null
            $saX = New-Object System.Windows.Media.Animation.DoubleAnimation(0.6, 1.0, [TimeSpan]::FromMilliseconds(550))
            $saX.EasingFunction = New-Object System.Windows.Media.Animation.BackEase
            $saX.EasingFunction.EasingMode = 'EaseOut'
            $saX.EasingFunction.Amplitude = 1.5
            $saY = New-Object System.Windows.Media.Animation.DoubleAnimation(0.6, 1.0, [TimeSpan]::FromMilliseconds(550))
            $saY.EasingFunction = New-Object System.Windows.Media.Animation.BackEase
            $saY.EasingFunction.EasingMode = 'EaseOut'
            $saY.EasingFunction.Amplitude = 1.5
            $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $saX)
            $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $saY)
        }

        $win.Show()

        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(33)
        $timer.Tag = [pscustomobject]@{
            Parts = $parts
            Height = $height
            Win = $win
            Closed = $false
            Ticks = 0
        }
        $timer.Add_Tick({
            $t = $this
            $st2 = $t.Tag
            $st2.Ticks++
            foreach ($p in $st2.Parts) {
                $p.Tr.Y += $p.Vy
                $p.Tr.X += $p.Vx
                $p.Vy += 0.22
                if ($p.Vx -gt 0) { $p.Vx -= 0.02 } elseif ($p.Vx -lt 0) { $p.Vx += 0.02 }
                $p.Rt.Angle += $p.Rot
                if ($p.Tr.Y -gt $st2.Height + 40 -and $p.Rect.Opacity -gt 0) {
                    $p.Rect.Opacity = [math]::Max(0, $p.Rect.Opacity - 0.06)
                }
            }
            if ($st2.Ticks -ge 70) {
                $t.Stop()
                if (-not $st2.Closed) {
                    $st2.Closed = $true
                    try { $st2.Win.Close() } catch {}
                }
            }
        })
        $timer.Start()
        $win.Add_Closed({ try { $this.Tag.Stop() } catch {} })
    } catch {}
}

function Build-ToastWindow($data) {
    $win = New-Object System.Windows.Window
    if ($null -ne $script:Window) { $win.Owner = $script:Window }
    $win.WindowStyle = 'None'
    $win.AllowsTransparency = $true
    $win.Background = [System.Windows.Media.Brushes]::Transparent
    $win.Topmost = $true
    $win.ShowInTaskbar = $false
    $win.ResizeMode = 'NoResize'
    $win.SizeToContent = 'WidthAndHeight'
    $win.FlowDirection = 'RightToLeft'

    $wrap = New-Object System.Windows.Controls.Border
    $wrap.CornerRadius = New-Object System.Windows.CornerRadius(14)
    $wrap.Margin = New-Object System.Windows.Thickness(0)
    $wrap.BorderThickness = New-Object System.Windows.Thickness(1)
    $wrap.BorderBrush = Get-Brush '#E5E7EB'
    $wrap.Background = Get-Brush '#FFFFFF'
    $wrap.MaxWidth = 370
    $wrap.Padding = New-Object System.Windows.Thickness(18, 14, 18, 14)
    $shad = New-Object System.Windows.Media.Effects.DropShadowEffect
    $shad.BlurRadius = 28
    $shad.ShadowDepth = 6
    $shad.Direction = 90
    $shad.Opacity = 0.28
    $shad.Color = [System.Windows.Media.Colors]::Black
    $wrap.Effect = $shad

    $main = New-Object System.Windows.Controls.StackPanel
    # Emoji markers (bell, per-row checkmarks) stay invisible until the pointer
    # hovers the toast, then fade in so the message stays clean by default.
    $hoverEls = New-Object System.Collections.ArrayList

    $top = New-Object System.Windows.Controls.DockPanel
    $icon = New-Object System.Windows.Controls.TextBlock
    $icon.Text = '🔔'
    $icon.FontSize = 18
    $icon.Margin = New-Object System.Windows.Thickness(0, 0, 0, 0)
    $icon.VerticalAlignment = 'Center'
    $icon.Opacity = 0
    $null = $hoverEls.Add($icon)
    [System.Windows.Controls.DockPanel]::SetDock($icon, 'Right')
    $top.Children.Add($icon) > $null

    $closeBtn = New-Object System.Windows.Controls.Button
    $closeBtn.Content = '✕'
    $closeBtn.FontSize = 13
    $closeBtn.Width = 26
    $closeBtn.Height = 26
    $closeBtn.Margin = New-Object System.Windows.Thickness(6, 0, 10, 0)
    $closeBtn.Style = $script:IconBtnStyle
    $closeBtn.Tag = 'ToastClose'
    $closeBtn.Add_Click({ Close-Toast $win })
    [System.Windows.Controls.DockPanel]::SetDock($closeBtn, 'Left')
    $top.Children.Add($closeBtn) > $null

    $head = New-Object System.Windows.Controls.TextBlock
    $head.Text = $data.Header
    $head.FontSize = 15
    $head.FontWeight = 'Bold'
    $head.Foreground = Get-Brush '#111827'
    $head.VerticalAlignment = 'Center'
    $head.TextTrimming = 'CharacterEllipsis'
    $top.Children.Add($head) > $null
    $main.Children.Add($top) > $null

    if ($data.Display) {
        $disp = New-Object System.Windows.Controls.TextBlock
        $disp.Text = $data.Display
        $disp.FontSize = 12.5
        $disp.Foreground = Get-Brush '#6B7280'
        $disp.Margin = New-Object System.Windows.Thickness(0, 3, 0, 6)
        $disp.TextTrimming = 'CharacterEllipsis'
        $main.Children.Add($disp) > $null
    }

    $rowsPanel = New-Object System.Windows.Controls.StackPanel
    foreach ($row in $data.Rows) {
        $rb = New-Object System.Windows.Controls.Button
        $rb.Tag = 'ToastRowDone'
        $rb.HorizontalAlignment = 'Stretch'
        $rb.HorizontalContentAlignment = 'Stretch'
        $rb.Background = Get-Brush '#F3F4F6'
        $rb.Foreground = Get-Brush '#111827'
        $rb.BorderThickness = New-Object System.Windows.Thickness(0)
        $rb.Padding = New-Object System.Windows.Thickness(10, 7, 10, 7)
        $rb.Margin = New-Object System.Windows.Thickness(0, 3, 0, 3)
        $rb.Cursor = 'Hand'
        $rb.DataContext = [pscustomobject]@{ Id = $row.Id; Title = $row.Title }
        $rowPanel = New-Object System.Windows.Controls.StackPanel
        $rowPanel.Orientation = 'Horizontal'
        $checkTxt = New-Object System.Windows.Controls.TextBlock
        $checkTxt.Text = '☐'
        $checkTxt.FontSize = 13
        $checkTxt.Margin = New-Object System.Windows.Thickness(0, 0, 6, 0)
        $checkTxt.VerticalAlignment = 'Center'
        $checkTxt.Opacity = 0
        $null = $hoverEls.Add($checkTxt)
        $rowPanel.Children.Add($checkTxt) > $null
        $txt = New-Object System.Windows.Controls.TextBlock
        $txt.Text = $row.Title
        $txt.FontSize = 13
        $txt.FontWeight = 'SemiBold'
        $txt.TextTrimming = 'CharacterEllipsis'
        $txt.VerticalAlignment = 'Center'
        $rowPanel.Children.Add($txt) > $null
        $rb.Content = $rowPanel
        $rb.Add_Click({ Handle-RowDone $this })
        $rowsPanel.Children.Add($rb) > $null
    }
    if ($data.Rows.Count -gt 0) {
        $sep = New-Object System.Windows.Controls.Border
        $sep.Height = 1
        $sep.Background = Get-Brush '#E5E7EB'
        $sep.Margin = New-Object System.Windows.Thickness(0, 8, 0, 6)
        $main.Children.Add($sep) > $null
        $main.Children.Add($rowsPanel) > $null
    }

    $foot = New-Object System.Windows.Controls.StackPanel
    $foot.Orientation = 'Horizontal'
    $foot.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)

    if (-not $data.Multi) {
        $okBtn = New-Object System.Windows.Controls.Button
        $okBtn.Content = 'בוצע ✓'
        $okBtn.FontSize = 12.5
        $okBtn.FontWeight = 'Bold'
        $okBtn.Padding = New-Object System.Windows.Thickness(12, 5, 12, 5)
        $okBtn.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
        $okBtn.Cursor = 'Hand'
        $okBtn.Style = $script:PrimaryBtnStyle
        $okBtn.Tag = 'ToastOk'
        $okBtn.Add_Click({ $w = [System.Windows.Window]::GetWindow($this); Complete-AllFromToast $w })
        $foot.Children.Add($okBtn) > $null
    }

    if ($data.Multi) {
        $allBtn = New-Object System.Windows.Controls.Button
        $allBtn.Content = 'השלם הכל ✓'
        $allBtn.FontSize = 12.5
        $allBtn.FontWeight = 'Bold'
        $allBtn.Padding = New-Object System.Windows.Thickness(12, 5, 12, 5)
        $allBtn.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
        $allBtn.Cursor = 'Hand'
        $allBtn.Style = $script:PrimaryBtnStyle
        $allBtn.Tag = 'ToastDoneAll'
        $allBtn.Add_Click({ $w = [System.Windows.Window]::GetWindow($this); Complete-AllFromToast $w })
        $foot.Children.Add($allBtn) > $null
    }

    $sn5 = New-Object System.Windows.Controls.Button
    $sn5.Content = 'דחה 5 דקות'
    $sn5.FontSize = 12.5
    $sn5.Padding = New-Object System.Windows.Thickness(12, 5, 12, 5)
    $sn5.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
    $sn5.Cursor = 'Hand'
    $sn5.Style = $script:SecondaryBtnStyle
    $sn5.Add_Click({ $w = [System.Windows.Window]::GetWindow($this); Snooze-Toast $w 5 })
    $foot.Children.Add($sn5) > $null

    $sn30 = New-Object System.Windows.Controls.Button
    $sn30.Content = 'דחה 30 דקות'
    $sn30.FontSize = 12.5
    $sn30.Padding = New-Object System.Windows.Thickness(12, 5, 12, 5)
    $sn30.Cursor = 'Hand'
    $sn30.Style = $script:SecondaryBtnStyle
    $sn30.Add_Click({ $w = [System.Windows.Window]::GetWindow($this); Snooze-Toast $w 30 })
    $foot.Children.Add($sn30) > $null

    $main.Children.Add($foot) > $null
    $wrap.Child = $main
    $win.Content = $wrap

    $script:ToastHover[$wrap] = $hoverEls
    $wrap.Add_MouseEnter({
        foreach ($el in $script:ToastHover[$this]) {
            $el.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
            $el.Opacity = 1
        }
    })
    $wrap.Add_MouseLeave({
        foreach ($el in $script:ToastHover[$this]) {
            $el.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
            $el.Opacity = 0
        }
    })

    $anim = New-Object System.Windows.Media.TranslateTransform(0, 30)
    $wrap.RenderTransform = $anim
    $wrap.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
    $wrap.Opacity = 0
    $wrap.Tag = $anim
    $win.Add_Loaded({
        $content = $this.Content
        $trans = $content.Tag
        $op = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 1, [TimeSpan]::FromMilliseconds(260))
        $op.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase
        $op.EasingFunction.EasingMode = 'EaseOut'
        $content.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $op)
        $mv = New-Object System.Windows.Media.Animation.DoubleAnimation(30, 0, [TimeSpan]::FromMilliseconds(320))
        $mv.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase
        $mv.EasingFunction.EasingMode = 'EaseOut'
        $trans.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $mv)
        Reposition-Toasts
    })
    $win.Add_Closed({ Handle-ToastClosed $this })
    return $win
}

function Reposition-Toasts {
    try {
        # Show toasts on the screen where the mouse currently is (multi-monitor support).
        $scr = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
        $wa = $scr.WorkingArea
        $margin = 18.0
        $total = 0.0
        foreach ($w in @($script:OpenToasts)) {
            if ($null -eq $w -or -not $w.IsVisible) { continue }
            $w.UpdateLayout()
            $h = [math]::Max(60.0, $w.ActualHeight)
            $w.Left = $wa.Right - $w.ActualWidth - $margin
            $w.Top = $wa.Bottom - $h - $margin - $total
            $total += $h + 12
        }
    } catch {}
}

# A fullscreen window is defined as the foreground window covering the entire
# bounds of its screen (video players, games, presentations, etc.).
function Test-FullscreenActive {
    try {
        $h = [DailyTasksFullscreen]::GetForegroundWindow()
        if ($h -eq [IntPtr]::Zero) { return $false }
        $r = New-Object DailyTasksFullscreen+RECT
        [void][DailyTasksFullscreen]::GetWindowRect($h, [ref]$r)
        $scr = [System.Windows.Forms.Screen]::FromHandle([IntPtr]$h)
        if ($null -eq $scr) { return $false }
        $b = $scr.Bounds
        return ($r.Left -le $b.Left -and $r.Top -le $b.Top -and $r.Right -ge $b.Right -and $r.Bottom -ge $b.Bottom)
    } catch {
        return $false
    }
}

function Show-Toast($win) {
    if (-not $script:ShowToastsFullscreen -and (Test-FullscreenActive)) {
        Write-Log 'Show-Toast: fullscreen app active, notification suppressed'
        try { if ($win.IsVisible) { $win.Close() } } catch {}
        return
    }
    $script:OpenToasts += $win
    $null = $win.Show()
}

function Close-Toast($win) {
    try { if ($win.IsVisible) { $win.Close() } } catch {}
}

function Handle-ToastClosed($win) {
    $script:OpenToasts = @($script:OpenToasts | Where-Object { $_ -ne $win })
    if ($null -ne $win.Content) { $script:ToastHover.Remove($win.Content) }
    Reposition-Toasts
}

function Snooze-Toast($win, [int]$minutes) {
    $data = $win.Tag
    $ids = @($data.TaskIds)
    $today = Get-TodayStr
    foreach ($id in $ids) {
        $t = Find-TaskById $id
        if ($null -eq $t) { continue }
        if ($t.Completed.ContainsKey($today)) { continue }
        $script:Snoozed[$id] = (Get-Date).AddMinutes($minutes)
        if ($script:NotifiedIds.ContainsKey($today)) {
            $script:NotifiedIds[$today] = @($script:NotifiedIds[$today] | Where-Object { $_ -ne $id })
        }
    }
    Close-Toast $win
}

function Complete-AllFromToast($win) {
    $data = $win.Tag
    $ids = @($data.TaskIds)
    $firstDone = $false
    foreach ($id in $ids) {
        $t = Find-TaskById $id
        if ($null -eq $t) { continue }
        if ($t.Completed.ContainsKey((Get-TodayStr))) { continue }
        Mark-TaskDone $id $true -Silent
        if (-not $firstDone) { $firstDone = $true }
    }
    if ($firstDone) {
        $todayTasks = @($script:Tasks | Where-Object { Test-TodayTask $_ })
        $remaining = @($todayTasks | Where-Object { -not $_.Completed.ContainsKey((Get-TodayStr)) })
        if ($remaining.Count -eq 0) {
            Celebrate-Confetti 90 'כל המשימות הושלמו!' -Dim
            Play-SuccessSound
        } else {
            Celebrate-Confetti 25 ''
        }
    }
    Close-Toast $win
}

function Show-Notifications([object[]]$taskList) {
    if ($null -eq $taskList -or $taskList.Count -eq 0) { return }
    $today = Get-TodayStr
    $ids = @()
    $shouldSound = $false
    foreach ($t in $taskList) {
        $ids += $t.Id
        $shouldSound = $script:SoundEnabled
        if (-not $script:NotifiedIds.ContainsKey($today)) { $script:NotifiedIds[$today] = @() }
        if ($script:NotifiedIds[$today] -notcontains $t.Id) {
            $script:NotifiedIds[$today] = @($script:NotifiedIds[$today]) + $t.Id
        }
    }
    if ($taskList.Count -eq 1) {
        $one = $taskList[0]
        $disp = $one.Time
        if ($one.Description) { $disp = $one.Time + ' • ' + $one.Description }
        $data = [pscustomobject]@{
            Header = $one.Title
            Display = $disp
            Rows = @()
            Multi = $false
            TaskIds = @($one.Id)
            DoneCount = 0
        }
    } else {
        $sorted = @($taskList | Sort-Object -Property Time)
        $rows = @()
        foreach ($t in $sorted) {
            $rows += [pscustomobject]@{ Id = $t.Id; Title = $t.Title }
        }
        $data = [pscustomobject]@{
            Header = ($sorted.Count.ToString() + ' משימות מחכות')
            Display = 'הגיע הזמן' + ' • ' + $sorted[0].Time
            Rows = @($rows)
            Multi = $true
            TaskIds = @($sorted.Id)
            DoneCount = 0
        }
    }
    $win = Build-ToastWindow $data
    $win.Tag = $data
    Show-Toast $win
    if ($shouldSound) { Play-TaskSound }
}

function Handle-RowDone($rb) {
    try {
        $row = $rb.DataContext
        if ($null -eq $row) { return }
        $t = Find-TaskById $row.Id
        if ($null -eq $t) { return }
        if ($t.Completed.ContainsKey((Get-TodayStr))) { return }
        Mark-TaskDone $t.Id $true -Silent
        $rb.IsEnabled = $false
        $rb.Opacity = 0.55
        $txt = $rb.Content
        if ($txt -is [System.Windows.Controls.TextBlock]) {
            $txt.Text = '✓ ' + $row.Title
            $txt.Foreground = Get-Brush '#10B981'
        }
        $win = [System.Windows.Window]::GetWindow($rb)
        $data = $win.Tag
        $data.DoneCount++
        $todayTasks = @($script:Tasks | Where-Object { Test-TodayTask $_ })
        $remaining = @($todayTasks | Where-Object { -not $_.Completed.ContainsKey((Get-TodayStr)) })
        if ($remaining.Count -eq 0) {
            Celebrate-Confetti 90 'כל המשימות הושלמו!' -Dim
            Play-SuccessSound
        } else {
            Celebrate-Confetti 14 ''
        }
        if ($data.Multi -and $data.DoneCount -ge $data.TaskIds.Count) {
            $closeTimer = New-Object System.Windows.Threading.DispatcherTimer
            $closeTimer.Interval = [TimeSpan]::FromMilliseconds(700)
            $closeTimer.Tag = $win
            $closeTimer.Add_Tick({
                $ct = $this
                $ct.Stop()
                Close-Toast $ct.Tag
            })
            $closeTimer.Start()
        }
    } catch {}
}

function On-Tick {
    if ($script:Exiting) { return }
    try {
        $now = Get-Date
        $today = Get-TodayStr
        $cut = $now.AddMinutes(-0.5)
        $expired = @()
        foreach ($k in @($script:Snoozed.Keys)) {
            if ($script:Snoozed[$k] -le $cut) {
                $expired += $k
            }
        }
        foreach ($id in $expired) {
            $script:Snoozed.Remove($id)
            if ($script:NotifiedIds.ContainsKey($today)) {
                $script:NotifiedIds[$today] = @($script:NotifiedIds[$today] | Where-Object { $_ -ne $id })
            }
        }
        $due = @()
        $nowDow = [int]$now.DayOfWeek
        foreach ($t in $script:Tasks) {
            $isToday = $false
            if ($t.Repeat -eq 'Once') { $isToday = ($t.Date -eq $today) }
            elseif ($t.Repeat -eq 'Weekly') { $isToday = ($t.Days -contains $nowDow) }
            else { $isToday = $true }
            if (-not $isToday) { continue }
            if (-not $t.Notify) { continue }
            if ($t.Completed.ContainsKey($today)) { continue }
            if ($script:Snoozed.ContainsKey($t.Id)) { continue }
            if ($script:NotifiedIds.ContainsKey($today) -and $script:NotifiedIds[$today] -contains $t.Id) { continue }
            $ts = Get-TimeSpanSafe $t.Time
            if ($null -eq $ts) { continue }
            $target = [datetime]::Today.Add($ts)
            if ($t.RemindBefore -gt 0) { $target = $target.AddMinutes(-$t.RemindBefore) }
            if ($now -ge $target) {
                $due += $t
            }
        }
        if ($due.Count -gt 0) {
            Show-Notifications $due
        }
        # Keep the "בעוד X דקות" counters fresh without losing the scroll position.
        if ($script:Window.IsVisible) { Refresh-List }
    } catch { Write-Log ('On-Tick: ' + $_.Exception.ToString()) }
}

function Initialize-Notified {
    $today = Get-TodayStr
    $nowDow = [int](Get-Date).DayOfWeek
    $now = Get-Date
    $already = @()
    foreach ($t in $script:Tasks) {
        $isToday = $false
        if ($t.Repeat -eq 'Once') { $isToday = ($t.Date -eq $today) }
        elseif ($t.Repeat -eq 'Weekly') { $isToday = ($t.Days -contains $nowDow) }
        else { $isToday = $true }
        if (-not $isToday) { continue }
        if (-not $t.Notify) { continue }
        if ($t.Completed.ContainsKey($today)) { continue }
        $ts = Get-TimeSpanSafe $t.Time
        if ($null -eq $ts) { continue }
        $target = [datetime]::Today.Add($ts)
        if ($t.RemindBefore -gt 0) { $target = $target.AddMinutes(-$t.RemindBefore) }
        if ($now -ge $target) { $already += $t.Id }
    }
    if ($already.Count -gt 0) {
        $script:NotifiedIds[$today] = @($already)
    }
    # Return the missed ids so the caller can surface a "missed tasks" toast.
    return @($already)
}

# Reorders a task by moving it one position in the list (drag & drop / keyboard order)
function Move-Task([string]$id, [int]$delta) {
    $idx = -1
    for ($i = 0; $i -lt $script:Tasks.Count; $i++) {
        if ($script:Tasks[$i].Id -eq $id) { $idx = $i; break }
    }
    if ($idx -lt 0) { return }
    $newIdx = $idx + $delta
    if ($newIdx -lt 0 -or $newIdx -ge $script:Tasks.Count) { return }
    $item = $script:Tasks[$idx]
    $script:Tasks.RemoveAt($idx)
    $script:Tasks.Insert($newIdx, $item)
    Save-Tasks
    Refresh-List
}

function Find-ListBoxItemAt($list, [System.Windows.Point]$pos) {
    try {
        $hit = [System.Windows.Media.VisualTreeHelper]::HitTest($list, $pos)
        if ($null -eq $hit) { return $null }
        $d = $hit.VisualHit
        while ($null -ne $d -and -not ($d -is [System.Windows.Controls.ListBoxItem])) {
            $d = [System.Windows.Media.VisualTreeHelper]::GetParent($d)
        }
        return $d
    } catch { return $null }
}

# Drag & drop to reorder tasks (the manual order is kept by Refresh-List)
function Enable-ListDragReorder {
    $script:TaskList.AllowDrop = $true
    $script:DragStartPoint = $null
    $script:TaskList.Add_PreviewMouseLeftButtonDown({
        $script:DragStartPoint = $_.GetPosition($script:TaskList)
    })
    $script:TaskList.Add_PreviewMouseMove({
        if ($_.LeftButton -eq 'Pressed' -and $null -ne $script:DragStartPoint) {
            $pos = $_.GetPosition($script:TaskList)
            $diff = $pos - $script:DragStartPoint
            if ([math]::Abs($diff.X) -gt 6 -or [math]::Abs($diff.Y) -gt 6) {
                $item = Find-ListBoxItemAt $script:TaskList $pos
                if ($null -ne $item -and $null -ne $item.DataContext -and $null -ne $item.DataContext.Id) {
                    $script:DragStartPoint = $null
                    [void][System.Windows.DragDrop]::DoDragDrop($script:TaskList, [string]$item.DataContext.Id, [System.Windows.DragDropEffects]::Move)
                }
            }
        }
    })
    $script:TaskList.Add_DragOver({
        $_.Effects = [System.Windows.DragDropEffects]::Move
        $_.Handled = $true
    })
    $script:TaskList.Add_Drop({
        try {
            $id = $_.Data.GetData([string])
            if ($null -eq $id) { return }
            $pos = $_.GetPosition($script:TaskList)
            $target = Find-ListBoxItemAt $script:TaskList $pos
            if ($null -eq $target -or $null -eq $target.DataContext -or $null -eq $target.DataContext.Id) { return }
            if ([string]$target.DataContext.Id -eq [string]$id) { return }
            $srcIdx = -1; $dstIdx = -1
            for ($i = 0; $i -lt $script:Tasks.Count; $i++) {
                if ($script:Tasks[$i].Id -eq [string]$id) { $srcIdx = $i }
                if ($script:Tasks[$i].Id -eq [string]$target.DataContext.Id) { $dstIdx = $i }
            }
            if ($srcIdx -lt 0 -or $dstIdx -lt 0 -or $srcIdx -eq $dstIdx) { return }
            $item = $script:Tasks[$srcIdx]
            $script:Tasks.RemoveAt($srcIdx)
            if ($dstIdx -gt $srcIdx) { $dstIdx-- }
            $script:Tasks.Insert($dstIdx, $item)
            Save-Tasks
            Refresh-List
        } catch { Write-Log ('List drop: ' + $_.Exception.Message) }
    })
}

# Toast shown once when the app starts after tasks were missed while it was closed.
function Show-MissedToast([string[]]$ids) {
    if ($script:MissedShown) { return }
    $script:MissedShown = $true
    if ($null -eq $ids -or $ids.Count -eq 0) { return }
    try {
        $tasks = @()
        foreach ($id in $ids) {
            $t = Find-TaskById $id
            if ($null -ne $t) { $tasks += $t }
        }
        if ($tasks.Count -eq 0) { return }
        $rows = @()
        foreach ($t in $tasks) { $rows += [pscustomobject]@{ Id = $t.Id; Title = $t.Title } }
        $data = [pscustomobject]@{
            Header = ($tasks.Count.ToString() + ' משימות שהוחמצו')
            Display = 'הגיע הזמן בזמן שהתוכנה הייתה סגורה'
            Rows = @($rows)
            Multi = $true
            TaskIds = @($tasks.Id)
            DoneCount = 0
        }
        $win = Build-ToastWindow $data
        $win.Tag = $data
        Show-Toast $win
    } catch { Write-Log ('Show-MissedToast: ' + $_.Exception.Message) }
}

function Get-StyleFromXaml([string]$xaml) {
    $pc = New-Object System.Windows.Markup.ParserContext
    $pc.XmlnsDictionary.Add('', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
    $pc.XmlnsDictionary.Add('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
    return [System.Windows.Markup.XamlReader]::Parse($xaml, $pc)
}

function New-SharedStyles {
    $script:PrimaryBtnStyle = Get-StyleFromXaml @'
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Button">
  <Setter Property="Foreground" Value="#FFFFFF"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="BorderThickness" Value="0"/>
  <Setter Property="Padding" Value="14,7"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="#4F46E5" CornerRadius="8" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#4338CA"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#3730A3"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.5"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
'@
    $script:SecondaryBtnStyle = Get-StyleFromXaml @'
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Button">
  <Setter Property="Foreground" Value="#374151"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="BorderThickness" Value="1"/>
  <Setter Property="Padding" Value="14,7"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="#FFFFFF" BorderBrush="#D1D5DB" CornerRadius="8" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#F3F4F6"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#E5E7EB"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
'@
    $script:IconBtnStyle = Get-StyleFromXaml @'
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Button">
  <Setter Property="Foreground" Value="#6B7280"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Background" Value="Transparent"/>
  <Setter Property="BorderThickness" Value="0"/>
  <Setter Property="Padding" Value="6,4"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="#00000000" CornerRadius="6" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#E5E7EB"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#D1D5DB"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
'@
}

function Test-NewerVersion([string]$tag) {
    $tag = $tag -replace '^[vV]', ''
    $cur = @($script:AppVersion -split '\.')
    $new = @($tag -split '\.')
    for ($i = 0; $i -lt [Math]::Max($cur.Count, $new.Count); $i++) {
        $a = 0; $b = 0
        if ($i -lt $cur.Count) { [void][int]::TryParse(($cur[$i] -replace '\D', ''), [ref]$a) }
        if ($i -lt $new.Count) { [void][int]::TryParse(($new[$i] -replace '\D', ''), [ref]$b) }
        if ($b -gt $a) { return $true }
        if ($b -lt $a) { return $false }
    }
    return $false
}

function Start-UpdateCheck([switch]$Manual) {
    if ($script:UpdateChecking) { return }
    $script:UpdateChecking = $true
    try {
        $script:UpdateJob = Start-Job -ScriptBlock {
            param($url)
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $r = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'DailyTasks-UpdateChecker' } -TimeoutSec 12
                $asset = $r.assets | Where-Object { $_.name -eq 'DailyTasks-Setup.exe' } | Select-Object -First 1
                if ($null -eq $asset) { $asset = $r.assets | Where-Object { $_.name -match 'Setup.*\.exe$' } | Select-Object -First 1 }
                if ($null -eq $asset) { return $null }
                return @{
                    Tag  = [string]$r.tag_name
                    Down = [string]$asset.browser_download_url
                }
            } catch { return $null }
        } -ArgumentList $script:UpdateUrl
    } catch {
        $script:UpdateChecking = $false
        if ($Manual) { [void](Show-MessageDialog 'לא ניתן היה לבדוק עדכונים. בדקו את חיבור האינטרנט ונסו שוב.' 'בדיקת עדכונים') }
        return
    }
    if ($null -eq $script:UpdateTimer) {
        $script:UpdateTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:UpdateTimer.Interval = [TimeSpan]::FromSeconds(1)
        $script:UpdateTimer.Add_Tick({ Complete-UpdateCheck })
    }
    $script:UpdateTimer.Start()
}

function Complete-UpdateCheck {
    if ($null -eq $script:UpdateJob) { return }
    if ($script:UpdateJob.State -ne 'Completed' -and $script:UpdateJob.State -ne 'Failed') { return }
    $job = $script:UpdateJob
    $script:UpdateJob = $null
    try { $script:UpdateTimer.Stop() } catch {}
    $script:UpdateChecking = $false
    $info = $null
    try { $info = @(Receive-Job -Job $job) | Select-Object -First 1 } catch { $info = $null }
    try { Remove-Job -Job $job -Force } catch {}
    if ($null -eq $info -or [string]::IsNullOrWhiteSpace([string]$info.Tag)) { return }
    if (Test-NewerVersion ([string]$info.Tag)) {
        Show-UpdateDialog $info
    }
}

function Close-UpdateDialog([string]$result) {
    $script:DlgResult = $result
    try { $script:DlgMsgContent.Visibility = 'Collapsed' } catch {}
    if (-not $script:DlgMsgWasOpen) { try { $script:DlgOverlay.Visibility = 'Collapsed' } catch {} }
    if ($null -ne $script:DlgFrame) { $script:DlgFrame.Continue = $false; $script:DlgFrame = $null }
}

function Show-UpdateDialog($info) {
    if ($null -eq $script:DlgMsgContent) { return }
    $script:DlgMsgWasOpen = ($script:DlgOverlay.Visibility -eq 'Visible')
    $script:DlgMsgContent.Children.Clear()
    $script:DlgResult = 'no'
    $script:DlgSaveAction = $null
    $script:UpdatePhase = 'idle'
    $script:DlgMsgContent.Visibility = 'Visible'

    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $script:DlgFrame = $frame

    $stack = New-Object System.Windows.Controls.StackPanel

    $head = New-Object System.Windows.Controls.TextBlock
    $head.Text = '🔄 עדכון זמין'
    $head.FontSize = 17
    $head.FontWeight = 'Bold'
    $head.Foreground = Get-Brush '#111827'
    $head.Margin = New-Object System.Windows.Thickness(0, 0, 0, 10)
    $stack.Children.Add($head) > $null

    $msg = New-Object System.Windows.Controls.TextBlock
    $msg.Text = "קיימת גרסה חדשה: $($info.Tag)`nהגרסה הנוכחית שלך: $($script:AppVersion)`n`nרוצים להוריד ולהתקין אותה עכשיו?"
    $msg.FontSize = 14
    $msg.Foreground = Get-Brush '#374151'
    $msg.TextWrapping = 'Wrap'
    $msg.MaxWidth = 430
    $stack.Children.Add($msg) > $null
    $script:UpdateMsg = $msg

    $bar = New-Object System.Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'
    $bar.HorizontalAlignment = 'Right'
    $bar.Margin = New-Object System.Windows.Thickness(0, 18, 0, 0)

    $laterBtn = New-Object System.Windows.Controls.Button
    $laterBtn.Content = 'לא עכשיו'
    $laterBtn.Width = 100
    $laterBtn.Height = 36
    $laterBtn.FontSize = 13
    $laterBtn.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
    $laterBtn.Style = $script:SecondaryBtnStyle
    $laterBtn.Add_Click({
        if ($script:UpdatePhase -ne 'downloading') { Close-UpdateDialog 'no' }
    })
    $bar.Children.Add($laterBtn) > $null

    $dlBtn = New-Object System.Windows.Controls.Button
    $dlBtn.Content = 'הורד והתקן'
    $dlBtn.Width = 130
    $dlBtn.Height = 36
    $dlBtn.FontSize = 13
    $dlBtn.Style = $script:PrimaryBtnStyle
    $dlBtn.Add_Click({
        if ($script:UpdatePhase -eq 'idle') {
            $script:UpdatePhase = 'downloading'
            $script:UpdateDlBtn.IsEnabled = $false
            $script:UpdateLaterBtn.IsEnabled = $false
            $script:UpdateMsg.Text = 'מורידים את הגרסה החדשה... זה עלול לקחת כמה רגעים.'
            Start-UpdateDownload ([string]$info.Down)
        } elseif ($script:UpdatePhase -eq 'ready') {
            Close-UpdateDialog 'install'
        }
    })
    $bar.Children.Add($dlBtn) > $null

    $script:UpdateDlBtn = $dlBtn
    $script:UpdateLaterBtn = $laterBtn

    $stack.Children.Add($bar) > $null
    $script:DlgMsgContent.Children.Add($stack) > $null

    $script:DlgOverlay.Visibility = 'Visible'
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    if ($script:DlgFrame -eq $frame) { $script:DlgFrame = $null }
    if ($script:DlgResult -eq 'install') { Launch-Installer }
}

function Start-UpdateDownload([string]$url) {
    if ([string]::IsNullOrWhiteSpace($url)) {
        $script:UpdatePhase = 'failed'
        if ($null -ne $script:UpdateMsg) { $script:UpdateMsg.Text = 'קישור ההורדה לא נמצא. הורידו ידנית מדף המהדורות באתר.' }
        if ($null -ne $script:UpdateDlBtn) { $script:UpdateDlBtn.IsEnabled = $false }
        if ($null -ne $script:UpdateLaterBtn) { $script:UpdateLaterBtn.Content = 'סגירה'; $script:UpdateLaterBtn.IsEnabled = $true }
        return
    }
    $target = Join-Path ([System.IO.Path]::GetTempPath()) 'DailyTasks-Setup.exe'
    $script:DownloadTarget = $target
    try {
        $script:DownloadJob = Start-Job -ScriptBlock {
            param($u, $t)
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $u -OutFile $t -UseBasicParsing -UserAgent 'DailyTasks-Update' -TimeoutSec 300
                return (Test-Path -LiteralPath $t)
            } catch { return $false }
        } -ArgumentList $url, $target
    } catch {
        $script:UpdatePhase = 'failed'
        if ($null -ne $script:UpdateMsg) { $script:UpdateMsg.Text = 'ההורדה נכשלה. נסו שוב מאוחר יותר או הורידו ידנית מדף המהדורות.' }
        if ($null -ne $script:UpdateDlBtn) { $script:UpdateDlBtn.IsEnabled = $false }
        if ($null -ne $script:UpdateLaterBtn) { $script:UpdateLaterBtn.Content = 'סגירה'; $script:UpdateLaterBtn.IsEnabled = $true }
        return
    }
    if ($null -eq $script:DownloadTimer) {
        $script:DownloadTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:DownloadTimer.Interval = [TimeSpan]::FromSeconds(1)
        $script:DownloadTimer.Add_Tick({ Complete-UpdateDownload })
    }
    $script:DownloadTimer.Start()
}

function Complete-UpdateDownload {
    if ($null -eq $script:DownloadJob) { return }
    if ($script:DownloadJob.State -ne 'Completed' -and $script:DownloadJob.State -ne 'Failed') { return }
    $job = $script:DownloadJob
    $script:DownloadJob = $null
    try { $script:DownloadTimer.Stop() } catch {}
    $ok = $false
    try { $ok = [bool](Receive-Job -Job $job) } catch { $ok = $false }
    try { Remove-Job -Job $job -Force } catch {}
    if ($ok -and (Test-Path -LiteralPath $script:DownloadTarget)) {
        $script:UpdatePhase = 'ready'
        if ($null -ne $script:UpdateMsg) { $script:UpdateMsg.Text = 'ההורדה הושלמה! לחצו "התקן עכשיו" כדי להתקין את הגרסה החדשה.' }
        if ($null -ne $script:UpdateDlBtn) { $script:UpdateDlBtn.Content = 'התקן עכשיו'; $script:UpdateDlBtn.IsEnabled = $true }
        if ($null -ne $script:UpdateLaterBtn) { $script:UpdateLaterBtn.IsEnabled = $true }
    } else {
        $script:UpdatePhase = 'failed'
        if ($null -ne $script:UpdateMsg) { $script:UpdateMsg.Text = 'ההורדה נכשלה. נסו שוב מאוחר יותר, או הורידו ידנית מדף המהדורות באתר.' }
        if ($null -ne $script:UpdateDlBtn) { $script:UpdateDlBtn.IsEnabled = $false }
        if ($null -ne $script:UpdateLaterBtn) { $script:UpdateLaterBtn.Content = 'סגירה'; $script:UpdateLaterBtn.IsEnabled = $true }
    }
}

function Launch-Installer {
    $exe = $script:DownloadTarget
    if (-not (Test-Path -LiteralPath $exe)) { return }
    try { Start-Process -FilePath $exe } catch {}
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(2)
    $t.Add_Tick({
        $t.Stop()
        Exit-App
    })
    $t.Start()
}

function Show-MessageDialog([string]$message, [string]$title, [switch]$Confirm) {
    if ($null -eq $script:DlgMsgContent) { return 'no' }
    $script:DlgMsgWasOpen = ($script:DlgOverlay.Visibility -eq 'Visible')
    $script:DlgMsgContent.Children.Clear()
    $script:DlgResult = 'no'
    $script:DlgMsgContent.Visibility = 'Visible'

    $head = New-Object System.Windows.Controls.TextBlock
    $head.Text = $title
    $head.FontSize = 17
    $head.FontWeight = 'Bold'
    $head.Foreground = Get-Brush '#111827'
    $head.Margin = New-Object System.Windows.Thickness(0, 0, 0, 10)
    $script:DlgMsgContent.Children.Add($head) > $null

    $msg = New-Object System.Windows.Controls.TextBlock
    $msg.Text = $message
    $msg.FontSize = 14
    $msg.Foreground = Get-Brush '#374151'
    $msg.TextWrapping = 'Wrap'
    $msg.MaxWidth = 430
    $script:DlgMsgContent.Children.Add($msg) > $null

    $bar = New-Object System.Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'
    $bar.HorizontalAlignment = 'Right'
    $bar.Margin = New-Object System.Windows.Thickness(0, 18, 0, 0)

    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $script:DlgFrame = $frame

    if ($Confirm) {
        $cancelBtn = New-Object System.Windows.Controls.Button
        $cancelBtn.Content = 'ביטול'
        $cancelBtn.Width = 92
        $cancelBtn.Height = 36
        $cancelBtn.FontSize = 13
        $cancelBtn.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
        $cancelBtn.Style = $script:SecondaryBtnStyle
        $cancelBtn.Add_Click({
            $script:DlgResult = 'no'
            $script:DlgMsgContent.Visibility = 'Collapsed'
            if (-not $script:DlgMsgWasOpen) { $script:DlgOverlay.Visibility = 'Collapsed' }
            $frame.Continue = $false
        })
        $bar.Children.Add($cancelBtn) > $null

        $okBtn = New-Object System.Windows.Controls.Button
        $okBtn.Content = 'מחיקה'
        $okBtn.Width = 92
        $okBtn.Height = 36
        $okBtn.FontSize = 13
        $okBtn.Style = $script:PrimaryBtnStyle
        $okBtn.Add_Click({
            $script:DlgResult = 'yes'
            $script:DlgMsgContent.Visibility = 'Collapsed'
            if (-not $script:DlgMsgWasOpen) { $script:DlgOverlay.Visibility = 'Collapsed' }
            $frame.Continue = $false
        })
        $bar.Children.Add($okBtn) > $null
    } else {
        $okBtn = New-Object System.Windows.Controls.Button
        $okBtn.Content = 'אישור'
        $okBtn.Width = 92
        $okBtn.Height = 36
        $okBtn.FontSize = 13
        $okBtn.Style = $script:PrimaryBtnStyle
        $okBtn.Add_Click({
            $script:DlgResult = 'ok'
            $script:DlgMsgContent.Visibility = 'Collapsed'
            if (-not $script:DlgMsgWasOpen) { $script:DlgOverlay.Visibility = 'Collapsed' }
            $frame.Continue = $false
        })
        $bar.Children.Add($okBtn) > $null
    }

    $script:DlgMsgContent.Children.Add($bar) > $null

    $script:DlgOverlay.Visibility = 'Visible'
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    if ($script:DlgFrame -eq $frame) { $script:DlgFrame = $null }
    return $script:DlgResult
}

function Close-DialogOverlay {
    try { if ($null -ne $script:DlgOverlay) { $script:DlgOverlay.Visibility = 'Collapsed' } } catch {}
    try { if ($null -ne $script:DlgContent) { $script:DlgContent.Children.Clear() } } catch {}
    $script:DlgSaveAction = $null
    $script:DlgResult = $null
    if ($null -ne $script:DlgFrame) { $script:DlgFrame.Continue = $false; $script:DlgFrame = $null }
}

$script:MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
        Title="משימות יומיות"
        Width="360" Height="700" MinWidth="320" MinHeight="500"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        WindowStartupLocation="Manual" ResizeMode="CanResize"
        FlowDirection="RightToLeft"
        FontFamily="Segoe UI"
        shell:WindowChrome.WindowChrome="{shell:WindowChrome CaptionHeight=34, ResizeBorderThickness=6, CornerRadius=14, GlassFrameThickness=0, UseAeroCaptionButtons=False}">
  <Window.Resources>
    <Style TargetType="TextBox">
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="BorderBrush" Value="#D1D5DB"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#111827"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="2,1,2,1" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#9CA3AF"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#4F46E5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#374151"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal">
              <Border x:Name="box" Width="20" Height="20" CornerRadius="6" Background="#FFFFFF" BorderBrush="#C7CBD1" BorderThickness="1.5" VerticalAlignment="Center">
                <Path x:Name="check" Data="M 3,10.5 L 7,14.5 L 16,5.5" Stroke="#4F46E5" StrokeThickness="2.2"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                      Visibility="Collapsed" FlowDirection="LeftToRight"/>
              </Border>
              <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="#EEF2FF"/>
                <Setter TargetName="box" Property="BorderBrush" Value="#4F46E5"/>
                <Setter TargetName="check" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="box" Property="BorderBrush" Value="#4F46E5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="TaskCheckStyle" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="26" Height="26">
              <Ellipse x:Name="bg" Fill="Transparent"/>
              <TextBlock x:Name="glyph" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="16"
                         Foreground="#C4CBD4" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="glyph" Property="Foreground" Value="#8B93A3"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bg" Property="Fill" Value="#D1FAE5"/>
                <Setter TargetName="glyph" Property="Foreground" Value="#10B981"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Focusable="False" Opacity="0"/>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Focusable="False">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border x:Name="thumb" Background="#C9CDD4" CornerRadius="5" Margin="2"/>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="thumb" Property="Background" Value="#9CA3AF"/></Trigger>
                          <Trigger Property="IsDragging" Value="True"><Setter TargetName="thumb" Property="Background" Value="#6B7280"/></Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Focusable="False" Opacity="0"/>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FilterStyle" TargetType="Button">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#374151"/>
      <Setter Property="Padding" Value="14,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#F3F4F6"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#E5E7EB"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#4F46E5"/><Setter TargetName="bd" Property="BorderThickness" Value="1.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryBtnStyle" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="#4F46E5" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#4338CA"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#3730A3"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#A5B4FC"/><Setter TargetName="bd" Property="BorderThickness" Value="1.5"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="IconBtnStyle" TargetType="Button">
      <Setter Property="Foreground" Value="#6B7280"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="#00000000" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#E5E7EB"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#D1D5DB"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#4F46E5"/><Setter TargetName="bd" Property="BorderThickness" Value="1.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ToggleBtnStyle" TargetType="ToggleButton">
      <Setter Property="Foreground" Value="#374151"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="14,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#F3F4F6"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#E5E7EB"/></Trigger>
              <Trigger Property="IsChecked" Value="True"><Setter TargetName="bd" Property="Background" Value="#E0E7FF"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#4F46E5"/><Setter TargetName="bd" Property="BorderThickness" Value="1.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border CornerRadius="14" Background="#F7F8FC" BorderBrush="#E5E7EB" BorderThickness="1" Padding="0">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0" Margin="18,9,18,6">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,0,0">
          <Border Width="30" Height="30" CornerRadius="9" Background="#EEF2FF" VerticalAlignment="Center" Margin="0,0,8,0">
            <Image x:Name="AppIconImg" Width="18" Height="18" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
          </Border>
          <TextBlock Text="משימות יומיות" FontSize="16" FontWeight="Bold" Foreground="#111827" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center"
                    shell:WindowChrome.IsHitTestVisibleInChrome="True">
          <Button x:Name="SoundBtn" Content="&#xE767;" FontFamily="Segoe MDL2 Assets" Width="34" Height="30" Margin="0,0,5,0" FontSize="15" Padding="0" Style="{StaticResource FilterStyle}" ToolTip="צליל התראות: מופעל"/>
          <Button x:Name="MinBtn" Content="&#xE921;" FontFamily="Segoe MDL2 Assets" Width="34" Height="30" Margin="0,0,5,0" FontSize="14" Padding="0" Style="{StaticResource FilterStyle}" ToolTip="מזעור"/>
          <Button x:Name="CloseBtn" Content="&#xE711;" FontFamily="Segoe MDL2 Assets" Width="34" Height="30" FontSize="14" Padding="0" Foreground="#6B7280" Style="{StaticResource FilterStyle}" ToolTip="סגירה למגש"/>
        </StackPanel>
      </Grid>

      <Border Grid.Row="1" Margin="16,0,16,14" CornerRadius="16" Padding="20,16">
        <Border.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#6366F1" Offset="0"/>
            <GradientStop Color="#8B5CF6" Offset="1"/>
          </LinearGradientBrush>
        </Border.Background>
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock x:Name="TopDate" Text="" FontSize="12" Foreground="#C7D2FE" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
          <Grid Grid.Row="1" Margin="0,6,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
              <TextBlock Text="היום" FontSize="12.5" Foreground="#C7D2FE" FontWeight="SemiBold"/>
              <TextBlock x:Name="HeroText" Text="0 מתוך 0 הושלמו" FontSize="22" FontWeight="Bold" Foreground="#FFFFFF" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
              <TextBlock x:Name="HeroStreak" Text="" FontSize="12" Foreground="#C7D2FE" Margin="0,3,0,0"/>
            </StackPanel>
            <TextBlock x:Name="HeroPct" Grid.Column="1" Text="0%" FontSize="36" FontWeight="ExtraBold" Foreground="#FFFFFF" VerticalAlignment="Center" Opacity="0.92"/>
          </Grid>
          <Grid Grid.Row="2" Margin="0,12,0,0">
            <Border Background="#40FFFFFF" CornerRadius="6" Height="12"/>
            <ProgressBar x:Name="HeroBar" Height="12" Minimum="0" Maximum="100" Value="0">
              <ProgressBar.Template>
                <ControlTemplate TargetType="ProgressBar">
                  <Grid>
                    <Border x:Name="PART_Track" Background="#40FFFFFF" CornerRadius="6"/>
                    <Border x:Name="PART_Indicator" Background="#FFFFFF" CornerRadius="6" HorizontalAlignment="Left"/>
                  </Grid>
                </ControlTemplate>
              </ProgressBar.Template>
            </ProgressBar>
          </Grid>
          <TextBlock x:Name="HeroHint" Grid.Row="3" Text="הוסיפו משימה ותתחילו לתכנן את היום" FontSize="12.5" Foreground="#E0E7FF" Margin="0,9,0,0" TextWrapping="Wrap"/>
        </Grid>
      </Border>

      <Border Grid.Row="2" Margin="16,0,16,14" CornerRadius="12" Background="#FFFFFF" BorderBrush="#E5E7EB" BorderThickness="1" Padding="14">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Grid>
              <TextBlock x:Name="QuickHint" Text="הוספה מהירה — כתבו משימה ולחצו Enter" FontSize="13" Foreground="#6B7280" VerticalAlignment="Center" Margin="10,0,0,0" IsHitTestVisible="False"/>
              <TextBox x:Name="QuickBox" FontSize="13" HorizontalAlignment="Stretch" Background="Transparent">
                <TextBox.Style>
                  <Style TargetType="TextBox" BasedOn="{StaticResource {x:Type TextBox}}">
                    <Setter Property="FontSize" Value="13"/>
                    <Setter Property="Padding" Value="10,7"/>
                    <Setter Property="BorderBrush" Value="Transparent"/>
                    <Setter Property="VerticalContentAlignment" Value="Center"/>
                  </Style>
                </TextBox.Style>
              </TextBox>
            </Grid>
            <Button x:Name="AddBtn" Grid.Column="1" Content="&#xE710;" FontFamily="Segoe MDL2 Assets" Width="36" Height="36" Margin="10,0,0,0" FontSize="15" Padding="0" IsTabStop="True" Style="{StaticResource PrimaryBtnStyle}" ToolTip="הוספת משימה מפורטת"/>
          </Grid>
        </Grid>
      </Border>

      <StackPanel Grid.Row="3" Margin="14,0,14,10">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="רשימת משימות" FontSize="14" FontWeight="Bold" Foreground="#111827" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
            <Button x:Name="SearchToggleBtn" Content="&#xE721;" FontFamily="Segoe MDL2 Assets" Width="30" Height="30" Margin="8,0,0,0" FontSize="14" Padding="0" Style="{StaticResource FilterStyle}" ToolTip="חיפוש במשימות (Ctrl+F)"/>
          </StackPanel>
          <TextBlock x:Name="FilterSummary" Grid.Column="1" FontSize="11.5" Foreground="#6B7280" VerticalAlignment="Center"/>
        </Grid>
        <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
          <Button x:Name="FiltToday" Content="היום" Margin="0,0,6,0" Style="{StaticResource FilterStyle}"/>
          <Button x:Name="FiltTomorrow" Content="מחר" Margin="0,0,6,0" Style="{StaticResource FilterStyle}"/>
          <Button x:Name="FiltWeek" Content="השבוע" Margin="0,0,6,0" Style="{StaticResource FilterStyle}"/>
          <Button x:Name="FiltAll" Content="הכל" Style="{StaticResource FilterStyle}"/>
        </StackPanel>
        <Grid x:Name="SearchWrap" Margin="0,8,0,0" Visibility="Collapsed">
          <TextBox x:Name="SearchBox" Margin="34,0,0,0" FontSize="13" Padding="10,7" BorderBrush="#D1D5DB" VerticalContentAlignment="Center" FlowDirection="RightToLeft"/>
          <Button x:Name="SearchClearBtn" Width="26" Height="26" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="4,0,0,0" Content="&#xE711;" FontFamily="Segoe MDL2 Assets" FontSize="12" Padding="0" Style="{StaticResource IconBtnStyle}" ToolTip="ניקוי חיפוש" Visibility="Collapsed"/>
        </Grid>
      </StackPanel>

      <Grid Grid.Row="4" Margin="14,0,14,10">
        <ListBox x:Name="TaskList" Background="Transparent" BorderThickness="0"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                 HorizontalContentAlignment="Stretch"
                 SelectionMode="Single"
                 VirtualizingPanel.ScrollUnit="Pixel">
          <ListBox.ItemContainerStyle>
            <Style TargetType="ListBoxItem">
              <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
              <Setter Property="Padding" Value="0"/>
              <Setter Property="Margin" Value="0,0,0,8"/>
              <Setter Property="BorderThickness" Value="0"/>
              <Setter Property="Background" Value="Transparent"/>
              <Setter Property="Focusable" Value="False"/>
              <Setter Property="Template">
                <Setter.Value>
                  <ControlTemplate TargetType="ListBoxItem">
                    <ContentPresenter/>
                  </ControlTemplate>
                </Setter.Value>
              </Setter>
            </Style>
          </ListBox.ItemContainerStyle>
          <ListBox.ItemTemplate>
            <DataTemplate>
              <Border CornerRadius="12" BorderBrush="#E5E7EB" BorderThickness="1" Padding="12,10" ToolTip="גרירה לסידור מחדש">
                <Border.Style>
                  <Style TargetType="Border">
                    <Setter Property="Background" Value="#FFFFFF"/>
                    <Style.Triggers>
                      <DataTrigger Binding="{Binding IsDone}" Value="True">
                        <Setter Property="Background" Value="#F6F7F9"/>
                      </DataTrigger>
                    </Style.Triggers>
                  </Style>
                </Border.Style>
                <Border.Effect>
                  <DropShadowEffect BlurRadius="12" ShadowDepth="2" Opacity="0.07" Color="#000000"/>
                </Border.Effect>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <CheckBox IsChecked="{Binding IsDone, Mode=OneWay}" Style="{StaticResource TaskCheckStyle}" VerticalAlignment="Center" Margin="2,0,12,0" ToolTip="סימון משימה כהושלמה"/>
                  <StackPanel Grid.Column="1" VerticalAlignment="Center">
                    <TextBlock Text="{Binding Title}" FontSize="13.5" FontWeight="SemiBold" TextWrapping="Wrap">
                      <TextBlock.Style>
                        <Style TargetType="TextBlock">
                          <Setter Property="Foreground" Value="#111827"/>
                          <Style.Triggers>
                            <DataTrigger Binding="{Binding IsDone}" Value="True">
                              <Setter Property="TextDecorations" Value="Strikethrough"/>
                              <Setter Property="Foreground" Value="#9CA3AF"/>
                            </DataTrigger>
                          </Style.Triggers>
                        </Style>
                      </TextBlock.Style>
                    </TextBlock>
                    <TextBlock Text="{Binding Description}" FontSize="12" Foreground="#6B7280" TextWrapping="Wrap" Margin="0,2,0,0" Visibility="{Binding DescVisibility}"/>
                    <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                      <Border Background="#EEF2FF" CornerRadius="10" Padding="8,2">
                        <TextBlock Text="{Binding RepeatDisplay}" FontSize="10.5" Foreground="#4F46E5"/>
                      </Border>
                      <TextBlock Text="&#xEA8F;" FontFamily="Segoe MDL2 Assets" FontSize="11" Margin="6,1,0,0" Visibility="{Binding BellVisibility}" ToolTip="מפעילה התראה"/>
                    </StackPanel>
                  </StackPanel>
                  <StackPanel Grid.Column="2" VerticalAlignment="Center" Margin="10,0,10,0" HorizontalAlignment="Center" MinWidth="58">
                    <TextBlock Text="{Binding TimeDisplay}" FontSize="13" FontWeight="Bold" Foreground="{Binding TimeBrush}" HorizontalAlignment="Center"/>
                    <TextBlock Text="{Binding TimeLeftText}" FontSize="11" Foreground="{Binding TimeLeftBrush}" HorizontalAlignment="Center" Margin="0,2,0,0"/>
                  </StackPanel>
                  <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="EditCardBtn" Content="&#xE70F;" FontFamily="Segoe MDL2 Assets" Width="28" Height="28" FontSize="14" Padding="0" Style="{StaticResource IconBtnStyle}" ToolTip="עריכה"/>
                    <Button x:Name="DelCardBtn" Content="&#xE74D;" FontFamily="Segoe MDL2 Assets" Width="28" Height="28" FontSize="14" Padding="0" Margin="3,0,0,0" Foreground="#EF4444" Style="{StaticResource IconBtnStyle}" ToolTip="מחיקה"/>
                  </StackPanel>
                </Grid>
              </Border>
            </DataTemplate>
          </ListBox.ItemTemplate>
        </ListBox>
        <StackPanel x:Name="EmptyMsg" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center">
          <TextBlock Text="🎉" FontSize="40" HorizontalAlignment="Center"/>
          <TextBlock Text="אין כאן משימות" FontSize="17" FontWeight="SemiBold" Foreground="#6B7280" HorizontalAlignment="Center" Margin="0,8,0,0"/>
          <TextBlock Text="הוסיפו משימה חדשה והתחילו לתכנן את היום" FontSize="12.5" Foreground="#6B7280" HorizontalAlignment="Center" Margin="0,4,0,0"/>
        </StackPanel>
      </Grid>

      <Border Grid.Row="5" Margin="14,0,14,10" Padding="4,8,4,4" BorderBrush="#E5E7EB" BorderThickness="0,1,0,0">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="TrayHint" Text="התוכנה פועלת ברקע במגש המערכת · לחיצה על ✕ ממזערת למגש" FontSize="11" Foreground="#6B7280" TextWrapping="Wrap" VerticalAlignment="Center"/>
          <ToggleButton x:Name="SettingsBtn" Grid.Column="1" Content="&#xE713;" FontFamily="Segoe MDL2 Assets" Width="34" Height="30" Margin="8,0,0,0" FontSize="15" Padding="0" Background="#FFFFFF" Foreground="#374151" BorderThickness="0" Cursor="Hand" Style="{StaticResource ToggleBtnStyle}" ToolTip="הגדרות"/>
          <Popup x:Name="SettingsPopup" Grid.ColumnSpan="2" Placement="Bottom" AllowsTransparency="True" StaysOpen="False" IsOpen="False">
            <Border Background="#FFFFFF" CornerRadius="12" BorderBrush="#E5E7EB" BorderThickness="1" Padding="16,12" MinWidth="230" Margin="0,6,0,0">
              <StackPanel>
                <CheckBox x:Name="AutoStartCheck" Content="הפעלה עם ווינדוס" FontSize="12" Foreground="#374151" Margin="0,4,0,0" HorizontalAlignment="Right" FlowDirection="RightToLeft" HorizontalContentAlignment="Right"/>
                <CheckBox x:Name="StartMinCheck" Content="התחל ממוזער למגש" FontSize="12" Foreground="#374151" Margin="0,6,0,0" HorizontalAlignment="Right" FlowDirection="RightToLeft" HorizontalContentAlignment="Right"/>
                <CheckBox x:Name="FullscreenToastsCheck" Content="הצג הודעות גם במסך מלא" FontSize="12" Foreground="#374151" Margin="0,6,0,0" HorizontalAlignment="Right" FlowDirection="RightToLeft" HorizontalContentAlignment="Right"/>
              </StackPanel>
            </Border>
          </Popup>
        </Grid>
      </Border>

      <Grid x:Name="DlgOverlay" Grid.RowSpan="6" Visibility="Collapsed" Background="Transparent">
        <Border Background="#66000000"/>
        <ScrollViewer HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto"
                      HorizontalContentAlignment="Center" VerticalContentAlignment="Center">
          <Border x:Name="DlgCard" Background="#FFFFFF" CornerRadius="14" BorderBrush="#E5E7EB" BorderThickness="1"
                  MaxWidth="310" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="14">
            <Grid>
              <StackPanel x:Name="DlgContent" Margin="18,16,18,16"/>
              <StackPanel x:Name="DlgMsgContent" Margin="18,16,18,16" Visibility="Collapsed" Background="#FFFFFF"/>
            </Grid>
          </Border>
        </ScrollViewer>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

function Create-AppIcon {
    $bmp = New-Object System.Drawing.Bitmap(64, 64)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $rect = New-Object System.Drawing.Rectangle(2, 2, 60, 60)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, [System.Drawing.Color]::FromArgb(99, 102, 241), [System.Drawing.Color]::FromArgb(79, 70, 229), 45)
    $g.FillEllipse($brush, $rect)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 8)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $p1 = New-Object System.Drawing.Point(16, 34)
    $p2 = New-Object System.Drawing.Point(28, 46)
    $p3 = New-Object System.Drawing.Point(48, 20)
    $g.DrawLines($pen, @($p1, $p2, $p3))
    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    $pen.Dispose()
    $brush.Dispose()
    $g.Dispose()
    $bmp.Dispose()
    return $icon
}

function New-WpfIcon {
    $icoPath = Join-Path $PSScriptRoot 'DailyTasks.ico'
    if (Test-Path -LiteralPath $icoPath) {
        try {
            $fs = [System.IO.File]::OpenRead($icoPath)
            try {
                $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create($fs, [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
                $best = $null
                foreach ($f in $decoder.Frames) {
                    if ($null -eq $best -or $f.PixelWidth -gt $best.PixelWidth) { $best = $f }
                }
                if ($null -ne $best) { return $best }
            } finally { $fs.Dispose() }
        } catch {}
    }
    $icon = Create-AppIcon
    try {
        $ms = New-Object System.IO.MemoryStream
        $icon.Save($ms)
        $ms.Position = 0
        $bmp = [System.Windows.Media.Imaging.BitmapFrame]::Create($ms, [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $ms.Dispose()
        $icon.Dispose()
        return $bmp
    } catch { return $null }
}

function New-WinIcon {
    # Taskbar/window icon built from the .ico via an HICON - the reliable way
    # for WPF windows (a plain BitmapFrame often renders as a generic icon).
    $icoPath = Join-Path $PSScriptRoot 'DailyTasks.ico'
    if (-not (Test-Path -LiteralPath $icoPath)) { return $null }
    try {
        $icon = New-Object System.Drawing.Icon($icoPath)
        try {
            $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($icon.Handle, [System.Windows.Int32Rect]::Empty, $null)
            return $src
        } finally { $icon.Dispose() }
    } catch { return $null }
}

function Show-MainWindow {
    $script:Window.Show()
    $script:Window.Activate()
    if ($script:Window.WindowState -eq 'Minimized') { $script:Window.WindowState = 'Normal' }
}

function New-TrayIcon {
    $icon = Create-AppIcon
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = $icon
    $ni.Text = 'משימות יומיות'
    $ni.Visible = $true
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $openItem = New-Object System.Windows.Forms.ToolStripMenuItem('פתיחת התוכנה')
    $openItem.Add_Click({ Show-MainWindow })
    $updateItem = New-Object System.Windows.Forms.ToolStripMenuItem('בדיקת עדכונים')
    $updateItem.Add_Click({ Start-UpdateCheck -Manual })
    $menu.Items.Add($updateItem) > $null
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem('יציאה')
    $exitItem.Add_Click({ Exit-App })
    $menu.Items.Add($openItem) > $null
    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) > $null
    $menu.Items.Add($exitItem) > $null
    $ni.ContextMenuStrip = $menu
    $ni.Add_DoubleClick({ Show-MainWindow })
    $script:Tray = $ni
}

function Exit-App {
    if ($script:Exiting) { return }
    $script:Exiting = $true
    try { Save-Tasks } catch {}
    try { Save-Settings } catch {}
    try { $script:Tray.Visible = $false; $script:Tray.Dispose() } catch {}
    try {
        if ($null -ne $script:Window -and $script:Window.IsLoaded) {
            $script:Window.Close()
        }
    } catch {}
    try { $script:App.Shutdown() } catch {}
}

function Init-App {
    New-SharedStyles
    Load-Settings
    Ensure-SoundFile
    Ensure-SuccessSound
    $script:App = [System.Windows.Application]::New()
    $script:App.ShutdownMode = 'OnExplicitShutdown'
    $script:App.Add_Exit({ Save-Tasks })

    $xamlBytes = [System.Text.Encoding]::UTF8.GetBytes($script:MainXaml)
    $xamlStream = New-Object System.IO.MemoryStream
    $xamlStream.Write($xamlBytes, 0, $xamlBytes.Length)
    $xamlStream.Position = 0
    $xamlReader = New-Object System.Xml.XmlTextReader($xamlStream)
    $win = [System.Windows.Markup.XamlReader]::Load($xamlReader)
    $script:Window = $win

    $script:QuickBox = $win.FindName('QuickBox')
    $script:SearchBox = $win.FindName('SearchBox')
    $script:SearchWrap = $win.FindName('SearchWrap')
    $script:SearchClearBtn = $win.FindName('SearchClearBtn')
    $script:AddBtn = $win.FindName('AddBtn')
    $script:FiltToday = $win.FindName('FiltToday')
    $script:FiltTomorrow = $win.FindName('FiltTomorrow')
    $script:FiltWeek = $win.FindName('FiltWeek')
    $script:FiltAll = $win.FindName('FiltAll')
    $script:TaskList = $win.FindName('TaskList')
    $script:EmptyMsg = $win.FindName('EmptyMsg')
    $script:HeroText = $win.FindName('HeroText')
    $script:HeroBar = $win.FindName('HeroBar')
    $script:HeroPct = $win.FindName('HeroPct')
    $script:HeroStreak = $win.FindName('HeroStreak')
    $script:HeroHint = $win.FindName('HeroHint')
    $script:FilterSummary = $win.FindName('FilterSummary')
    $script:TopDate = $win.FindName('TopDate')
    $script:SearchToggleBtn = $win.FindName('SearchToggleBtn')
    $script:DlgOverlay = $win.FindName('DlgOverlay')
    $script:DlgContent = $win.FindName('DlgContent')
    $script:DlgMsgContent = $win.FindName('DlgMsgContent')
    $script:SoundBtn = $win.FindName('SoundBtn')
    $script:SettingsBtn = $win.FindName('SettingsBtn')
    $script:SettingsPopup = $win.FindName('SettingsPopup')
    $minBtn = $win.FindName('MinBtn')
    $closeBtn = $win.FindName('CloseBtn')
    $script:AppIconImg = $win.FindName('AppIconImg')

    # The settings checkboxes live inside the settings popup (its own namescope),
    # so they are resolved through the popup itself.
    $script:AutoStartCheck = $script:SettingsPopup.FindName('AutoStartCheck')
    $script:StartMinCheck = $script:SettingsPopup.FindName('StartMinCheck')
    $script:FullscreenToastsCheck = $script:SettingsPopup.FindName('FullscreenToastsCheck')
    $script:SettingsPopup.PlacementTarget = $script:SettingsBtn
    $script:SettingsBtn.Add_Click({
        if ($script:SettingsBtn.IsChecked) { $script:SettingsPopup.IsOpen = $true }
        else { $script:SettingsPopup.IsOpen = $false }
    })
    $script:SettingsPopup.Add_Closed({ $script:SettingsBtn.IsChecked = $false })

    $script:SearchBox.Text = ''
    $script:SearchBox.ToolTip = 'חיפוש בין המשימות לפי שם או תיאור'
    $script:SearchWrap.Visibility = 'Collapsed'
    $script:QuickBox.ToolTip = 'הוספה מהירה: כתבו משימה, אופציונלי עם שעה (לדוגמה: שיחת טלפון 09:30) ולחצו Enter'
    $script:QuickHint = $win.FindName('QuickHint')

    $today = Get-Date
    $he = New-Object System.Globalization.CultureInfo('he-IL')
    $script:TopDate.Text = $today.ToString('dddd, d בMMMM', $he)

    $addHandler = [System.Windows.RoutedEventHandler]{ param($s, $e) Handle-ListClick $s $e }
    $script:TaskList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $addHandler)
    Enable-ListDragReorder

    function Update-SoundButton {
        if ($script:SoundEnabled) {
            $script:SoundBtn.Content = [string][char]0xE767
            $script:SoundBtn.ToolTip = 'צליל התראות: מופעל'
        } else {
            $script:SoundBtn.Content = [string][char]0xE74F
            $script:SoundBtn.ToolTip = 'צליל התראות: כבוי'
        }
    }
    Update-SoundButton
    $script:SoundBtn.Add_Click({
        $script:SoundEnabled = -not $script:SoundEnabled
        Update-SoundButton
        Save-Settings
    })
    $minBtn.Add_Click({ $script:Window.WindowState = 'Minimized' })
    $closeBtn.Add_Click({ $script:Window.Hide() })
    function Open-DetailedDialog {
        $text = $script:QuickBox.Text.Trim()
        $title = $text
        $time = ''
        $tm = [regex]::Match($text, '\b(\d{1,2}:\d{2})\b')
        if ($tm.Success) {
            $cand = $tm.Value
            if (Get-TimeSpanSafe $cand) {
                $time = $cand
                $title = ($text.Substring(0, $tm.Index) + ' ' + $text.Substring($tm.Index + $tm.Length)) -replace '\s+', ' '
                $title = $title.Trim()
                if (-not $title) { $title = $text }
            }
        }
        # The text moves into the detailed dialog - the quick box starts clean.
        $script:QuickBox.Clear()
        Show-TaskDialog $null $title $time
    }
    $script:AddBtn.Add_Click({ Open-DetailedDialog })
    $script:AddBtn.Add_KeyDown({
        if ($_.Key -eq 'Enter') { $_.Handled = $true; Open-DetailedDialog }
    })
    $script:QuickBox.Add_KeyDown({
        if ($_.Key -eq 'Enter') { $_.Handled = $true; Add-QuickTask }
    })
    $script:SearchBox.Add_TextChanged({
        $script:SearchClearBtn.Visibility = if ($script:SearchBox.Text.Length -gt 0) { 'Visible' } else { 'Collapsed' }
        Refresh-List
    })
    $script:SearchBox.Add_KeyDown({
        if ($_.Key -eq 'Escape') {
            $_.Handled = $true
            $script:SearchWrap.Visibility = 'Collapsed'
            $script:SearchBox.Text = ''
            Refresh-List
        }
    })
    $script:SearchClearBtn.Add_Click({
        $script:SearchBox.Text = ''
        $script:SearchBox.Focus()
    })
    $script:SearchToggleBtn.Add_Click({
        if ($script:SearchWrap.Visibility -eq 'Collapsed') {
            $script:SearchWrap.Visibility = 'Visible'
            $script:SearchBox.Focus()
        } else {
            $script:SearchWrap.Visibility = 'Collapsed'
            $script:SearchBox.Text = ''
            Refresh-List
        }
    })
    $win.Add_KeyDown({
        if ($_.Key -eq 'F' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
            $_.Handled = $true
            if ($script:SearchWrap.Visibility -eq 'Collapsed') { $script:SearchWrap.Visibility = 'Visible' }
            $script:SearchBox.Focus()
        }
        elseif ($script:DlgOverlay.Visibility -eq 'Visible') {
            if ($_.Key -eq 'Escape') {
                $_.Handled = $true
                if ($script:DlgMsgContent.Visibility -eq 'Visible') {
                    $script:DlgResult = 'no'
                    $script:DlgMsgContent.Visibility = 'Collapsed'
                    if (-not $script:DlgMsgWasOpen) { $script:DlgOverlay.Visibility = 'Collapsed' }
                    if ($null -ne $script:DlgFrame) { $script:DlgFrame.Continue = $false; $script:DlgFrame = $null }
                } else {
                    Close-DialogOverlay
                }
            }
            elseif ($_.Key -eq 'Enter' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
                $_.Handled = $true
                if ($script:DlgMsgContent.Visibility -ne 'Visible' -and $null -ne $script:DlgSaveAction) {
                    & $script:DlgSaveAction
                }
            }
        }
    })
    $script:QuickBox.Add_TextChanged({
        $script:QuickHint.Visibility = if ($script:QuickBox.Text.Length -gt 0) { 'Collapsed' } else { 'Visible' }
    })

    function Update-FilterButtons {
        $map = @{
            'today' = $script:FiltToday
            'tomorrow' = $script:FiltTomorrow
            'week' = $script:FiltWeek
            'all' = $script:FiltAll
        }
        foreach ($k in $map.Keys) {
            if ($k -eq $script:Filter) {
                $map[$k].Background = Get-Brush '#4F46E5'
                $map[$k].Foreground = Get-Brush '#FFFFFF'
            } else {
                $map[$k].Background = Get-Brush '#FFFFFF'
                $map[$k].Foreground = Get-Brush '#374151'
            }
        }
    }
    $script:Filter = 'today'
    Update-FilterButtons
    $script:FiltToday.Add_Click({ $script:Filter = 'today'; Update-FilterButtons; Refresh-List })
    $script:FiltTomorrow.Add_Click({ $script:Filter = 'tomorrow'; Update-FilterButtons; Refresh-List })
    $script:FiltWeek.Add_Click({ $script:Filter = 'week'; Update-FilterButtons; Refresh-List })
    $script:FiltAll.Add_Click({ $script:Filter = 'all'; Update-FilterButtons; Refresh-List })

    $autoOn = Test-Path -LiteralPath (Get-StartupShortcut)
    $script:AutoStartCheck.IsChecked = $autoOn
    $script:AutoStartCheck.Add_Click({ Set-AutoStart ($script:AutoStartCheck.IsChecked -eq $true) })
    $script:StartMinCheck.IsChecked = $script:StartMinimized
    $script:StartMinCheck.Add_Click({
        $script:StartMinimized = ($script:StartMinCheck.IsChecked -eq $true)
        Save-Settings
    })
    $script:FullscreenToastsCheck.IsChecked = $script:ShowToastsFullscreen
    $script:FullscreenToastsCheck.Add_Click({
        $script:ShowToastsFullscreen = ($script:FullscreenToastsCheck.IsChecked -eq $true)
        Save-Settings
    })

    $win.Add_Closing({
        param($s, $e)
        if (-not $script:Exiting) {
            $e.Cancel = $true
            $script:Window.Hide()
        }
    })

    Load-Tasks
    $missed = @(Initialize-Notified)
    Refresh-List

    $tickTimer = New-Object System.Windows.Threading.DispatcherTimer
    $tickTimer.Interval = [TimeSpan]::FromSeconds(20)
    $tickTimer.Add_Tick({ On-Tick })
    $tickTimer.Start()

    try { $script:ShowEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Global\DailyTasksApp_Show') } catch { $script:ShowEvent = $null }
    if ($null -ne $script:ShowEvent) {
        $showTimer = New-Object System.Windows.Threading.DispatcherTimer
        $showTimer.Interval = [TimeSpan]::FromMilliseconds(400)
        $showTimer.Add_Tick({
            if ($script:ShowEvent.WaitOne(0)) { Show-MainWindow }
        })
        $showTimer.Start()
    }

    $win.Icon = New-WinIcon
    if ($null -ne $script:AppIconImg) {
        $iconSrc = New-WpfIcon
        if ($null -ne $iconSrc) { $script:AppIconImg.Source = $iconSrc }
    }
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $win.Left = [double]$wa.Left
    $win.Top = [double]$wa.Bottom - $win.Height

    $hint = $win.FindName('TrayHint')
    if ($null -ne $hint) { $hint.Text = $hint.Text + " · גרסה $($script:AppVersion)" }
    Start-UpdateCheck

    if (-not $script:StartMinimized) { $win.Show() }
    if ($missed.Count -gt 0) { Show-MissedToast $missed }
    $script:App.Run()
}

New-TrayIcon
Init-App

