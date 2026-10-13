@echo off
rem Backup daily TikTok snapshot from this PC (main run: GitHub Actions 01:00 UTC; this one says already_done if that worked).
rem Run by Windows Task Scheduler task "NDN TikTok daily"; output goes to logs\tiktok_daily.log.
cd /d "%~dp0"
if not exist logs mkdir logs
py -m pip install -q -U "yt-dlp[default,curl-cffi]" >> logs\tiktok_daily.log 2>&1
py extract_tiktok.py --upload --by pc >> logs\tiktok_daily.log 2>&1
