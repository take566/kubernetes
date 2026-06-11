#Requires -Version 5.1
<#
.SYNOPSIS
  Windows-side WSL AMD GPU passthrough checks and guided recovery.
.DESCRIPTION
  Does NOT run wsl --shutdown automatically (requires user consent).
  Checks driver version, .wslconfig, WSL version, and runs diagnose-wsl-gpu.sh in WSL.
.EXAMPLE
  .\scripts\fix-wsl-gpu-passthrough.ps1
  .\scripts\fix-wsl-gpu-passthrough.ps1 -Distro Ubuntu-24.04
#>
[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu-24.04'
)

$ErrorActionPreference = 'Continue'

function Normalize-WslText([string]$text) {
    if (-not $text) { return '' }
    return ($text -replace "`0", '').Trim()
}

function Get-RepoRoot {
    $root = Split-Path -Parent $PSScriptRoot
    return (Resolve-Path $root).Path
}

function Convert-ToWslPath([string]$WindowsPath) {
    $full = (Resolve-Path $WindowsPath).Path
    if ($full -match '^([A-Za-z]):\\(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = ($Matches[2] -replace '\\', '/')
        return "/mnt/$drive/$rest"
    }
    return ($full -replace '\\', '/')
}

function Test-WslDevice {
    param([string]$DistroName, [string]$Device)
    wsl -d $DistroName -e test -e $Device 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

Write-Host '=== WSL AMD GPU Passthrough (Windows) ===' -ForegroundColor Cyan

# GPU on Windows
$gpus = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'AMD|Radeon' }
if (-not $gpus) {
    Write-Host 'WARN: No AMD GPU detected on Windows' -ForegroundColor Yellow
} else {
    foreach ($g in $gpus) {
        Write-Host ("GPU: {0}" -f $g.Name)
        Write-Host ("  DriverVersion: {0}" -f $g.DriverVersion)
        $isRx5700 = $g.Name -match '5700|5600|5500|Navi 10|RDNA'
        if ($isRx5700) {
            Write-Host '  RX 5000 (gfx1010): NOT in AMD WSL ROCm 7.2 support matrix' -ForegroundColor Yellow
            Write-Host '  /dev/kfd missing is EXPECTED — use Windows Ollama for GPU inference' -ForegroundColor Yellow
        }
        # WSL ROCm 7.2 requires Adrenalin 26.1.1 for WSL2 (driver branch, not just display driver)
        $drv = $g.DriverVersion
        if ($drv -and $drv -notmatch '^32\.0\.2[6-9]|^32\.0\.3') {
            Write-Host '  Note: WSL ROCm needs AMD Software: Adrenalin Edition 26.1.1 for WSL2' -ForegroundColor DarkYellow
            Write-Host '  https://rocm.docs.amd.com/projects/radeon-ryzen/en/docs-7.2/docs/install/installrad/wsl/install-radeon.html' -ForegroundColor DarkGray
        }
    }
}

Write-Host "`n--- WSL version ---" -ForegroundColor Cyan
try {
    wsl --version 2>&1 | ForEach-Object { Write-Host "  $_" }
} catch {
    Write-Host '  wsl --version unavailable (update WSL: wsl --update)' -ForegroundColor Yellow
}

Write-Host "`n--- .wslconfig ---" -ForegroundColor Cyan
$wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
if (Test-Path $wslConfig) {
    Get-Content $wslConfig | ForEach-Object { Write-Host "  $_" }
    if ((Get-Content $wslConfig -Raw) -match 'gpuSupport\s*=\s*false') {
        Write-Host '  WARN: gpuSupport=false disables WSL GPU — remove or set true' -ForegroundColor Red
    }
} else {
    Write-Host '  (not present — default GPU support enabled on WSL 2.7+)' -ForegroundColor DarkGray
}

Write-Host "`n--- WSL device nodes ---" -ForegroundColor Cyan
$dxg = Test-WslDevice $Distro '/dev/dxg'
$kfd = Test-WslDevice $Distro '/dev/kfd'
$dri = $false
wsl -d $Distro -e test -d /dev/dri 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { $dri = $true }

$dxgColor = if ($dxg) { 'Green' } else { 'Red' }
$kfdColor = if ($kfd) { 'Green' } else { 'Yellow' }
$driColor = if ($dri) { 'Green' } else { 'Yellow' }
Write-Host ("  /dev/dxg: {0}" -f $(if ($dxg) { 'OK' } else { 'MISSING' })) -ForegroundColor $dxgColor
Write-Host ("  /dev/kfd: {0}" -f $(if ($kfd) { 'OK' } else { 'MISSING' })) -ForegroundColor $kfdColor
Write-Host ("  /dev/dri: {0}" -f $(if ($dri) { 'OK' } else { 'MISSING' })) -ForegroundColor $driColor

Write-Host "`n--- WSL diagnose script ---" -ForegroundColor Cyan
$repoRoot = Get-RepoRoot
$wslRepo = Convert-ToWslPath $repoRoot
$diagScript = Join-Path $repoRoot 'scripts\diagnose-wsl-gpu.sh'
if (Test-Path $diagScript) {
    wsl -d $Distro -- bash -lc "cd '$wslRepo' && chmod +x scripts/diagnose-wsl-gpu.sh 2>/dev/null; ./scripts/diagnose-wsl-gpu.sh" 2>&1
    $diagExit = $LASTEXITCODE
} else {
    Write-Host '  diagnose-wsl-gpu.sh not found in repo' -ForegroundColor Red
    $diagExit = 1
}

Write-Host "`n--- Manual recovery (run when safe) ---" -ForegroundColor Cyan
Write-Host '  1. Install AMD Adrenalin 26.1.1 for WSL2 from AMD ROCm WSL install page'
Write-Host '  2. In WSL: sudo ./scripts/install-wsl-rocm.sh'
Write-Host '  3. wsl --shutdown   # closes all WSL sessions — YOU must run this'
Write-Host '  4. Re-open WSL and: ./scripts/diagnose-wsl-gpu.sh'
Write-Host ''
Write-Host '  RX 5700: skip ROCm — use .\scripts\setup-ollama-rx5700.ps1 instead' -ForegroundColor Yellow
Write-Host '  RX 5700 research: docs\RX5700_WSL_GPU.md + scripts\try-rx5700-wsl-gpu-experimental.sh' -ForegroundColor DarkGray

exit $diagExit
