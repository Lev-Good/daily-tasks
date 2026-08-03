$ErrorActionPreference = 'Stop'

$dest = Join-Path $env:LOCALAPPDATA 'DailyTasks'
$files = 'DailyTasks.ps1', 'DailyTasks.cmd', 'DailyTasks.exe', 'DailyTasks.ico', 'sound.wav', 'success.wav', 'tasks.json'

Write-Host 'מתקין את משימות יומיות...'

if (-not (Test-Path -LiteralPath $dest)) {
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
}

foreach ($f in $files) {
    $s = Join-Path $PSScriptRoot $f
    if (Test-Path -LiteralPath $s) {
        Copy-Item -LiteralPath $s -Destination (Join-Path $dest $f) -Force
    }
}

$ws = New-Object -ComObject WScript.Shell
$runner = Join-Path $dest 'DailyTasks.exe'
$ps1Path = Join-Path $dest 'DailyTasks.ps1'

$desktop = [Environment]::GetFolderPath('Desktop')
$startMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'משימות יומיות'

$lnkPlaces = @()
if (Test-Path -LiteralPath $desktop) { $lnkPlaces += $desktop }
if (-not (Test-Path -LiteralPath $startMenuDir)) {
    try { New-Item -ItemType Directory -Path $startMenuDir -Force | Out-Null } catch {}
}
if (Test-Path -LiteralPath $startMenuDir) { $lnkPlaces += $startMenuDir }

foreach ($dir in $lnkPlaces) {
    $sc = $ws.CreateShortcut((Join-Path $dir 'משימות יומיות.lnk'))
    if (Test-Path -LiteralPath $runner) {
        $sc.TargetPath = $runner
        $sc.Arguments = ''
        $sc.IconLocation = "$runner,0"
    } else {
        $sc.TargetPath = 'powershell.exe'
        $sc.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ps1Path + '"'
    }
    $sc.WorkingDirectory = $dest
    $sc.Description = 'משימות יומיות'
    $sc.Save()
}

Write-Host ''
Write-Host 'ההתקנה הושלמה בהצלחה!'
Write-Host 'התוכנה הותקנה בתיקייה:' $dest
Write-Host 'נוצרו קיצורי דרך: שולחן העבודה ותפריט התחל.'
Write-Host 'ניתן להפעיל את התוכנה עכשיו מהקיצור בדרך.'
