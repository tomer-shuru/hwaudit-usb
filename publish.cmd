@echo off
REM For Tomer, not for coworkers. Pushes the current version to the network share.
REM First time:  publish.cmd -Share \\fileserver\it\hwaudit
REM After that:  just double-click me.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish-to-share.ps1" %*
echo.
pause
