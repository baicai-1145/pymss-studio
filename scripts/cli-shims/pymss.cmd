@echo off
setlocal
rem Pymss Studio CLI bridge: run the pymss CLI inside the app's managed runtime.
rem The active environment is resolved at call time, so moving the install directory,
rem switching backends, or reinstalling never breaks the command.
set "SCRIPT_DIR=%~dp0"
set "RUNTIME_ENVS=%SCRIPT_DIR%..\python-runtime\runtime-envs"
set "ACTIVE=%RUNTIME_ENVS%\active-runtime.json"

set "PY="
if exist "%ACTIVE%" (
  for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "try { (Get-Content -Raw -LiteralPath '%ACTIVE%' | ConvertFrom-Json).pythonPath } catch { }" 2^>nul`) do (
    if exist "%%~P" set "PY=%%~P"
  )
)
if not defined PY (
  for /d %%D in ("%RUNTIME_ENVS%\*") do (
    if not defined PY if exist "%%~D\Scripts\python.exe" set "PY=%%~D\Scripts\python.exe"
  )
)
if not defined PY (
  echo Pymss Studio: no managed runtime environment found. Start Pymss Studio once and install the dependencies first. 1>&2
  exit /b 1
)

rem Share the app's model cache when it lives in the default location; a model directory
rem the user configured themselves wins. Portable installs keep data next to the app,
rem installed installs use the roaming app-data directory.
set "DATA_ROOT="
if exist "%SCRIPT_DIR%..\data" set "DATA_ROOT=%SCRIPT_DIR%..\data"
if not defined DATA_ROOT if exist "%APPDATA%\studio.pymss.desktop" set "DATA_ROOT=%APPDATA%\studio.pymss.desktop"
if defined DATA_ROOT (
  if not defined PYMSS_MODEL_DIR if exist "%DATA_ROOT%\models" set "PYMSS_MODEL_DIR=%DATA_ROOT%\models"
  if not defined PYMSS_USER_MODELS if exist "%DATA_ROOT%\settings\user_models.json" set "PYMSS_USER_MODELS=%DATA_ROOT%\settings\user_models.json"
)

"%PY%" -m pymss %*
