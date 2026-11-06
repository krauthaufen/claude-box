@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-box.ps1" %*
exit /b %ERRORLEVEL%
