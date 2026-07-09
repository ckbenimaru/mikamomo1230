@echo off
chcp 65001 >nul
cd /d "D:\下载\SmartVideoDownloader"
"D:\下载\SmartVideoDownloader\yt-dlp.exe" "--cookies" "D:\下载\SmartVideoDownloader\cookies.txt" "-f" "bv*+ba/b" "--merge-output-format" "mp4" "--write-thumbnail" "--embed-thumbnail" "--embed-metadata" "--no-mtime" "--windows-filenames" "--restrict-filenames" "--retries" "10" "--fragment-retries" "10" "--concurrent-fragments" "3" "-P" "D:\下载\SmartVideoDownloader\downloads" "-o" "%(title).80s-%(id)s.%(ext)s" "https://hk.pornhub.com/view_video.php?viewkey=6a40f609a2abf" > "D:\下载\SmartVideoDownloader\logs\20260709-095922-164e70fd.log" 2>&1

