# Rebuilds DailyTasks.exe (launcher) and DailyTasks-Setup.exe (installer).
# Requires the .NET Framework compiler (csc.exe) and PowerShell 5.1, both of
# which ship with Windows.
$ErrorActionPreference = 'Stop'

$dir = $PSScriptRoot
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw "csc.exe not found at $csc" }

# System.Management.Automation.dll ships with Windows PowerShell 5.1 (GAC).
$sma = Get-ChildItem 'C:\Windows\Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation' `
    -Recurse -Filter 'System.Management.Automation.dll' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $sma) { throw 'System.Management.Automation.dll not found (PowerShell 5.1 required)' }

# 1) Build the launcher (DailyTasks.exe) - runs the app in-process, no powershell.exe child.
$launcher = Join-Path $dir 'Launcher.cs'
if (-not (Test-Path -LiteralPath $launcher)) { throw "Launcher.cs not found at $launcher" }
& $csc /nologo /target:winexe /optimize+ /codepage:65001 `
    /win32icon:DailyTasks.ico `
    /win32manifest:app.manifest `
    "/r:$($sma.FullName)" `
    "/out:$(Join-Path $dir 'DailyTasks.exe')" `
    $launcher
if ($LASTEXITCODE -ne 0) { throw "launcher build failed with exit code $LASTEXITCODE" }

# 2) Build the installer (DailyTasks-Setup.exe) with the payload embedded as resources.
$files = @(
    'DailyTasks.cmd',
    'DailyTasks.ps1',
    'DailyTasks.exe',
    'DailyTasks.ico',
    'install.cmd',
    'uninstall.cmd',
    'uninstall.ps1',
    'README.txt',
    'setup.ps1',
    'sound.wav',
    'success.wav'
)

$res = $files | ForEach-Object { '/resource:' + $_ }
$out = Join-Path $dir 'DailyTasks-Setup.exe'

Push-Location $dir
try {
    & $csc /nologo /target:winexe /optimize+ /codepage:65001 `
        /win32icon:DailyTasks.ico `
        /win32manifest:app.manifest `
        "/out:$out" @res SFX.cs
    if ($LASTEXITCODE -ne 0) { throw "installer build failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}

Write-Host "DailyTasks.exe rebuilt: $(Join-Path $dir 'DailyTasks.exe')"
Write-Host "DailyTasks-Setup.exe rebuilt: $out"
