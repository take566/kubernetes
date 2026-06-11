#Requires -Version 5.1
<#
.SYNOPSIS
  Detect outdated AMD Adrenalin driver and guide GPU recovery for Ollama (RX 5700).
.DESCRIPTION
  Cannot auto-install drivers. Compares WMI DriverVersion, checks HIP runtime DLLs
  (Ollama needs amdhip64_7.dll), scans Ollama logs, and prints remediation steps.
.PARAMETER VerifyAfterUpdate
  Run a short inference test and check Ollama reports GPU (not CPU).
.PARAMETER OpenDownloadPage
  Open AMD driver download / auto-detect pages in the default browser.
.PARAMETER TryWinget
  Search winget for AMD packages (usually no Adrenalin WHQL; informational only).
.EXAMPLE
  .\scripts\update-adrenalin-gpu.ps1
.EXAMPLE
  .\scripts\update-adrenalin-gpu.ps1 -VerifyAfterUpdate
.EXAMPLE
  .\scripts\update-adrenalin-gpu.ps1 -OpenDownloadPage
#>
[CmdletBinding()]
param(
    [switch]$VerifyAfterUpdate,
    [switch]$OpenDownloadPage,
    [switch]$TryWinget
)

$ErrorActionPreference = 'Stop'

# WMI DriverVersion 32.0.<build>.<revision> — new Adrenalin WHQL for RDNA uses build 31xxx+.
# Legacy branch (e.g. 32.0.21043.x) ships HIP6 only; Ollama 0.30+ needs HIP7 (amdhip64_7.dll).
$MinDriverBuild = 31000
$AdrenalinDownloadUrl = 'https://www.amd.com/en/support/download/drivers.html'
$AmdAutoDetectUrl = 'https://www.amd.com/en/support/download/auto-detect-tool.html'
$AdrenalinWslDocUrl = 'https://rocm.docs.amd.com/projects/radeon-ryzen/en/docs-7.2/docs/install/installrad/wsl/install-radeon.html'
$Rx5700ProductUrl = 'https://www.amd.com/en/support/downloads/drivers.html/graphics/radeon-rx/radeon-rx-5000-series/radeon-rx-5700.html'

# GPU inference p50 for qwen2.5:0.5b on RX 5700 (project benchmarks).
$GpuLatencyP50Ms = 750
$CpuLatencyP50Ms = 1200

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Get-AmdGpuInfo {
    Get-CimInstance Win32_VideoController |
        Where-Object { $_.Name -match 'AMD|Radeon' -and $_.Name -notmatch 'Microsoft|Remote' }
}

function Get-DriverBuildNumber([string]$DriverVersion) {
    if (-not $DriverVersion) { return $null }
    $parts = $DriverVersion -split '\.'
    if ($parts.Count -lt 3) { return $null }
    $build = 0
    if ([int]::TryParse($parts[2], [ref]$build)) { return $build }
    return $null
}

function Test-DriverBuildSufficient([string]$DriverVersion) {
    $build = Get-DriverBuildNumber -DriverVersion $DriverVersion
    if ($null -eq $build) { return $false }
    return ($build -ge $MinDriverBuild)
}

function Test-HipRuntimeDlls {
    $hip6 = $null -ne (Get-Command amdhip64_6.dll -ErrorAction SilentlyContinue)
    $hip7 = $null -ne (Get-Command amdhip64_7.dll -ErrorAction SilentlyContinue)
    [PSCustomObject]@{
        Hip6Present = $hip6
        Hip7Present = $hip7
        OllamaWouldWarn = ($hip6 -and -not $hip7)
    }
}

function Get-OllamaDriverWarning {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Ollama\server.log'),
        (Join-Path $env:LOCALAPPDATA 'Ollama\logs\server.log')
    )
    foreach ($path in $candidates) {
        if (-not (Test-Path $path)) { continue }
        $tail = Get-Content -Path $path -Tail 300 -ErrorAction SilentlyContinue
        $hit = $tail | Select-String -Pattern 'AMD driver is too old|falling back to CPU|no compatible GPUs|library=cpu' -SimpleMatch:$false
        if ($hit) { return $hit | Select-Object -First 1 -ExpandProperty Line }
    }
    return $null
}

function Get-OllamaComputeBackend {
    $path = Join-Path $env:LOCALAPPDATA 'Ollama\server.log'
    if (-not (Test-Path $path)) { return $null }
    $lines = Get-Content -Path $path -Tail 400 -ErrorAction SilentlyContinue
    $hit = $lines | Select-String -Pattern 'inference compute' | Select-Object -Last 1
    if (-not $hit) { return $null }
    if ($hit.Line -match 'library=(\S+)') { return $Matches[1] }
    return $null
}

function Test-OllamaUsingGpu {
    $backend = Get-OllamaComputeBackend
    if ($backend -and $backend -ne 'cpu') { return $true }

    $psOut = & ollama ps 2>&1 | Out-String
    if ($psOut -match '100%\s*GPU') { return $true }
    if ($psOut -match '100%\s*CPU') { return $false }
    return $false
}

function Show-WingetStatus {
    Write-Step 'winget search (informational)'
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Host '  winget not available.' -ForegroundColor DarkGray
        return
    }
    $results = @(
        winget search 'AMD' --source winget 2>&1
        winget search 'Radeon' --source winget 2>&1
        winget search 'Adrenalin' --source winget 2>&1
    ) | Out-String
    $hits = $results | Select-String -Pattern 'Adrenalin|Radeon Software' -AllMatches
    if ($hits) {
        Write-Host "  $hits" -ForegroundColor DarkGray
    } else {
        Write-Host '  No AMD Software: Adrenalin Edition WHQL package in winget.' -ForegroundColor Yellow
        Write-Host '  (AMD Software: Cloud Edition is NOT the desktop GPU driver.)' -ForegroundColor DarkGray
    }
}

function Open-AmdDownloadPages {
    Write-Step 'Opening AMD download pages'
    foreach ($url in @($AmdAutoDetectUrl, $Rx5700ProductUrl, $AdrenalinDownloadUrl)) {
        Write-Host "  $url"
        Start-Process $url
    }
}

function Show-Remediation {
    param(
        [string]$Reason,
        [string]$CurrentVersion,
        [int]$CurrentBuild
    )
    Write-Host "`n--- Remediation (manual) ---" -ForegroundColor Yellow
    Write-Host "  Reason: $Reason"
    if ($CurrentVersion) {
        Write-Host ("  Current WMI: {0} (build {1}, need >= {2})" -f $CurrentVersion, $CurrentBuild, $MinDriverBuild) -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '  Ollama 0.30+ on Windows requires HIP7 runtime (amdhip64_7.dll).' -ForegroundColor White
    Write-Host '  Your driver branch (32.0.21xxx) only provides HIP6 (amdhip64_6.dll).' -ForegroundColor White
    Write-Host ''
    Write-Host '  Recommended: install latest AMD Software: Adrenalin Edition (e.g. 26.6.1).' -ForegroundColor Green
    Write-Host '  After update, WMI should show build 32.0.31xxx+ (e.g. 32.0.31019.2002).' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Steps:'
    Write-Host '  1. Auto-detect (easiest):'
    Write-Host "       $AmdAutoDetectUrl"
    Write-Host '     Or RX 5700 product page:'
    Write-Host "       $Rx5700ProductUrl"
    Write-Host '  2. Run installer — choose Factory Reset / Clean Install if offered.'
    Write-Host '  3. Reboot if prompted.'
    Write-Host '  4. Quit Ollama from system tray, then start Ollama again.'
    Write-Host '  5. Verify:'
    Write-Host '       .\scripts\update-adrenalin-gpu.ps1 -VerifyAfterUpdate'
    Write-Host '       ollama ps   # should show GPU, not 100% CPU'
    Write-Host '       .\scripts\bench_ollama_openai.ps1 -Model qwen2.5:0.5b-rx5700 -LatencySamples 3'
    Write-Host "     Target p50: ~$GpuLatencyP50Ms ms (GPU). CPU fallback is ~$CpuLatencyP50Ms ms+." -ForegroundColor DarkGray
    Write-Host ''
    Write-Host "  General portal: $AdrenalinDownloadUrl" -ForegroundColor DarkGray
    Write-Host "  WSL ROCm (RX 5700 NOT supported): $AdrenalinWslDocUrl" -ForegroundColor DarkGray
    Write-Host '  See also: docs/RX5700_WSL_GPU.md' -ForegroundColor DarkGray
}

Write-Host '=== AMD Adrenalin GPU Driver Check (Ollama / RX 5700) ===' -ForegroundColor Cyan

if ($OpenDownloadPage) {
    Open-AmdDownloadPages
}

if ($TryWinget) {
    Show-WingetStatus
}

Write-Step 'GPU detection'
$amdGpus = @(Get-AmdGpuInfo)
if ($amdGpus.Count -eq 0) {
    Write-Host '  No AMD GPU detected — script is for RX 5700 / Radeon Windows path.' -ForegroundColor Yellow
    exit 0
}

$needsUpdate = $false
$primaryVersion = $null
$primaryBuild = $null

foreach ($g in $amdGpus) {
    $build = Get-DriverBuildNumber -DriverVersion $g.DriverVersion
    $ok = Test-DriverBuildSufficient -DriverVersion $g.DriverVersion
    $color = if ($ok) { 'Green' } else { 'Yellow' }
    Write-Host ("  {0}" -f $g.Name)
    Write-Host ("    DriverVersion: {0}" -f $g.DriverVersion) -ForegroundColor $color
    Write-Host ("    Build (3rd component): {0} — minimum >= {1}" -f $build, $MinDriverBuild) -ForegroundColor DarkGray
    if ($build -lt 31000 -and $build -ge 21000) {
        Write-Host '    Branch: legacy 32.0.21xxx (HIP6 only) — upgrade to 32.0.31xxx for Ollama GPU' -ForegroundColor Yellow
    }
    if (-not $primaryVersion) {
        $primaryVersion = $g.DriverVersion
        $primaryBuild = $build
    }
    if (-not $ok) { $needsUpdate = $true }
}

Write-Step 'HIP runtime DLLs (Ollama amd.go check)'
$hip = Test-HipRuntimeDlls
Write-Host ("  amdhip64_6.dll (HIP6): {0}" -f $(if ($hip.Hip6Present) { 'found' } else { 'MISSING' })) -ForegroundColor $(if ($hip.Hip6Present) { 'Green' } else { 'Red' })
Write-Host ("  amdhip64_7.dll (HIP7): {0}" -f $(if ($hip.Hip7Present) { 'found' } else { 'MISSING' })) -ForegroundColor $(if ($hip.Hip7Present) { 'Green' } else { 'Red' })
if ($hip.OllamaWouldWarn) {
    Write-Host '  Ollama: HIP6 present but HIP7 missing → "AMD driver is too old"' -ForegroundColor Red
    $needsUpdate = $true
} elseif ($hip.Hip7Present) {
    Write-Host '  HIP7 runtime OK for Ollama GPU inference.' -ForegroundColor Green
}

Write-Step 'Ollama log scan'
$logWarn = Get-OllamaDriverWarning
$backend = Get-OllamaComputeBackend
if ($logWarn) {
    Write-Host "  WARN: $logWarn" -ForegroundColor Red
    $needsUpdate = $true
} else {
    Write-Host '  No recent driver-too-old / CPU-fallback warning in Ollama logs.' -ForegroundColor Green
}
if ($backend) {
    $bc = if ($backend -eq 'cpu') { 'Red' } else { 'Green' }
    Write-Host ("  Active compute backend (last startup): {0}" -f $backend) -ForegroundColor $bc
    if ($backend -eq 'cpu') { $needsUpdate = $true }
}

if ($VerifyAfterUpdate) {
    Write-Step 'Post-update verification'
    $ollama = Get-Command ollama -ErrorAction SilentlyContinue
    if (-not $ollama) {
        Write-Host '  ollama CLI not in PATH' -ForegroundColor Yellow
    } else {
        $body = @{ model = 'qwen2.5:0.5b'; prompt = 'Say GPU'; stream = $false; options = @{ num_predict = 4 } } | ConvertTo-Json -Compress
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $null = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 120
            $sw.Stop()
            $ms = $sw.ElapsedMilliseconds
            $usingGpu = Test-OllamaUsingGpu
            $procLine = (& ollama ps 2>&1 | Select-Object -Skip 1 | Select-Object -First 1)
            Write-Host ("  Inference OK ({0} ms)" -f $ms) -ForegroundColor Green
            if ($procLine) { Write-Host ("  ollama ps: {0}" -f $procLine.Trim()) }
            if ($usingGpu) {
                Write-Host '  GPU active (ROCm backend or ollama ps shows GPU).' -ForegroundColor Green
            } else {
                Write-Host '  CPU inference — GPU not active.' -ForegroundColor Red
                Write-Host ("  Latency {0} ms vs GPU target ~{1} ms — likely CPU fallback." -f $ms, $GpuLatencyP50Ms) -ForegroundColor Yellow
                $needsUpdate = $true
            }
        } catch {
            Write-Host "  Ollama generate failed: $_" -ForegroundColor Red
            Write-Host '  Ensure Ollama is running (system tray).' -ForegroundColor Yellow
        }
    }
}

if ($needsUpdate) {
    Show-Remediation -Reason 'Driver build below minimum, HIP7 DLL missing, and/or Ollama on CPU' `
        -CurrentVersion $primaryVersion -CurrentBuild $primaryBuild
    exit 1
}

Write-Host "`nDriver check passed — Ollama should use GPU." -ForegroundColor Green
exit 0
