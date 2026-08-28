<#
.SYNOPSIS
  Finds MetaTrader 4/5 installations on the system and copies copybridge.dll and BridgeJson.mqh.
.DESCRIPTION
  After a "build all architectures", run this script to deploy the files to all
  MQL4/MQL5 folders found (Program Files and AppData\MetaQuotes\Terminal).
  If your MT is in another path, use -Mql4Path or -Mql5Path to install there too.
.PARAMETER RepoRoot
  Repository root path (default: parent directory of tools).
.PARAMETER Mql4Path
  Extra path to MQL4\Libraries (e.g. D:\MyMT4\MQL4). DLL is copied to Mql4Path\Libraries\copybridge.dll
.PARAMETER Mql5Path
  Extra path to MQL5\Libraries (e.g. D:\MyMT5\MQL5).
.PARAMETER WhatIf
  Only show what would be copied, without copying.
#>
param(
    [string]$RepoRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) ''),
    [string]$Mql4Path = '',
    [string]$Mql5Path = '',
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

# Source paths (project dist)
$distMt4Libraries = Join-Path $RepoRoot 'dist\mt4\Libraries\copybridge.dll'
$distMt5Libraries = Join-Path $RepoRoot 'dist\mt5\Libraries\copybridge.dll'
$distMqh          = Join-Path $RepoRoot 'include\bridge\BridgeJson.mqh'

# Paths to search for MetaTrader terminals
$searchRoots = @(
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    (Join-Path $env:APPDATA 'MetaQuotes\Terminal')
)

function Find-MetaTraderFolders {
    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($root in $searchRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        try {
            $dirs = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue
        } catch {
            continue
        }
        foreach ($d in $dirs) {
            $mql4 = Join-Path $d.FullName 'MQL4'
            $mql5 = Join-Path $d.FullName 'MQL5'
            if (Test-Path (Join-Path $mql4 'Libraries')) {
                $found.Add([PSCustomObject]@{ Type = 'MT4'; Root = $d.FullName; MqlPath = $mql4 })
            }
            if (Test-Path (Join-Path $mql5 'Libraries')) {
                $found.Add([PSCustomObject]@{ Type = 'MT5'; Root = $d.FullName; MqlPath = $mql5 })
            }
        }
    }
    return $found
}

function Deploy-ToMetaTrader {
    if (-not (Test-Path $distMt4Libraries)) {
        Write-Warning "Not found: $distMt4Libraries. Run first: tools\build_all_architectures.bat"
    }
    if (-not (Test-Path $distMt5Libraries)) {
        Write-Warning "Not found: $distMt5Libraries. Run first: tools\build_all_architectures.bat"
    }
    if (-not (Test-Path $distMqh)) {
        Write-Warning "Not found: $distMqh"
    }

    $folders = Find-MetaTraderFolders

    # Add manual paths if provided
    if ($Mql4Path -and (Test-Path $Mql4Path)) {
        $lib = Join-Path $Mql4Path 'Libraries'
        if (-not (Test-Path $lib)) { New-Item -ItemType Directory -Path $lib -Force | Out-Null }
        $folders.Add([PSCustomObject]@{ Type = 'MT4'; Root = $Mql4Path; MqlPath = $Mql4Path })
        Write-Host "Additional MT4 path: $Mql4Path" -ForegroundColor Cyan
    }
    if ($Mql5Path -and (Test-Path $Mql5Path)) {
        $lib = Join-Path $Mql5Path 'Libraries'
        if (-not (Test-Path $lib)) { New-Item -ItemType Directory -Path $lib -Force | Out-Null }
        $folders.Add([PSCustomObject]@{ Type = 'MT5'; Root = $Mql5Path; MqlPath = $Mql5Path })
        Write-Host "Additional MT5 path: $Mql5Path" -ForegroundColor Cyan
    }

    if ($folders.Count -eq 0) {
        Write-Host "No MetaTrader installation found (MQL4/MQL5 with Libraries folder)." -ForegroundColor Yellow
        Write-Host "Paths searched: $($searchRoots -join ', ')" -ForegroundColor Gray
        Write-Host "You can pass -Mql4Path 'C:\path\to\MQL4' to install to a specific path." -ForegroundColor Cyan
        return
    }

    Write-Host "Installations where DLL will be copied: $($folders.Count)" -ForegroundColor Cyan
    foreach ($f in $folders) {
        $libDir = Join-Path $f.MqlPath 'Libraries'
        Write-Host "  - $($f.Type): $libDir" -ForegroundColor Gray
    }
    Write-Host ""

    $copied = 0
    foreach ($f in $folders) {
        $libDir   = Join-Path $f.MqlPath 'Libraries'
        $incDir   = Join-Path $f.MqlPath 'Include\bridge'
        $dllDest  = Join-Path $libDir 'copybridge.dll'
        $mqhDest  = Join-Path $incDir 'BridgeJson.mqh'

        if ($f.Type -eq 'MT4') {
            $srcDll = $distMt4Libraries
        } else {
            $srcDll = $distMt5Libraries
        }

        if ($WhatIf) {
            if (Test-Path $srcDll) { Write-Host "[WhatIf] Would copy DLL -> $dllDest" -ForegroundColor DarkCyan }
            if (Test-Path $distMqh) { Write-Host "[WhatIf] Would copy MQH -> $mqhDest" -ForegroundColor DarkCyan }
            $copied++
            continue
        }

        try {
            if (Test-Path $srcDll) {
                if (-not (Test-Path $libDir)) { New-Item -ItemType Directory -Path $libDir -Force | Out-Null }
                Copy-Item -Path $srcDll -Destination $dllDest -Force
                $dllInfo = Get-Item $dllDest
                Write-Host "  OK DLL -> $($f.Type)" -ForegroundColor Green
                Write-Host "      $dllDest" -ForegroundColor DarkGray
                Write-Host "      (updated: $($dllInfo.LastWriteTime))" -ForegroundColor DarkGray
                $copied++
            }
            if (Test-Path $distMqh) {
                if (-not (Test-Path $incDir)) { New-Item -ItemType Directory -Path $incDir -Force | Out-Null }
                Copy-Item -Path $distMqh -Destination $mqhDest -Force
                Write-Host "  OK MQH -> $($f.Type) $incDir" -ForegroundColor Green
            }
        } catch {
            Write-Warning "  Error at $($f.Root): $_"
        }
    }

    if (-not $WhatIf -and $copied -gt 0) {
        Write-Host ""
        Write-Host "Deploy completed. Close MetaTrader completely and reopen it so the new DLL is loaded." -ForegroundColor Green
    }
    if (-not $WhatIf -and $folders.Count -eq 0 -and (-not $Mql4Path -and -not $Mql5Path)) {
        Write-Host "If your MT is in another folder, run:" -ForegroundColor Yellow
        Write-Host "  .\deploy_to_metatrader.ps1 -Mql4Path 'C:\full\path\to\MQL4'" -ForegroundColor Cyan
    }
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Deploying CopyBridge to MetaTrader" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Repo: $RepoRoot" -ForegroundColor Gray
if ($WhatIf) { Write-Host "WhatIf mode: nothing will be copied." -ForegroundColor Yellow }
Write-Host ""

Deploy-ToMetaTrader
exit 0
