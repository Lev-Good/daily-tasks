@echo off
setlocal
where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo PowerShell was not found. DailyTasks requires Windows PowerShell 5.1.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
pause
