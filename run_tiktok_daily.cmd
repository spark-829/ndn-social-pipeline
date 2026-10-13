@echo off
rem Daily TikTok snapshot from this PC (TikTok blocks GitHub's IPs).
rem Run by Windows Task Scheduler task "NDN TikTok daily"; output goes to logs\tiktok_daily.log.
cd /d "%~dp0"
if not exist logs mkdir logs
py -m pip install -q -U yt-dlp >> logs\tiktok_daily.log 2>&1
py extract_tiktok.py --upload --by pc >> logs\tiktok_daily.log 2>&1
