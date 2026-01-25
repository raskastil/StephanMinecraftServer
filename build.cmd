@echo off
setlocal
set SCRIPT=%~dp0scripts\build.ps1
powershell -ExecutionPolicy Bypass -File "%SCRIPT%" %*
