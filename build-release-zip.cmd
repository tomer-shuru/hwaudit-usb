@echo off
REM For Tomer, not for coworkers. Builds the self-contained zip to attach to a
REM GitHub Release. Plug in a Blancco stick first - the ISO is taken from it.
REM   build-release-zip.cmd -Tag v1.0
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-release-zip.ps1" %*
echo.
pause
