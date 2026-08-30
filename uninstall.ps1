$ErrorActionPreference = 'Continue'

$dest = Join-Path $env:LOCALAPPDATA 'DailyTasks'
$desktop = [Environment]::GetFolderPath('Desktop')
$startMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'משימות יומיות'
$startup = [Environment]::GetFolderPath('Startup')

Write-Host ''
Write-Host 'הסרת התקנה של "משימות יומיות"' -ForegroundColor Cyan
Write-Host ''
Write-Host 'שימו לב: אם התוכנה רצה כרגע, סגרו אותה לפני המשך ההסרה.'
Write-Host ''

# Shortcuts: desktop, start menu, autostart
foreach ($p in @((Join-Path $desktop 'משימות יומיות.lnk'), (Join-Path $startMenuDir 'משימות יומיות.lnk'), (Join-Path $startup 'DailyTasks.lnk'))) {
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
}
if (Test-Path -LiteralPath $startMenuDir) {
    Remove-Item -LiteralPath $startMenuDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'נמחקו קיצורי הדרך (שולחן העבודה, תפריט התחל, הפעלה אוטומטית).'

$ans = Read-Host 'למחוק גם את קבצי התוכנה (כולל המשימות שלך)? [N/y]'
if ($ans -match '^[yY]') {
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "נמחקה התיקייה $dest"
    }
} else {
    Write-Host "הקבצים נשמרו ב- $dest (מומלץ לגבות את tasks.json)."
}

Write-Host ''
Write-Host 'הסרת ההתקנה הושלמה.'
Start-Sleep -Seconds 2
