@echo off
(
cd /d %~dp0
echo Starting Safe Git Sync...
powershell -ExecutionPolicy Bypass -File .\git-auto-sync.ps1
if errorlevel 1 (
    echo ERROR: Safe sync failed.
    exit /b 1
)
echo Safe Git Sync completed successfully.
exit /b 0
)
