@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-box-win.ps1" %*
exit /b %ERRORLEVEL%
