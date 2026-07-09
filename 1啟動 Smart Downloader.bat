@echo off
chcp 65001 >nul
title Smart Video Downloader
cd /d "%~dp0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0SmartVideoDownloader.ps1"
exit






