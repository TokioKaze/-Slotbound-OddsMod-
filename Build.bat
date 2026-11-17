@echo off
rem Build SlotboundOddsModSetup.exe (folder build) with PyInstaller. Run on Windows with Python 3.
rem Full output is written to build_log.txt.
setlocal
rem Keep in sync with MOD_VERSION in SlotboundOddsMod.lua
set VER=1.3.1
set REL=SlotboundOddsMod_v%VER%
cd /d "%~dp0"
echo Building... (details in build_log.txt)
call :main > build_log.txt 2>&1
set RC=%errorlevel%
type build_log.txt
echo.
if "%RC%"=="0" ( echo [OK] Installer: dist\SlotboundOddsModSetup.exe ) else ( echo [FAILED] See build_log.txt )
if not "%~1"=="nopause" pause
exit /b %RC%

:main
set PY=
where py >nul 2>nul && set PY=py -3
if not defined PY ( where python >nul 2>nul && set PY=python )
if not defined PY ( echo [ERROR] Python 3 not found. & exit /b 1 )
%PY% --version
%PY% -m pip install --disable-pip-version-check -q -r requirements-build.txt
if errorlevel 1 ( echo [ERROR] pip install failed. & exit /b 1 )
%PY% -m PyInstaller --noconfirm --clean --onefile --noconsole --name SlotboundOddsModSetup --add-data "SlotboundOddsMod.lua;." --add-data "SlotboundOddsMod.ini;." SlotboundOddsModInstaller.py
if errorlevel 1 ( echo [ERROR] PyInstaller failed. & exit /b 1 )
start /wait "" "dist\SlotboundOddsModSetup.exe" --selftest
if errorlevel 1 ( echo [ERROR] Self-test failed. See %%LOCALAPPDATA%%\SlotboundOddsMod\installer.log & exit /b 1 )
echo [DONE] Single-file installer: dist\SlotboundOddsModSetup.exe
exit /b 0
