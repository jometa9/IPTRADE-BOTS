@echo off
REM Script to compile copybridge.dll using Visual Studio
REM Searches for and executes vcvarsall.bat to initialize the environment

setlocal enabledelayedexpansion

REM Search for Visual Studio - try specific paths
set "VS_PATH="

REM User-specific path (D:\Program Files\Microsoft Visual Studio\18\Community)
if exist "D:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvarsall.bat" (
    set "VS_PATH=D:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvarsall.bat"
    goto :found
)

REM Search in Program Files (64-bit)
if exist "%ProgramFiles%\Microsoft Visual Studio" (
    for /f "delims=" %%v in ('dir /b /ad "%ProgramFiles%\Microsoft Visual Studio" 2^>nul') do (
        REM Try Community edition
        if exist "%ProgramFiles%\Microsoft Visual Studio\%%v\Community\VC\Auxiliary\Build\vcvarsall.bat" (
            set "VS_PATH=%ProgramFiles%\Microsoft Visual Studio\%%v\Community\VC\Auxiliary\Build\vcvarsall.bat"
            goto :found
        )
        REM Try Professional edition
        if exist "%ProgramFiles%\Microsoft Visual Studio\%%v\Professional\VC\Auxiliary\Build\vcvarsall.bat" (
            set "VS_PATH=%ProgramFiles%\Microsoft Visual Studio\%%v\Professional\VC\Auxiliary\Build\vcvarsall.bat"
            goto :found
        )
        REM Try Enterprise edition
        if exist "%ProgramFiles%\Microsoft Visual Studio\%%v\Enterprise\VC\Auxiliary\Build\vcvarsall.bat" (
            set "VS_PATH=%ProgramFiles%\Microsoft Visual Studio\%%v\Enterprise\VC\Auxiliary\Build\vcvarsall.bat"
            goto :found
        )
        REM Try BuildTools
        if exist "%ProgramFiles%\Microsoft Visual Studio\%%v\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" (
            set "VS_PATH=%ProgramFiles%\Microsoft Visual Studio\%%v\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
            goto :found
        )
    )
)

REM Search in Program Files (x86)
if exist "%ProgramFiles(x86)%\Microsoft Visual Studio" (
    for /f "delims=" %%v in ('dir /b /ad "%ProgramFiles(x86)%\Microsoft Visual Studio" 2^>nul') do (
        REM Try Community edition
        if exist "%ProgramFiles(x86)%\Microsoft Visual Studio\%%v\Community\VC\Auxiliary\Build\vcvarsall.bat" (
            set "VS_PATH=%ProgramFiles(x86)%\Microsoft Visual Studio\%%v\Community\VC\Auxiliary\Build\vcvarsall.bat"
            goto :found
        )
        REM Try Professional edition
        if exist "%ProgramFiles(x86)%\Microsoft Visual Studio\%%v\Professional\VC\Auxiliary\Build\vcvarsall.bat" (
            set "VS_PATH=%ProgramFiles(x86)%\Microsoft Visual Studio\%%v\Professional\VC\Auxiliary\Build\vcvarsall.bat"
            goto :found
        )
        REM Try Enterprise edition
        if exist "%ProgramFiles(x86)%\Microsoft Visual Studio\%%v\Enterprise\VC\Auxiliary\Build\vcvarsall.bat" (
            set "VS_PATH=%ProgramFiles(x86)%\Microsoft Visual Studio\%%v\Enterprise\VC\Auxiliary\Build\vcvarsall.bat"
            goto :found
        )
        REM Try BuildTools
        if exist "%ProgramFiles(x86)%\Microsoft Visual Studio\%%v\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" (
            set "VS_PATH=%ProgramFiles(x86)%\Microsoft Visual Studio\%%v\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
            goto :found
        )
    )
)

REM If Visual Studio not found, try using PowerShell script directly (it's more robust)
echo WARNING: vcvarsall.bat not found. Using PowerShell script directly...
echo This should work if CMake and Visual Studio are properly installed.
goto :use_powershell

:found
echo Initializing Visual Studio environment...
if "%1"=="x64" (
    call "%VS_PATH%" x64 >nul 2>&1
) else (
    call "%VS_PATH%" x86 >nul 2>&1
)

REM Verify that cmake is available
where cmake >nul 2>&1
if errorlevel 1 (
    echo ERROR: CMake not found. Install CMake or add it to PATH.
    exit /b 1
)

REM Execute PowerShell script
echo Compiling copybridge.dll...
if "%1"=="x64" (
    powershell -ExecutionPolicy Bypass -File "%~dp0build_copybridge.ps1" -Configuration Release -Architecture x64
) else (
    powershell -ExecutionPolicy Bypass -File "%~dp0build_copybridge.ps1" -Configuration Release -Architecture Win32
)
goto :end

:use_powershell
REM Execute PowerShell script directly (it will find CMake and Visual Studio automatically)
echo Compiling copybridge.dll using PowerShell...
if "%1"=="x64" (
    powershell -ExecutionPolicy Bypass -File "%~dp0build_copybridge.ps1" -Configuration Release -Architecture x64
) else (
    powershell -ExecutionPolicy Bypass -File "%~dp0build_copybridge.ps1" -Configuration Release -Architecture Win32
)

:end

if errorlevel 1 (
    echo.
    echo ERROR: Compilation failed. Check the previous messages.
    exit /b 1
)

echo.
echo Compilation completed successfully!
pause

