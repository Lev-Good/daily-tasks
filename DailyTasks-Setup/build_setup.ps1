# Rebuilds DailyTasks-Setup.exe from the payload files in this folder.
# Requires the .NET Framework compiler (csc.exe) that ships with Windows.
$ErrorActionPreference = 'Stop'

$dir = $PSScriptRoot
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw "csc.exe not found at $csc" }

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
    'success.wav',
    'tasks.json'
)

$res = $files | ForEach-Object { '/resource:' + $_ }
$out = Join-Path $dir 'DailyTasks-Setup.exe'

Push-Location $dir
try {
    & $csc /nologo /target:winexe /optimize+ /codepage:65001 `
        "/out:$out" @res SFX.cs
    if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}

Write-Host "DailyTasks-Setup.exe rebuilt: $out"
