@echo off
rem Source install (needs Python 3). Most players should use SlotboundOddsModInstaller.exe from Releases instead.
setlocal
chcp 65001 >nul
set PYTHONIOENCODING=utf-8
cd /d "%~dp0"
set GAME=%~1
if "%GAME%"=="" set GAME=%~dp0.
set PY=
where py >nul 2>nul && set PY=py -3
if not defined PY ( where python >nul 2>nul && set PY=python )
if not defined PY (
  echo [ERROR] Python 3 not found. Download SlotboundOddsModInstaller from the Releases page instead - it needs no Python.
  goto end
)
%PY% -m pip install --disable-pip-version-check -q cryptography
if errorlevel 1 ( echo [ERROR] Could not install the "cryptography" package. Check your network. & goto end )
%PY% slotbound_odds_patcher.py "%GAME%"
:end
echo.
pause
