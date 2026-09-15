@echo off
setlocal
chcp 65001 >nul 2>nul
set "APPDIR=%LOCALAPPDATA%\DailyTasks"
set "OUT=%APPDIR%\diagnose.txt"
set "PSX=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%APPDIR%" mkdir "%APPDIR%" >nul 2>nul

> "%OUT%" echo ================ DailyTasks diagnose report ================
>> "%OUT%" echo date: %DATE% %TIME%

>> "%OUT%" echo.
>> "%OUT%" echo --- 1. Windows
>> "%OUT%" ver
>> "%OUT%" echo processor: %PROCESSOR_ARCHITECTURE%  os: %OS%  appdir: %APPDIR%
if exist "%PSX%" (>> "%OUT%" echo powershell.exe 5.1: FOUND) else (>> "%OUT%" echo powershell.exe 5.1: MISSING)
>> "%OUT%" echo --- Windows PowerShell 5.1 engine (System.Management.Automation) in GAC:
dir "%SystemRoot%\Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation" /s /b >> "%OUT%" 2>&1
>> "%OUT%" echo --- .NET Framework version in registry:
reg query "HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" /v Version >> "%OUT%" 2>&1

>> "%OUT%" echo.
>> "%OUT%" echo --- 2. PowerShell details
if not exist "%PSX%" goto nops
"%PSX%" -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; 'PS version: ' + $PSVersionTable.PSVersion.ToString(); 'language mode: ' + $ExecutionContext.SessionState.LanguageMode; 'appdomain: ' + [AppDomain]::CurrentDomain.FriendlyName; try { $a = [Reflection.Assembly]::Load('System.Management.Automation, Version=3.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35'); 'SMA load: OK ' + $a.Location } catch { 'SMA load FAILED: ' + $_.Exception.Message }; 'OS: ' + [Environment]::OSVersion.VersionString; '64bit OS: ' + [Environment]::Is64BitOS; 'ANSI codepage: ' + [Text.Encoding]::Default.WebName; 'culture: ' + [Globalization.CultureInfo]::CurrentCulture.Name; 'execution policy: ' + (Get-ExecutionPolicy).ToString(); 'temp: ' + [IO.Path]::GetTempPath()" >> "%OUT%" 2>&1
>> "%OUT%" echo --- execution policy list:
"%PSX%" -NoProfile -Command "Get-ExecutionPolicy -List | Format-Table -AutoSize | Out-String" >> "%OUT%" 2>&1
goto afterps
:nops
>> "%OUT%" echo Windows PowerShell 5.1 is not installed - that alone prevents the app from starting.
:afterps

>> "%OUT%" echo.
>> "%OUT%" echo --- 3. Is the app running? (single-instance mutex)
if not exist "%PSX%" goto nomutex
"%PSX%" -NoProfile -Command "try { $m = [Threading.Mutex]::OpenExisting('Global\DailyTasksApp_Hebrew'); 'mutex: EXISTS (a copy is already running, or one is stuck)' } catch { 'mutex: free (no copy running)' }" >> "%OUT%" 2>&1
:nomutex
tasklist /FI "IMAGENAME eq DailyTasks.exe" /FO TABLE >> "%OUT%" 2>&1
tasklist /FI "IMAGENAME eq powershell.exe" /FO TABLE >> "%OUT%" 2>&1

>> "%OUT%" echo.
>> "%OUT%" echo --- 4. Installed files (dir /r also reveals a Zone.Identifier = blocked download)
dir /a /r "%APPDIR%" >> "%OUT%" 2>&1
>> "%OUT%" echo --- hashes:
certutil -hashfile "%APPDIR%\DailyTasks.exe" SHA256 >> "%OUT%" 2>&1
certutil -hashfile "%APPDIR%\DailyTasks.ps1" SHA256 >> "%OUT%" 2>&1

>> "%OUT%" echo.
>> "%OUT%" echo --- 5. Shortcuts that point at the app
if not exist "%PSX%" goto noshortcuts
"%PSX%" -NoProfile -Command "$ws = New-Object -ComObject WScript.Shell; $dirs = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Startup')); foreach ($d in $dirs) { Get-ChildItem -LiteralPath $d -Filter *.lnk -Recurse -ErrorAction SilentlyContinue | ForEach-Object { try { $sc = $ws.CreateShortcut($_.FullName); if ($sc.TargetPath -like '*DailyTasks*') { $_.FullName + ' -> ' + $sc.TargetPath + ' args=[' + $sc.Arguments + '] workdir=' + $sc.WorkingDirectory } } catch {} } }" >> "%OUT%" 2>&1
:noshortcuts

>> "%OUT%" echo.
>> "%OUT%" echo --- 6. settings.json
type "%APPDIR%\settings.json" >> "%OUT%" 2>&1

>> "%OUT%" echo.
>> "%OUT%" echo --- 7. logs (last 80 lines each)
if not exist "%PSX%" goto nologs
"%PSX%" -NoProfile -Command "foreach ($n in @('launcher.log','error.log','install.log')) { $p = Join-Path $env:LOCALAPPDATA ('DailyTasks\' + $n); '--- ' + $n; if (Test-Path -LiteralPath $p) { Get-Content -LiteralPath $p -Tail 80 } else { '(missing)' } }" >> "%OUT%" 2>&1
:nologs

>> "%OUT%" echo.
>> "%OUT%" echo ================ end of report ================

cls
echo.
echo  The report was written to:
echo  %OUT%
echo.
echo  Please send this file to the developer.
echo.
pause
endlocal
