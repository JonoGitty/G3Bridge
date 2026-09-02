@echo off
REM Build the Backrooms Tape SWF for Flash Player 10.1 with Haxe.
REM   tools\build_backrooms.cmd            release build
REM   tools\build_backrooms.cmd -debug     with debug info
cd /d "%~dp0\.."
C:\AI\tools\haxe\haxe.exe -cp src\backrooms -main Main -swf www\games\backrooms\backrooms.swf -swf-version 10.1 -D swf-header=1024:617:24:000000 -D swf-metadata=backrooms-tape %*
if errorlevel 1 (echo BUILD FAILED & exit /b 1)
for %%F in (www\games\backrooms\backrooms.swf) do echo built %%~zF bytes
