@echo off
rem Packages the release build into build\dist\GitGud and GitGud-win64.zip
rem (see package.ps1). Runs package.ps1 even where PowerShell scripts are
rem blocked by the execution policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0package.ps1" %*
exit /b %ERRORLEVEL%
