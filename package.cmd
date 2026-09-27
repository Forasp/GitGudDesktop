@echo off
rem Packages the release build (see package.ps1: -Publish commits it to the
rem `dist` branch, -Push also pushes that branch). Runs package.ps1 even where
rem PowerShell scripts are blocked by the execution policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0package.ps1" %*
exit /b %ERRORLEVEL%
