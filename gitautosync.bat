@echo off
REM Force git sync - discard local changes and pull from remote
REM This script ignores all local changes and forces download from git

cd /d %~dp0

echo Forcing git sync - discarding local changes...
echo.

REM Fetch latest changes from remote
echo Fetching from remote repository...
git fetch --all
if errorlevel 1 (
    echo ERROR: Failed to fetch from remote repository
    exit /b 1
)
echo Fetch completed successfully.
echo.

REM Get current branch name
echo Detecting current branch...
for /f "tokens=*" %%i in ('git rev-parse --abbrev-ref HEAD 2^>nul') do set BRANCH=%%i
if "%BRANCH%"=="" (
    echo ERROR: Failed to detect current branch
    exit /b 1
)
echo Current branch: %BRANCH%
echo.

REM Discard all local changes and force reset to remote branch
echo Resetting to remote branch state...
git reset --hard "origin/%BRANCH%"
if errorlevel 1 (
    echo ERROR: Failed to reset to remote branch
    exit /b 1
)
echo Reset completed successfully.
echo.

REM Clean untracked files and directories
echo Cleaning untracked files...
git clean -fd
if errorlevel 1 (
    echo ERROR: Failed to clean untracked files
    exit /b 1
)
echo Clean completed successfully.
echo.

echo ============================================
echo Git sync completed - all local changes discarded
echo Branch: %BRANCH%
echo ============================================
echo.

exit /b 0
