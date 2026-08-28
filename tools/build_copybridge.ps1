param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [ValidateSet("Win32", "x64")]
    [string]$Architecture = "Win32",
    [string]$Generator = "Visual Studio 17 2022",
    [switch]$Rebuild  # Force full rebuild (avoids stale object cache)
)

$ErrorActionPreference = "Stop"

function Find-CMake {
    # Search for cmake in PATH first
    $cmake = Get-Command cmake -ErrorAction SilentlyContinue
    if ($cmake) {
        return $cmake.Path
    }
    
    # Search in common CMake locations
    $commonPaths = @(
        "C:\Program Files\CMake\bin\cmake.exe",
        "C:\Program Files (x86)\CMake\bin\cmake.exe",
        "$env:ProgramFiles\CMake\bin\cmake.exe",
        "$env:ProgramFiles(x86)\CMake\bin\cmake.exe"
    )
    
    foreach ($path in $commonPaths) {
        if (Test-Path $path) {
            return $path
        }
    }
    
    # Search in Visual Studio
    $vsPaths = @(
        "$env:ProgramFiles\Microsoft Visual Studio\*\*\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
        "$env:ProgramFiles(x86)\Microsoft Visual Studio\*\*\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
    )
    
    foreach ($pattern in $vsPaths) {
        $found = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            return $found.FullName
        }
    }
    
    return $null
}

function Find-MSBuild {
    # Search for MSBuild in PATH first
    $msbuild = Get-Command msbuild -ErrorAction SilentlyContinue
    if ($msbuild) {
        return $msbuild.Path
    }
    
    # Search in Visual Studio
    $vsPaths = @(
        "$env:ProgramFiles\Microsoft Visual Studio\*\*\MSBuild\Current\Bin\MSBuild.exe",
        "$env:ProgramFiles(x86)\Microsoft Visual Studio\*\*\MSBuild\Current\Bin\MSBuild.exe",
        "$env:ProgramFiles\Microsoft Visual Studio\*\*\MSBuild\*\Bin\MSBuild.exe",
        "$env:ProgramFiles(x86)\Microsoft Visual Studio\*\*\MSBuild\*\Bin\MSBuild.exe"
    )
    
    foreach ($pattern in $vsPaths) {
        $found = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            return $found.FullName
        }
    }
    
    return $null
}

function Find-VisualStudioGenerator {
    # Search for Visual Studio in multiple locations
    $vsPaths = @(
        "D:\Program Files\Microsoft Visual Studio",
        "D:\Program Files (x86)\Microsoft Visual Studio",
        "$env:ProgramFiles\Microsoft Visual Studio",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio",
        "C:\Program Files\Microsoft Visual Studio",
        "C:\Program Files (x86)\Microsoft Visual Studio"
    )
    
    foreach ($vsBasePath in $vsPaths) {
        if (Test-Path $vsBasePath) {
            $vsVersions = Get-ChildItem -Path $vsBasePath -Directory -ErrorAction SilentlyContinue | 
                Where-Object { $_.Name -match '^\d+$' } | 
                Sort-Object { [int]$_.Name } -Descending
            
            foreach ($vsVersion in $vsVersions) {
                $versionNum = [int]$vsVersion.Name
                $editions = @('Community', 'Professional', 'Enterprise', 'BuildTools')
                
                foreach ($edition in $editions) {
                    $vsPath = Join-Path $vsVersion.FullName $edition
                    if (Test-Path $vsPath) {
                        Write-Host "Found Visual Studio at: $vsPath (version $versionNum)" -ForegroundColor Cyan
                        # Map VS version to CMake generator
                        # Folder "18" -> "Visual Studio 18 2026" (VS 2024 preview)
                        # Folder "17" or "2022" -> "Visual Studio 17 2022"
                        # Folder "16" or "2019" -> "Visual Studio 16 2019"
                        # Folder "15" or "2017" -> "Visual Studio 15 2017"
                        if ($versionNum -eq 18) {
                            return "Visual Studio 18 2026"
                        } elseif ($versionNum -eq 2022 -or $versionNum -eq 17) {
                            return "Visual Studio 17 2022"
                        } elseif ($versionNum -eq 2019 -or $versionNum -eq 16) {
                            return "Visual Studio 16 2019"
                        } elseif ($versionNum -eq 2017 -or $versionNum -eq 15) {
                            return "Visual Studio 15 2017"
                        }
                    }
                }
            }
        }
    }
    
    # Default fallback
    return "Visual Studio 17 2022"
}

$repoRoot = Resolve-Path "$PSScriptRoot\.."
$projectDir = Join-Path $repoRoot "bridge-dll"
$buildDir = Join-Path $projectDir "build\$Architecture"
$solutionFile = Join-Path $buildDir "copybridge.sln"

# Try to find CMake first
$cmakeExe = Find-CMake
$useMSBuild = $false

if ($cmakeExe) {
    Write-Host "Using CMake: $cmakeExe" -ForegroundColor Green
    
    # Auto-detect Visual Studio generator if not explicitly provided or if default
    if ($Generator -eq "Visual Studio 17 2022") {
        $detectedGenerator = Find-VisualStudioGenerator
        if ($detectedGenerator) {
            $Generator = $detectedGenerator
            Write-Host "Auto-detected Visual Studio generator: $Generator" -ForegroundColor Cyan
        }
    }
    
    if (-not (Test-Path $buildDir)) {
        New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
    }
} elseif (Test-Path $solutionFile) {
    # CMake not found, but solution file exists - use MSBuild directly
    $msbuildExe = Find-MSBuild
    if ($msbuildExe) {
        Write-Host "CMake not found, but solution file exists. Using MSBuild directly." -ForegroundColor Yellow
        Write-Host "Using MSBuild: $msbuildExe" -ForegroundColor Green
        $useMSBuild = $true
    } else {
        throw "CMake not found and MSBuild not found. Please install CMake or Visual Studio with C++ tools."
    }
} else {
    throw "CMake not found and no existing solution file. Please install CMake to generate build files."
}

Push-Location $projectDir
try {
    if (-not $useMSBuild) {
        Write-Host "== Configuring CMake ($Generator | $Architecture | $Configuration)=="
        & $cmakeExe -B $buildDir -S . -G $Generator -A $Architecture

        if ($Rebuild) {
            Write-Host "== Clean (Rebuild) ==" -ForegroundColor Yellow
            & $cmakeExe --build $buildDir --config $Configuration --target clean
        }
        Write-Host "== Compiling copybridge.dll =="
        & $cmakeExe --build $buildDir --config $Configuration
    } else {
        # Use MSBuild directly - build only the copybridge project to avoid ZERO_CHECK issues
        $platform = if ($Architecture -eq "Win32") { "Win32" } else { "x64" }
        $projectFile = Join-Path $buildDir "copybridge.vcxproj"
        $releaseDir = Join-Path $buildDir "$Configuration"
        if ($Rebuild) {
            Write-Host "== Full rebuild: clearing previous output (avoids cache) ==" -ForegroundColor Yellow
            if (Test-Path $releaseDir) {
                Remove-Item -Path (Join-Path $releaseDir "*.obj") -Force -ErrorAction SilentlyContinue
                Remove-Item -Path (Join-Path $releaseDir "copybridge.dll") -Force -ErrorAction SilentlyContinue
            }
        }
        if (Test-Path $projectFile) {
            Write-Host "== Compiling copybridge.dll with MSBuild ($platform | $Configuration)=="
            & $msbuildExe $projectFile /p:Configuration=$Configuration /p:Platform=$platform /m /t:Build
        } else {
            Write-Host "== Compiling copybridge.dll with MSBuild ($platform | $Configuration)=="
            & $msbuildExe $solutionFile /p:Configuration=$Configuration /p:Platform=$platform /m /t:copybridge
        }
    }

    $output = Join-Path $buildDir "$Configuration\copybridge.dll"
    if (Test-Path $output) {
        Write-Host "DLL generated at: $output"
        
        # Map architecture to MetaTrader folder name
        $mtFolder = if ($Architecture -eq "Win32") { "mt4" } else { "mt5" }
        
        # Create distribution folder with MetaTrader structure
        $distDir = Join-Path $repoRoot "dist\$mtFolder"
        if (-not (Test-Path $distDir)) {
            New-Item -ItemType Directory -Force -Path $distDir | Out-Null
        }
        
        # Create Libraries folder (for DLL)
        $librariesDir = Join-Path $distDir "Libraries"
        if (-not (Test-Path $librariesDir)) {
            New-Item -ItemType Directory -Force -Path $librariesDir | Out-Null
        }
        
        # Copy DLL to Libraries folder
        $distDll = Join-Path $librariesDir "copybridge.dll"
        Copy-Item -Path $output -Destination $distDll -Force
        Write-Host "DLL copied to: $distDll"
        
        # Verify DLL was copied and show file info
        if (Test-Path $distDll) {
            $dllInfo = Get-Item $distDll
            Write-Host "DLL size: $($dllInfo.Length) bytes" -ForegroundColor Yellow
            Write-Host "DLL modified: $($dllInfo.LastWriteTime)" -ForegroundColor Yellow
        } else {
            Write-Warning "DLL copy verification failed!"
        }
        
        # Create Include folder structure (for MQL headers)
        $includeDestDir = Join-Path $distDir "Include\bridge"
        if (-not (Test-Path $includeDestDir)) {
            New-Item -ItemType Directory -Force -Path $includeDestDir | Out-Null
        }
        
        # Copy MQL header to Include folder
        $includeSource = Join-Path $repoRoot "include\bridge\BridgeJson.mqh"
        $includeDest = Join-Path $includeDestDir "BridgeJson.mqh"
        if (Test-Path $includeSource) {
            Copy-Item -Path $includeSource -Destination $includeDest -Force
            Write-Host "Header copied to: $includeDest"
            
            # Verify header was copied
            if (Test-Path $includeDest) {
                $headerInfo = Get-Item $includeDest
                Write-Host "Header size: $($headerInfo.Length) bytes" -ForegroundColor Yellow
                Write-Host "Header modified: $($headerInfo.LastWriteTime)" -ForegroundColor Yellow
            }
        } else {
            Write-Warning "Header source not found at: $includeSource"
        }
        
        Write-Host ""
        Write-Host "=== Files ready to use in the bots ===" -ForegroundColor Green
        Write-Host "Distribution folder: $distDir" -ForegroundColor Green
        Write-Host "  Structure matches MetaTrader folders:" -ForegroundColor Cyan
        Write-Host "    Libraries\copybridge.dll -> Copy to MQL4/MQL5\Libraries\" -ForegroundColor Cyan
        Write-Host "    Include\bridge\BridgeJson.mqh -> Copy to MQL4/MQL5\Include\bridge\" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "IMPORTANT: After copying to MT4, restart MT4 or reload the EA!" -ForegroundColor Red
        Write-Host "  MT4 caches DLLs in memory, so changes won't take effect until restart." -ForegroundColor Red
        Write-Host ""
    } else {
        Write-Warning "copybridge.dll not found at $output. Check the previous messages."
    }
}
finally {
    Pop-Location
}

