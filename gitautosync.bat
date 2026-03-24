@echo off
REM Safe git sync wrapper for PowerShell script
REM This version delegates the sync logic to git-auto-sync.ps1 (v1.3.8+)

cd /d %~dp0

echo Starting Safe Git Sync...
powershell -ExecutionPolicy Bypass -File .\git-auto-sync.ps1
if errorlevel 1 (
    echo ERROR: Safe sync failed.
    exit /b 1
)

echo Safe Git Sync completed successfully.
exit /b 0
