@echo off
REM G3Bridge - start the daemon that the iMac G3 dials into.
REM Must run on Windows Python: WSL2 is NAT-ed and unreachable from the cable.
title G3Bridge daemon
cd /d "%~dp0"
if not exist "C:\Python310\python.exe" (
  echo Cannot find C:\Python310\python.exe
  pause
  exit /b 1
)
echo.
echo   G3Bridge
echo   ========
echo   agent port   0.0.0.0:9990   ^<- the iMac connects here
echo   control port 127.0.0.1:9991 ^<- Claude connects here
echo.
C:\Python310\python.exe host\g3d.py
pause
