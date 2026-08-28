@echo off
echo ========================================
echo Building CopyBridge DLL for all architectures
echo ========================================
echo/

REM Build MT4 (Win32) - Rebuild avoids cache and ensures DLL is up to date (heartbeat, etc.)
echo Building for MT4 (Win32)...
echo ----------------------------------------
powershell -ExecutionPolicy Bypass -File "%~dp0build_copybridge.ps1" -Configuration Release -Architecture Win32 -Rebuild
if errorlevel 1 (
    echo ERROR: MT4 build failed!
    exit /b 1
)
echo MT4 build completed successfully!
echo/

REM Build MT5 (x64)
echo Building for MT5 (x64)...
echo ----------------------------------------
powershell -ExecutionPolicy Bypass -File "%~dp0build_copybridge.ps1" -Configuration Release -Architecture x64 -Rebuild
if errorlevel 1 (
    echo ERROR: MT5 build failed!
    exit /b 1
)
echo MT5 build completed successfully!
echo/

echo ========================================
echo All architectures built successfully!
echo ========================================
echo/

REM Copy DLLs to distribution folders
echo Copying DLLs to distribution folders...

REM Create directories if they don't exist
if not exist "%~dp0..\dist\mt4\Libraries" mkdir "%~dp0..\dist\mt4\Libraries"
if not exist "%~dp0..\dist\mt5\Libraries" mkdir "%~dp0..\dist\mt5\Libraries"
if not exist "%~dp0..\dist\mt4\Include\bridge" mkdir "%~dp0..\dist\mt4\Include\bridge"
if not exist "%~dp0..\dist\mt5\Include\bridge" mkdir "%~dp0..\dist\mt5\Include\bridge"

REM Copy MT4 DLL (Win32) - dist is what deploy then copies to MT
set "DIST_MT4_DLL=%~dp0..\dist\mt4\Libraries\copybridge.dll"
if exist "%~dp0..\bridge-dll\build\Win32\Release\copybridge.dll" (
    copy /Y "%~dp0..\bridge-dll\build\Win32\Release\copybridge.dll" "%~dp0..\dist\mt4\Libraries\"
    echo MT4 DLL copied to dist\mt4\Libraries
    if exist "%DIST_MT4_DLL%" (
        echo   ^> dist\mt4\Libraries\copybridge.dll - this is the DLL that deploy installs to MT4
    )
) else (
    echo WARNING: MT4 DLL not found in build\Win32\Release
)

REM Copy MT5 DLL (x64)
if exist "%~dp0..\bridge-dll\build\x64\Release\copybridge.dll" (
    copy /Y "%~dp0..\bridge-dll\build\x64\Release\copybridge.dll" "%~dp0..\dist\mt5\Libraries\"
    echo MT5 DLL copied to dist\mt5\Libraries
) else (
    echo WARNING: MT5 DLL not found in build\x64\Release
)

REM Copy MQH include file to both architectures
if exist "%~dp0..\include\bridge\BridgeJson.mqh" (
    copy /Y "%~dp0..\include\bridge\BridgeJson.mqh" "%~dp0..\dist\mt4\Include\bridge\"
    copy /Y "%~dp0..\include\bridge\BridgeJson.mqh" "%~dp0..\dist\mt5\Include\bridge\"
    echo Include files copied to dist folders
) else (
    echo WARNING: BridgeJson.mqh not found
)

echo/
echo Distribution files updated successfully!
echo ========================================
echo/

REM Deploy to MetaTrader folders found on the system
echo Deploying to MetaTrader installations...
echo ----------------------------------------
powershell -ExecutionPolicy Bypass -File "%~dp0deploy_to_metatrader.ps1" -RepoRoot "%~dp0.."
if %errorlevel% neq 0 echo WARNING: Deploy to MetaTrader had issues (check if any MT was found).
echo/

echo ========================================
echo Installation instructions (if not auto-deployed):
echo   MT4: Copy dist\mt4\Libraries\copybridge.dll to MQL4\Libraries\
echo   MT5: Copy dist\mt5\Libraries\copybridge.dll to MQL5\Libraries\
echo ========================================
echo/
echo IMPORTANT - For the heartbeat and new DLL to load:
echo   1. Close MetaTrader completely (not just the chart).
echo   2. Reopen MT and attach the EA again.
echo   MT caches the DLL in memory; without closing it keeps using the old one.
echo ========================================
exit /b 0
