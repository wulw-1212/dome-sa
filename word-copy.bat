@echo off
rem ==========================================================================
rem  Word copy helper launcher (no folder authorization needed)
rem
rem  Double-click this file: it starts the local helper on 127.0.0.1 and then
rem  opens the copy page. Both default directories are already filled in, so
rem  you can click the copy button right away - no folder authorization step.
rem
rem  Closing the helper window stops it. Leaving it closed is fine too.
rem
rem  Usage:  word-copy.bat            start helper and open the page
rem          word-copy.bat noopen     start helper only (for automated tests)
rem ==========================================================================
setlocal
cd /d "%~dp0"
set PORT=8765

rem If the helper is already running, do not start a second one.
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $s = Invoke-RestMethod -Uri ('http://127.0.0.1:' + %PORT% + '/api/status') -TimeoutSec 2; if ($s.app -eq 'word-copy-helper') { exit 7 } } catch { }; exit 8"
if "%errorlevel%"=="7" (
  echo Helper already running.
  if /I not "%~1"=="noopen" start "" "http://127.0.0.1:%PORT%/"
  goto :eof
)

if /I not "%~1"=="noopen" (
  rem Open the browser only after the helper had time to bind the port,
  rem so the page does not fall back to authorization mode on a failed probe.
  start "" /min powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Sleep -Milliseconds 1200; Start-Process ('http://127.0.0.1:%PORT%/')"
)

echo Starting the Word copy helper on port %PORT% ...
echo This window IS the helper: close it to stop. It only listens on 127.0.0.1.
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\word-copy-server.ps1" -Port %PORT%
