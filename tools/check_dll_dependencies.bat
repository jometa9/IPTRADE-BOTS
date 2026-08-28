@echo off
REM Script to verify copybridge.dll dependencies
echo ========================================
echo Verifying copybridge.dll dependencies
echo ========================================
echo.

set "REPO_ROOT=%~dp0.."
set "DLL_PATH=%REPO_ROOT%\dist\mt5\Libraries\copybridge.dll"

if not exist "%DLL_PATH%" (
    echo ERROR: DLL not found at: %DLL_PATH%
    echo.
    echo Build first with: tools\build_all_architectures.bat
    echo Or copy manually:
    echo   MT4: dist\mt4\Libraries\copybridge.dll -^> MQL4\Libraries\
    echo   MT5: dist\mt5\Libraries\copybridge.dll -^> MQL5\Libraries\
    pause
    exit /b 1
)

echo DLL found: %DLL_PATH%
echo.

echo Verifying common dependencies...
echo.

REM Verify Visual C++ Runtime
if exist "C:\Windows\System32\vcruntime140.dll" (
    echo [OK] vcruntime140.dll found
) else (
    echo [MISSING] vcruntime140.dll NOT found
    echo         Install: Microsoft Visual C++ 2015-2022 Redistributable (x64)
    echo         URL: https://aka.ms/vs/17/release/vc_redist.x64.exe
)

if exist "C:\Windows\System32\msvcp140.dll" (
    echo [OK] msvcp140.dll found
) else (
    echo [MISSING] msvcp140.dll NOT found
)

if exist "C:\Windows\System32\vcruntime140_1.dll" (
    echo [OK] vcruntime140_1.dll found
) else (
    echo [INFO] vcruntime140_1.dll not found (may be optional)
)

REM Verify Windows dependencies
if exist "C:\Windows\System32\ws2_32.dll" (
    echo [OK] ws2_32.dll found
) else (
    echo [ERROR] ws2_32.dll NOT found (Windows Sockets)
)

if exist "C:\Windows\System32\winhttp.dll" (
    echo [OK] winhttp.dll found
) else (
    echo [ERROR] winhttp.dll NOT found (Windows HTTP)
)

if exist "C:\Windows\System32\bcrypt.dll" (
    echo [OK] bcrypt.dll found
) else (
    echo [ERROR] bcrypt.dll NOT found (Windows Cryptography)
)

echo.
echo ========================================
echo If dependencies are missing, install Visual C++ Redistributable:
echo https://aka.ms/vs/17/release/vc_redist.x64.exe
echo ========================================
echo.

REM Try to use dumpbin if available (Visual Studio)
where dumpbin >nul 2>&1
if %errorlevel% equ 0 (
    echo.
    echo Analyzing DLL dependencies with dumpbin...
    echo.
    dumpbin /dependents "%DLL_PATH%"
) else (
    echo.
    echo To see all dependencies, install Visual Studio and run:
    echo   dumpbin /dependents "%DLL_PATH%"
    echo.
    echo Or use Dependency Walker (depends.exe) to analyze the DLL
)

pause

