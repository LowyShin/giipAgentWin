@echo off
REM Force git sync - discard local changes and pull from remote
REM This script ignores all local changes and forces download from git

cd /d %~dp0

echo Forcing git sync - discarding local changes...

REM Fetch latest changes from remote
git fetch --all

REM Get current branch name
for /f "tokens=*" %%i in ('git rev-parse --abbrev-ref HEAD') do set BRANCH=%%i

REM Discard all local changes and force reset to remote branch
git reset --hard origin/%BRANCH%

REM Clean untracked files and directories
git clean -fd

echo.
echo Git sync completed - all local changes discarded
echo Current branch: %BRANCH%
echo.
