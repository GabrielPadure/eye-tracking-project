@echo off
REM Build the AAC desktop .exe on Windows.
REM
REM Prereqs:
REM   - Python 3.11 + the backend venv at backend\.venv (see README).
REM   - Flutter SDK on PATH (for the web build).
REM   - face_landmarker.task cached at %USERPROFILE%\.cache\eyetrax\mediapipe\.
REM     Run gaze_test_eyetrax.py once if missing — eyetrax downloads it.
REM
REM Output:  backend\dist\AAC\AAC.exe  (folder distribution, ~600 MB)

setlocal
set SCRIPT_DIR=%~dp0
set PROJECT_ROOT=%SCRIPT_DIR%..
set VENV=%SCRIPT_DIR%.venv

if not exist "%VENV%\Scripts\python.exe" (
  echo ERROR: %VENV%\Scripts\python.exe not found. Set up the venv first:
  echo   cd backend ^&^& python3.11 -m venv .venv ^&^& .venv\Scripts\Activate.ps1
  echo   pip install -r requirements.txt pyinstaller
  exit /b 1
)

REM 1. Build the Flutter web app.
echo ==^> Building Flutter web (release)
pushd "%PROJECT_ROOT%\app"
call flutter build web --release || exit /b 1
popd

REM 2. PyInstaller.
echo ==^> Running PyInstaller
pushd "%SCRIPT_DIR%"
"%VENV%\Scripts\pyinstaller.exe" --noconfirm aac_app.spec || exit /b 1
popd

echo.
echo ==^> Built: %SCRIPT_DIR%dist\AAC\AAC.exe
echo     Run:  "%SCRIPT_DIR%dist\AAC\AAC.exe"
echo.
echo NOTE: Windows Defender SmartScreen will warn on first launch
echo       because the .exe is unsigned. Click "More info" then
echo       "Run anyway" to bypass.

endlocal
