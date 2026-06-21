@echo off
title Folder Size Browser
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0FindBigFiles.ps1"
if errorlevel 1 pause
