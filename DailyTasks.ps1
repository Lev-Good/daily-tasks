Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$mutex = New-Object System.Threading.Mutex($false, 'Global\DailyTasksApp_Hebrew')
if (-not $mutex.WaitOne(0, $false)) {
    [System.Windows.MessageBox]::Show('התוכנה כבר פועלת. בדקו את מגש המערכת.', 'משימות יומיות')
    exit
}

$script:DataFile = Join-Path $PSScriptRoot 'tasks.json'
$script:Tasks = @()
$script:Snoozed = @{}
$script:OpenToasts = @()
$script:NotifiedIds = @{}
$script:NotifiedDate = ''
$script:LastMinute = ''
$script:Exiting = $false
$script:Tray = $null
$script:App = $null

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

function Load-Tasks {
    if (Test-Path -LiteralPath $script:DataFile) {
        try {
            $raw = [System.IO.File]::ReadAllText($script:DataFile, [System.Text.Encoding]::UTF8)
            $script:Tasks = @($raw | ConvertFrom-Json)
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
        } catch {
            $script:Tasks = @()
        }
    }
}

function Save-Tasks {
    try {
        $cutoff = (Get-Date).AddDays(-60).ToString('yyyy-MM-dd')
        foreach ($t in $script:Tasks) {
            $keys = @($t.Completed.Keys)
            foreach ($k in $keys) {
                if ($k -lt $cutoff) { $t.Completed.Remove($k) }
            }
        }
        $json = $script:Tasks | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($script:DataFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
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

function Play-TaskSound {
    $wav = Join-Path $PSScriptRoot 'sound.wav'
    if (Test-Path -LiteralPath $wav) {
        try { $pl = New-Object System.Media.SoundPlayer($wav); $pl.Play() } catch { try { [System.Media.SystemSounds]::Exclamation.Play() } catch {} }
    } else {
        try { [System.Media.SystemSounds]::Exclamation.Play() } catch {}
    }
}

function Play-SuccessSound {
    $wav = Join-Path $PSScriptRoot 'success.wav'
    if (Test-Path -LiteralPath $wav) {
        try { $pl = New-Object System.Media.SoundPlayer($wav); $pl.Play() } catch {}
    }
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
        $tgt = [datetime]::Today.Add([TimeSpan]::Parse($t.Time))
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
    } else {
        $timeLeft = ''
        $timeBrush = '#9CA3AF'; $timeLeftBrush = '#9CA3AF'
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

function Refresh-List {
    if ($null -eq $script:TaskList) { return }
    $today = Get-TodayStr
    $nowDow = [int](Get-Date).DayOfWeek
    $onlyToday = ($script:FiltToday.Tag -eq 'on')
    $q = $script:SearchBox.Text.Trim().ToLower()
    $views = @()
    $totalToday = 0
    $doneToday = 0
    foreach ($t in $script:Tasks) {
        $isToday = $true
        if ($t.Repeat -eq 'Once' -and $t.Date -ne $today) { $isToday = $false }
        elseif ($t.Repeat -eq 'Weekly' -and $t.Days -notcontains $nowDow) { $isToday = $false }
        if ($isToday) {
            $totalToday++
            if ($t.Completed.ContainsKey($today)) { $doneToday++ }
        }
        if ($onlyToday -and -not $isToday) { continue }
        if ($q) {
            $hay = ($t.Title + ' ' + $t.Description).ToLower()
            if (-not $hay.Contains($q)) { continue }
        }
        $views += New-TaskView $t $today $isToday
    }
    $views = @($views | Sort-Object -Property @{Expression = { $_.IsDone }; Ascending = $true}, @{Expression = { [TimeSpan]::Parse($_.Time) }; Ascending = $true})
    $script:TaskList.ItemsSource = [object[]]$views
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
            $r = [System.Windows.MessageBox]::Show("למחוק את המשימה ?$($t.Title)?", 'מחיקת משימה', 'YesNo', 'Question')
            if ($r -eq 'Yes') {
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
    $titleBox.Width = 290
    $titleBox.FontSize = 14
    $titleBox.Padding = New-Object System.Windows.Thickness(8, 6, 8, 6)
    $titleBox.VerticalContentAlignment = 'Center'

    $descBox = New-Object System.Windows.Controls.TextBox
    $descBox.Width = 330
    $descBox.FontSize = 14
    $descBox.Padding = New-Object System.Windows.Thickness(8, 6, 8, 6)
    $descBox.VerticalContentAlignment = 'Center'

    $removeBtn = New-Object System.Windows.Controls.Button
    $removeBtn.Content = '✕'
    $removeBtn.Width = 30
    $removeBtn.Height = 30
    $removeBtn.FontSize = 12
    $removeBtn.Margin = New-Object System.Windows.Thickness(4, 0, 0, 0)
    $removeBtn.Style = $script:IconBtnStyle
    $removeBtn.Add_Click({
        $btn = $_.Source
        $stack = $btn.Parent
        $panel = $stack.Parent
        $panel.Children.Remove($stack)
    })

    $row.Children.Add($titleBox) > $null
    $row.Children.Add($descBox) > $null
    $row.Children.Add($removeBtn) > $null
    $rowsPanel.Children.Add($row) > $null
}

function Show-TaskDialog($existing) {
    $win = New-Object System.Windows.Window
    $win.Title = 'משימה יומית'
    $win.SizeToContent = 'Height'
    $win.Width = 760
    $win.WindowStartupLocation = 'CenterOwner'
    $win.WindowStyle = 'SingleBorderWindow'
    $win.ResizeMode = 'NoResize'
    $win.Background = Get-Brush '#FFFFFF'
    $win.FlowDirection = 'RightToLeft'
    $win.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
    $win.Add_KeyDown({
        if ($_.Key -eq 'Escape') { $_.Handled = $true; $win.Close() }
    })
    $win.Add_KeyDown({
        if ($_.Key -eq 'Enter' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
            $_.Handled = $true; $win.Tag = 'saved'; $win.DialogResult = $true; $win.Close()
        }
    })

    $outer = New-Object System.Windows.Controls.StackPanel
    $outer.Margin = New-Object System.Windows.Thickness(24)
    $outer.HorizontalAlignment = 'Stretch'

    $header = New-Object System.Windows.Controls.TextBlock
    $header.Text = if ($null -eq $existing) { 'משימה חדשה' } else { 'עריכת משימה' }
    $header.FontSize = 20
    $header.FontWeight = 'Bold'
    $header.Foreground = Get-Brush '#111827'
    $header.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
    $outer.Children.Add($header) > $null

    $sub = New-Object System.Windows.Controls.TextBlock
    $sub.Text = 'ניתן להזין כמה משימות בבת אחת - כולן יתריעו יחד באותו זמן'
    $sub.FontSize = 12
    $sub.Foreground = Get-Brush '#6B7280'
    $sub.Margin = New-Object System.Windows.Thickness(0, 0, 0, 14)
    $outer.Children.Add($sub) > $null

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = New-Object System.Windows.Thickness(0, 0, 0, 10)
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = New-Object System.Windows.GridLength(150)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $c2.Width = New-Object System.Windows.GridLength(1, 'Star')
    $grid.ColumnDefinitions.Add($c1) > $null
    $grid.ColumnDefinitions.Add($c2) > $null

    function Add-Field([string]$labelText, $control, [int]$rowIdx) {
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $labelText
        $lbl.FontSize = 14
        $lbl.FontWeight = 'SemiBold'
        $lbl.Foreground = Get-Brush '#374151'
        $lbl.VerticalAlignment = 'Center'
        $lbl.Margin = New-Object System.Windows.Thickness(0, 6, 0, 6)
        [System.Windows.Controls.Grid]::SetRow($lbl, $rowIdx)
        [System.Windows.Controls.Grid]::SetColumn($lbl, 0)
        $grid.Children.Add($lbl) > $null
        $cp = New-Object System.Windows.Controls.StackPanel
        $cp.Orientation = 'Horizontal'
        $cp.HorizontalAlignment = 'Stretch'
        $cp.Margin = New-Object System.Windows.Thickness(0, 4, 0, 4)
        $cp.Children.Add($control) > $null
        [System.Windows.Controls.Grid]::SetRow($cp, $rowIdx)
        [System.Windows.Controls.Grid]::SetColumn($cp, 1)
        $grid.Children.Add($cp) > $null
    }

    $timeBox = New-Object System.Windows.Controls.TextBox
    $timeBox.Text = if ($null -ne $existing) { $existing.Time } else { (Get-Date).AddMinutes(30).ToString('HH:mm') }
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
        $repeatBox.SelectedIndex = 0
    }

    $daysPanel = New-Object System.Windows.Controls.StackPanel
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

    $onceDate = New-Object System.Windows.Controls.TextBox
    $onceDate.Width = 120
    $onceDate.FontSize = 15
    $onceDate.Padding = New-Object System.Windows.Thickness(8, 6, 8, 6)
    $onceDate.VerticalContentAlignment = 'Center'
    $onceDate.Visibility = if ($repeatBox.SelectedIndex -eq 2) { 'Visible' } else { 'Collapsed' }
    if ($null -ne $existing -and $existing.Repeat -eq 'Once' -and $existing.Date) {
        $onceDate.Text = $existing.Date
    } else {
        $onceDate.Text = (Get-Date).ToString('yyyy-MM-dd')
    }

    $notifyCheck = New-Object System.Windows.Controls.CheckBox
    $notifyCheck.Content = 'התראה וצליל'
    $notifyCheck.FontSize = 14
    $notifyCheck.IsChecked = $true
    if ($null -ne $existing) { $notifyCheck.IsChecked = $existing.Notify }

    $soundCheck = New-Object System.Windows.Controls.CheckBox
    $soundCheck.Content = 'צליל'
    $soundCheck.FontSize = 14
    $soundCheck.Margin = New-Object System.Windows.Thickness(20, 0, 0, 0)
    $soundCheck.IsChecked = $true
    if ($null -ne $existing) { $soundCheck.IsChecked = $existing.Sound }

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

    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) > $null
    Add-Field 'שעה' $timeBox 0

    $notifyWrap = New-Object System.Windows.Controls.StackPanel
    $notifyWrap.Orientation = 'Horizontal'
    $notifyWrap.Children.Add($notifyCheck) > $null
    $notifyWrap.Children.Add($soundCheck) > $null

    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) > $null
    Add-Field 'התראה' $notifyWrap 1

    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) > $null
    Add-Field 'תזכורת' $remindBox 2

    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) > $null
    Add-Field 'חזרה' $repeatBox 3

    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) > $null
    Add-Field 'ימים' $daysPanel 4

    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) > $null
    Add-Field 'תאריך' $onceDate 5

    $outer.Children.Add($grid) > $null

    $rowsLabel = New-Object System.Windows.Controls.TextBlock
    $rowsLabel.Text = 'המשימות'
    $rowsLabel.FontSize = 14
    $rowsLabel.FontWeight = 'SemiBold'
    $rowsLabel.Foreground = Get-Brush '#374151'
    $rowsLabel.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
    $outer.Children.Add($rowsLabel) > $null

    $rowsPanel = New-Object System.Windows.Controls.StackPanel
    $rowsPanel.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
    $outer.Children.Add($rowsPanel) > $null
    $script:dlgRowsPanel = $rowsPanel

    $addRowBtn = New-Object System.Windows.Controls.Button
    $addRowBtn.Content = '+ הוספת משימה נוספת (אותו זמן)'
    $addRowBtn.FontSize = 13
    $addRowBtn.Padding = New-Object System.Windows.Thickness(12, 6, 12, 6)
    $addRowBtn.Background = Get-Brush '#EEF2FF'
    $addRowBtn.Foreground = Get-Brush '#4F46E5'
    $addRowBtn.BorderThickness = New-Object System.Windows.Thickness(0)
    $addRowBtn.Cursor = 'Hand'
    $addRowBtn.HorizontalAlignment = 'Left'
    $addRowBtn.Add_Click({ Add-DialogRow })
    $outer.Children.Add($addRowBtn) > $null

    $btnBar = New-Object System.Windows.Controls.StackPanel
    $btnBar.Orientation = 'Horizontal'
    $btnBar.HorizontalAlignment = 'Right'
    $btnBar.Margin = New-Object System.Windows.Thickness(0, 18, 0, 0)

    $cancelBtn = New-Object System.Windows.Controls.Button
    $cancelBtn.Content = 'ביטול'
    $cancelBtn.Width = 110
    $cancelBtn.Height = 38
    $cancelBtn.FontSize = 14
    $cancelBtn.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
    $cancelBtn.Style = $script:SecondaryBtnStyle
    $cancelBtn.Add_Click({ $win.Close() })
    $btnBar.Children.Add($cancelBtn) > $null

    $saveBtn = New-Object System.Windows.Controls.Button
    $saveBtn.Content = if ($null -eq $existing) { 'הוספה' } else { 'שמירה' }
    $saveBtn.Width = 130
    $saveBtn.Height = 38
    $saveBtn.FontSize = 14
    $saveBtn.Style = $script:PrimaryBtnStyle
    $saveBtn.Add_Click({
        $timeStr = $timeBox.Text.Trim()
        if (-not ($timeStr -match '^\d{1,2}:\d{2}$')) {
            [System.Windows.MessageBox]::Show('נא להזין שעה בפורמט HH:MM', 'שגיאה')
            return
        }
        $titles = @()
        $descs = @()
        $first = $true
        foreach ($child in $rowsPanel.Children) {
            $boxes = @()
            foreach ($c in $child.Children) { $boxes += $c }
            if ($boxes.Count -ge 2) {
                $tl = $boxes[0].Text.Trim()
                $dc = $boxes[1].Text.Trim()
                if ($first) {
                    $titles += $tl
                    $descs += $dc
                    $first = $false
                } elseif ($tl -or $dc) {
                    $titles += $tl
                    $descs += $dc
                }
            }
        }
        if ($titles.Count -eq 0) {
            [System.Windows.MessageBox]::Show('נא להזין לפחות משימה אחת עם כותרת', 'שגיאה')
            return
        }
        if ($repeatBox.SelectedIndex -eq 1) {
            $selected = @($dayChecks | Where-Object { $_.IsChecked -eq $true } | ForEach-Object { [int]$_.Tag })
            if ($selected.Count -eq 0) {
                [System.Windows.MessageBox]::Show('נא לבחור לפחות יום אחד לחזרה שבועית', 'שגיאה')
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
                    Repeat = 'Daily'
                    Days = @()
                    Date = ''
                    Notify = $false
                    Sound = $false
                    RemindBefore = 0
                    Completed = @{}
                }
            }
            $t.Title = $titles[$i]
            $t.Description = $descs[$i]
            $t.Time = $timeStr
            $t.Repeat = $repeat
            if ($repeat -eq 'Weekly') { $t.Days = @($selected) }
            elseif ($repeat -eq 'Once') { $t.Date = $onceDate.Text.Trim() }
            $t.Notify = [bool]$notifyCheck.IsChecked
            $t.Sound = [bool]$soundCheck.IsChecked
            $t.RemindBefore = $remind
            if ($null -eq $existing -or $i -gt 0) {
                $script:Tasks += $t
            }
        }
        Save-Tasks
        Refresh-List
        $win.Tag = 'saved'
        $win.DialogResult = $true
        $win.Close()
    })
    $btnBar.Children.Add($saveBtn) > $null
    $outer.Children.Add($btnBar) > $null

    $win.Content = $outer

    if ($null -eq $existing) {
        Add-DialogRow
        Add-DialogRow
        $rowsPanel.Children[1].Children[0].Text = ''
    } else {
        Add-DialogRow
        $r0 = $rowsPanel.Children[0]
        $r0.Children[0].Text = $existing.Title
        $r0.Children[1].Text = $existing.Description
        $r0.Children[2].Visibility = 'Collapsed'
    }

    $script:dlgWin = $win
    $null = $win.ShowDialog()
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
    if (-not ($timeStr -match '^\d{1,2}:\d{2}$')) { $timeStr = (Get-Date).AddMinutes(30).ToString('HH:mm') }
    $t = [pscustomobject]@{
        Id = [guid]::NewGuid().ToString()
        Title = $title
        Description = ''
        Time = $timeStr
        Repeat = 'Daily'
        Days = @()
        Date = ''
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

    $top = New-Object System.Windows.Controls.DockPanel
    $icon = New-Object System.Windows.Controls.TextBlock
    $icon.Text = '🔔'
    $icon.FontSize = 18
    $icon.Margin = New-Object System.Windows.Thickness(0, 0, 0, 0)
    $icon.VerticalAlignment = 'Center'
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
        $txt = New-Object System.Windows.Controls.TextBlock
        $txt.Text = '☐ ' + $row.Title
        $txt.FontSize = 13
        $txt.FontWeight = 'SemiBold'
        $txt.TextTrimming = 'CharacterEllipsis'
        $txt.VerticalAlignment = 'Center'
        $rb.Content = $txt
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
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
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

function Show-Toast($win) {
    $script:OpenToasts += $win
    $null = $win.Show()
}

function Close-Toast($win) {
    try { if ($win.IsVisible) { $win.Close() } } catch {}
}

function Handle-ToastClosed($win) {
    $script:OpenToasts = @($script:OpenToasts | Where-Object { $_ -ne $win })
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
        if ($t.Sound) { $shouldSound = $true }
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
        $target = [datetime]::Today.Add([TimeSpan]::Parse($t.Time))
        if ($t.RemindBefore -gt 0) { $target = $target.AddMinutes(-$t.RemindBefore) }
        if ($now -ge $target) {
            $due += $t
        }
    }
    if ($due.Count -gt 0) {
        Show-Notifications $due
    }
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
        $target = [datetime]::Today.Add([TimeSpan]::Parse($t.Time))
        if ($t.RemindBefore -gt 0) { $target = $target.AddMinutes(-$t.RemindBefore) }
        if ($now -ge $target) { $already += $t.Id }
    }
    if ($already.Count -gt 0) {
        $script:NotifiedIds[$today] = @($already)
    }
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
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="#4F46E5" CornerRadius="8" Padding="14,7">
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
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="#FFFFFF" BorderBrush="#D1D5DB" CornerRadius="8" Padding="14,7">
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
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="bd" Background="#00000000" CornerRadius="6" Padding="6,4">
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

$script:MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
        Title="משימות יומיות"
        Width="320" Height="640" MinWidth="290" MinHeight="460"
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
    </Style>
    <Style x:Key="FilterStyle" TargetType="Button">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#374151"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="14,6">
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
    <Style x:Key="PrimaryBtnStyle" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="#4F46E5" CornerRadius="8" Padding="14,7">
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
    <Style x:Key="IconBtnStyle" TargetType="Button">
      <Setter Property="Foreground" Value="#6B7280"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="#00000000" CornerRadius="6" Padding="6,4">
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
  </Window.Resources>

  <Border CornerRadius="14" Background="#F3F4F6" BorderBrush="#E5E7EB" BorderThickness="1" Padding="0">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0" Margin="18,8,18,6">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,0,0">
          <TextBlock Text="📋" FontSize="18" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <TextBlock Text="משימות יומיות" FontSize="17" FontWeight="Bold" Foreground="#111827" VerticalAlignment="Center"/>
          <TextBlock x:Name="TopDate" FontSize="12.5" Foreground="#9CA3AF" VerticalAlignment="Center" Margin="12,0,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center"
                    shell:WindowChrome.IsHitTestVisibleInChrome="True">
          <Button x:Name="MinBtn" Content="&#x2013;" Width="36" Height="30" Margin="0,0,6,0" FontSize="14" Style="{StaticResource FilterStyle}" ToolTip="מזעור"/>
          <Button x:Name="CloseBtn" Content="&#x2715;" Width="36" Height="30" FontSize="12" Foreground="#6B7280" Style="{StaticResource FilterStyle}" ToolTip="סגירה למגש"/>
        </StackPanel>
      </Grid>

      <Border Grid.Row="1" Margin="14,0,14,12" CornerRadius="16" Padding="22,18">
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
          </Grid.RowDefinitions>
          <Grid Grid.Row="0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
              <TextBlock Text="היום" FontSize="13" Foreground="#C7D2FE" FontWeight="SemiBold"/>
              <TextBlock x:Name="HeroText" Text="0 מתוך 0 הושלמו" FontSize="26" FontWeight="Bold" Foreground="#FFFFFF" Margin="0,2,0,0"/>
              <TextBlock x:Name="HeroStreak" Text="" FontSize="12" Foreground="#C7D2FE" Margin="0,3,0,0"/>
            </StackPanel>
            <TextBlock x:Name="HeroPct" Grid.Column="1" Text="0%" FontSize="44" FontWeight="ExtraBold" Foreground="#FFFFFF" VerticalAlignment="Center" Opacity="0.92"/>
          </Grid>
          <Grid Grid.Row="1" Margin="0,14,0,0">
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
          <TextBlock x:Name="HeroHint" Grid.Row="2" Text="הוסיפו משימה ותתחילו לתכנן את היום" FontSize="12.5" Foreground="#E0E7FF" Margin="0,10,0,0"/>
        </Grid>
      </Border>

      <Border Grid.Row="2" Margin="14,0,14,12" CornerRadius="12" Background="#FFFFFF" BorderBrush="#E5E7EB" BorderThickness="1" Padding="12">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Grid>
              <TextBlock x:Name="QuickHint" Text="הוספה מהירה: כתבו משימה ו-Enter..." FontSize="13" Foreground="#9CA3AF" VerticalAlignment="Center" Margin="10,0,0,0" IsHitTestVisible="False"/>
              <TextBox x:Name="QuickBox" FontSize="13" HorizontalAlignment="Stretch" Background="Transparent">
                <TextBox.Style>
                  <Style TargetType="TextBox">
                    <Setter Property="FontSize" Value="13"/>
                    <Setter Property="Padding" Value="10,7"/>
                    <Setter Property="BorderBrush" Value="#D1D5DB"/>
                    <Setter Property="VerticalContentAlignment" Value="Center"/>
                  </Style>
                </TextBox.Style>
              </TextBox>
            </Grid>
            <Button x:Name="AddBtn" Grid.Column="1" Content="משימה מפורטת" Width="120" Height="34" Margin="10,0,0,0" Style="{StaticResource PrimaryBtnStyle}" ToolTip="פתיחת חלון הוספה/עריכה מפורטת של משימה"/>
          </Grid>
          <Grid Grid.Row="1" Margin="0,8,0,0">
            <TextBlock x:Name="SearchHint" Text="חיפוש משימות..." FontSize="13" Foreground="#9CA3AF" VerticalAlignment="Center" Margin="10,0,0,0" IsHitTestVisible="False"/>
            <TextBox x:Name="SearchBox" FontSize="13" HorizontalAlignment="Stretch" Background="Transparent">
              <TextBox.Style>
                <Style TargetType="TextBox">
                  <Setter Property="FontSize" Value="13"/>
                  <Setter Property="Padding" Value="10,7"/>
                  <Setter Property="BorderBrush" Value="#D1D5DB"/>
                  <Setter Property="VerticalContentAlignment" Value="Center"/>
                </Style>
              </TextBox.Style>
            </TextBox>
          </Grid>
        </Grid>
      </Border>

      <Grid Grid.Row="3" Margin="14,0,14,10">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="רשימת משימות" FontSize="14" FontWeight="Bold" Foreground="#111827" VerticalAlignment="Center"/>
          <TextBlock x:Name="FilterSummary" FontSize="12" Foreground="#9CA3AF" VerticalAlignment="Center" Margin="10,0,0,0"/>
        </StackPanel>
        <Button x:Name="FiltToday" Grid.Column="1" Content="היום" Margin="0,0,8,0" Style="{StaticResource FilterStyle}"/>
        <Button x:Name="FiltAll" Grid.Column="2" Content="הכל" Style="{StaticResource FilterStyle}"/>
      </Grid>

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
              <Border CornerRadius="12" Background="#FFFFFF" BorderBrush="#E5E7EB" BorderThickness="1" Padding="12,10">
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
                  <CheckBox IsChecked="{Binding IsDone, Mode=OneWay}" Width="24" Height="24" VerticalAlignment="Center" Margin="4,0,12,0"/>
                  <StackPanel Grid.Column="1" VerticalAlignment="Center">
                    <TextBlock Text="{Binding Title}" FontSize="14" FontWeight="SemiBold" Foreground="#111827" TextTrimming="CharacterEllipsis"/>
                    <TextBlock Text="{Binding Description}" FontSize="12" Foreground="#6B7280" TextTrimming="CharacterEllipsis" Margin="0,2,0,0" Visibility="{Binding DescVisibility}"/>
                    <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                      <Border Background="#EEF2FF" CornerRadius="10" Padding="8,2">
                        <TextBlock Text="{Binding RepeatDisplay}" FontSize="10.5" Foreground="#4F46E5"/>
                      </Border>
                      <TextBlock Text="&#x1F514;" FontSize="10.5" Margin="6,1,0,0" Visibility="{Binding BellVisibility}" ToolTip="מפעילה התראה"/>
                    </StackPanel>
                  </StackPanel>
                  <StackPanel Grid.Column="2" VerticalAlignment="Center" Margin="12,0,12,0" HorizontalAlignment="Center">
                    <TextBlock Text="{Binding TimeDisplay}" FontSize="13.5" FontWeight="Bold" Foreground="{Binding TimeBrush}" HorizontalAlignment="Center"/>
                    <TextBlock Text="{Binding TimeLeftText}" FontSize="11.5" Foreground="{Binding TimeLeftBrush}" HorizontalAlignment="Center" Margin="0,2,0,0"/>
                  </StackPanel>
                  <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="EditCardBtn" Content="&#x270E;" Width="30" Height="30" FontSize="13" Style="{StaticResource IconBtnStyle}" ToolTip="עריכה"/>
                    <Button x:Name="DelCardBtn" Content="&#x2715;" Width="30" Height="30" FontSize="12" Margin="4,0,0,0" Foreground="#EF4444" Style="{StaticResource IconBtnStyle}" ToolTip="מחיקה"/>
                  </StackPanel>
                </Grid>
              </Border>
            </DataTemplate>
          </ListBox.ItemTemplate>
        </ListBox>
        <StackPanel x:Name="EmptyMsg" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center">
          <TextBlock Text="🎉" FontSize="40" HorizontalAlignment="Center"/>
          <TextBlock Text="אין כאן משימות" FontSize="17" FontWeight="SemiBold" Foreground="#6B7280" HorizontalAlignment="Center" Margin="0,8,0,0"/>
          <TextBlock Text="הוסיפו משימה חדשה והתחילו לתכנן את היום" FontSize="12.5" Foreground="#9CA3AF" HorizontalAlignment="Center" Margin="0,4,0,0"/>
        </StackPanel>
      </Grid>

      <Border Grid.Row="5" Margin="14,0,14,10" Padding="4,8,4,2" BorderBrush="#E5E7EB" BorderThickness="0,1,0,0">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Text="התוכנה ממשיכה לרוץ במגש המערכת - לחיצה על ✕ תסגור אותה למגש" FontSize="11.5" Foreground="#9CA3AF" VerticalAlignment="Center"/>
          <CheckBox x:Name="AutoStartCheck" Grid.Column="1" Content="הפעלה עם ווינדוס" FontSize="12.5" Foreground="#374151" VerticalAlignment="Center"/>
        </Grid>
      </Border>
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
    $script:AddBtn = $win.FindName('AddBtn')
    $script:FiltToday = $win.FindName('FiltToday')
    $script:FiltAll = $win.FindName('FiltAll')
    $script:TaskList = $win.FindName('TaskList')
    $script:EmptyMsg = $win.FindName('EmptyMsg')
    $script:HeroText = $win.FindName('HeroText')
    $script:HeroBar = $win.FindName('HeroBar')
    $script:HeroPct = $win.FindName('HeroPct')
    $script:HeroStreak = $win.FindName('HeroStreak')
    $script:HeroHint = $win.FindName('HeroHint')
    $script:FilterSummary = $win.FindName('FilterSummary')
    $script:AutoStartCheck = $win.FindName('AutoStartCheck')
    $script:TopDate = $win.FindName('TopDate')
    $minBtn = $win.FindName('MinBtn')
    $closeBtn = $win.FindName('CloseBtn')

    $script:SearchBox.Text = ''
    $script:SearchBox.ToolTip = 'חיפוש בין המשימות לפי שם או תיאור'
    $script:QuickBox.ToolTip = 'הוספה מהירה: כתבו משימה, אופציונלי עם שעה (לדוגמה: שיחת טלפון 09:30) ולחצו Enter'
    $script:QuickHint = $win.FindName('QuickHint')
    $script:SearchHint = $win.FindName('SearchHint')

    $today = Get-Date
    $he = New-Object System.Globalization.CultureInfo('he-IL')
    $script:TopDate.Text = $today.ToString('dddd, d בMMMM yyyy', $he)

    $addHandler = [System.Windows.RoutedEventHandler]{ param($s, $e) Handle-ListClick $s $e }
    $script:TaskList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $addHandler)

    $minBtn.Add_Click({ $script:Window.WindowState = 'Minimized' })
    $closeBtn.Add_Click({ $script:Window.Hide() })
    $script:AddBtn.Add_Click({ Show-TaskDialog $null })
    $script:QuickBox.Add_KeyDown({
        if ($_.Key -eq 'Enter') { $_.Handled = $true; Add-QuickTask }
    })
    $script:SearchBox.Add_TextChanged({
        $script:SearchHint.Visibility = if ($script:SearchBox.Text.Length -gt 0) { 'Collapsed' } else { 'Visible' }
        Refresh-List
    })
    $script:QuickBox.Add_TextChanged({
        $script:QuickHint.Visibility = if ($script:QuickBox.Text.Length -gt 0) { 'Collapsed' } else { 'Visible' }
    })

    function Update-FilterButtons {
        $todayOn = ($script:FiltToday.Tag -eq 'on')
        if ($todayOn) {
            $script:FiltToday.Background = Get-Brush '#4F46E5'
            $script:FiltToday.Foreground = Get-Brush '#FFFFFF'
            $script:FiltAll.Background = Get-Brush '#FFFFFF'
            $script:FiltAll.Foreground = Get-Brush '#374151'
        } else {
            $script:FiltToday.Background = Get-Brush '#FFFFFF'
            $script:FiltToday.Foreground = Get-Brush '#374151'
            $script:FiltAll.Background = Get-Brush '#4F46E5'
            $script:FiltAll.Foreground = Get-Brush '#FFFFFF'
        }
    }
    $script:FiltToday.Tag = 'on'
    Update-FilterButtons
    $script:FiltToday.Add_Click({
        $script:FiltToday.Tag = 'on'
        $script:FiltAll.Tag = 'off'
        Update-FilterButtons
        Refresh-List
    })
    $script:FiltAll.Add_Click({
        $script:FiltToday.Tag = 'off'
        $script:FiltAll.Tag = 'on'
        Update-FilterButtons
        Refresh-List
    })

    $autoOn = Test-Path -LiteralPath (Get-StartupShortcut)
    $script:AutoStartCheck.IsChecked = $autoOn
    $script:AutoStartCheck.Add_Click({ Set-AutoStart ($script:AutoStartCheck.IsChecked -eq $true) })

    $win.Add_Closing({
        param($s, $e)
        if (-not $script:Exiting) {
            $e.Cancel = $true
            $script:Window.Hide()
        }
    })

    Load-Tasks
    Initialize-Notified
    Refresh-List

    $tickTimer = New-Object System.Windows.Threading.DispatcherTimer
    $tickTimer.Interval = [TimeSpan]::FromSeconds(20)
    $tickTimer.Add_Tick({ On-Tick })
    $tickTimer.Start()

    $win.Icon = New-WpfIcon
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $win.Left = [double]$wa.Left
    $win.Top = [double]$wa.Bottom - $win.Height

    $win.Show()
    $script:App.Run()
}

New-TrayIcon
Init-App

