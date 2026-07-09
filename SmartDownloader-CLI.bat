@echo off
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion
title Smart Video Downloader CLI

cd /d "%~dp0"

if exist "%~dp0yt-dlp.exe" (
    set "YTDLP=%~dp0yt-dlp.exe"
) else (
    set "YTDLP=yt-dlp.exe"
)

set "PROXY=socks5://127.0.0.1:7898"
set "COOKIES=cookies.txt"
set "OUTDIR=%~dp0downloads"
set "MAX_PARALLEL=3"
set "FRAGMENTS=8"

if not exist "%OUTDIR%" mkdir "%OUTDIR%"
if not exist "%~dp0logs" mkdir "%~dp0logs"

echo ========================================
echo        Smart Video Downloader CLI
echo ========================================
echo.
echo 可一次輸入多條網址；輸入空白行後開始下載。
echo 目前設定：同時下載 %MAX_PARALLEL% 條，單條影片分段併發 %FRAGMENTS%。
echo.

set /a COUNT=0
:READ_URL
set "URL="
set /p URL=影片網址：
if "%URL%"=="" goto START_DOWNLOADS
set /a COUNT+=1
set "URL_!COUNT!=%URL%"
goto READ_URL

:START_DOWNLOADS
if "%COUNT%"=="0" (
    echo 沒有輸入網址。
    pause
    exit /b
)

echo.
echo 建立 %COUNT% 個下載任務...
echo.

set /a INDEX=1
:QUEUE_LOOP
if %INDEX% GTR %COUNT% goto WAIT_ALL

call set "URL=%%URL_%INDEX%%%"
call :WAIT_SLOT

set "LOG=%~dp0logs\download-%DATE:/=-%-%TIME::=-%-%INDEX%.log"
set "LOG=%LOG: =0%"

start "Download %INDEX%" /min cmd /c ""%YTDLP%" --proxy "%PROXY%" --cookies "%COOKIES%" -f "bv*+ba/b" --merge-output-format mp4 --write-thumbnail --embed-thumbnail --embed-metadata --no-mtime --windows-filenames --restrict-filenames --retries 10 --fragment-retries 10 --concurrent-fragments %FRAGMENTS% -P "%OUTDIR%" -o "%%(title).80s-%%(id)s.%%(ext)s" "%URL%" > "%LOG%" 2>&1"

echo 已開始：%URL%
set /a INDEX+=1
goto QUEUE_LOOP

:WAIT_SLOT
for /f %%P in ('tasklist /v /fi "WINDOWTITLE eq Download *" ^| find /c "cmd.exe"') do set "RUNNING=%%P"
if not defined RUNNING set "RUNNING=0"
if %RUNNING% GEQ %MAX_PARALLEL% (
    timeout /t 2 /nobreak >nul
    goto WAIT_SLOT
)
exit /b

:WAIT_ALL
echo.
echo 所有任務已派發，下載會在背景視窗繼續進行。
echo 檔案位置：%OUTDIR%
echo 記錄位置：%~dp0logs
pause






