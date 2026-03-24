echo Calling gitautosync.bat...
call gitautosync.bat
if errorlevel 1 (
    echo ERROR: Sync failed. Agent will not start.
    pause
    exit /b 1
)

echo Starting giipAgent3.ps1...
powershell -ExecutionPolicy Bypass -File .\giipAgent3.ps1
echo giipAgent3.ps1 execution ended (ExitCode: %ERRORLEVEL%)
pause
