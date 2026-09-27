@echo off
rem Sets up and builds GitGud Desktop (see setup.ps1 for the options, e.g.
rem "setup -Preset full -Test"). Runs setup.ps1 even where PowerShell
rem scripts are blocked by the execution policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
exit /b %ERRORLEVEL%
