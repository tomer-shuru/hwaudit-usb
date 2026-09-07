@echo off
REM Double-click me. Finds the connected BLANCCO stick and installs onto it.
REM Pass -DryRun to see what would happen without writing anything.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-to-stick.ps1" %*
echo.
pause
