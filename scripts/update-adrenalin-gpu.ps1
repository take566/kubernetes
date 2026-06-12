#Requires -Version 5.1
<#
.SYNOPSIS
  Verify Ollama GPU inference path on AMD Radeon (RX 5700 / RDNA1: Vulkan backend).
.DESCRIPTION
  RX 5700 (RDNA1, gfx1010) can NOT reach HIP7 / driver build 31000+:
  Adrenalin 26.x ships two driver branches — RDNA1/2 get variant A
  (Driver 25.10.43.12 = WMI 32.0.21043.12001, the LATEST for RDNA1),
  while build 31019+ (bundling HIP7) is variant B for RDNA3/4 only.
  Telling RDNA1 users to "update to build 31000+" is therefore wrong.

  The correct GPU path for RX 5700 is Ollama's Vulkan backend:
  Ollama 0.30.x bundles lib\ollama\vulkan\ggml-vulkan.dll in the full
  Windows installer and OLLAMA_VULKAN is enabled by default (set 0 to disable).
  Measured on this project: RX 5700 detected as Vulkan0, 100% GPU offload,
  ~157 tok/s (3.4x CPU).

  Known failure mode: Ollama SELF-UPDATE may replace only ollama.exe and
  drop lib\ollama\vulkan\ — fix is re-running the official OllamaSetup.exe
  (supports /VERYSILENT), NOT an Adrenalin driver update.

  This script checks:
    (a) lib\ollama\vulkan\ggml-vulkan.dll exists (else: repair install)
    (b) server.log "inference compute" reports library=Vulkan + GPU name
    (c) ollama ps PROCESSOR column (note: Vulkan may be misreported as
        "100% CPU" — log offload evidence is used to disambiguate)
  Driver-build / HIP7 checks remain for RDNA3/4 only (informational on RDNA1/2).
.PARAMETER VerifyAfterUpdate
  Run a short inference test and check Ollama actually uses the GPU.
.PARAMETER OpenDownloadPage
  Open the Ollama download page (and AMD driver pages for RDNA3/4 cases).
.PARAMETER TryWinget
  Search winget for AMD packages (informational only).
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

# WMI DriverVersion 32.0.<build>.<revision>
# RDNA1/2 (variant A): 32.0.21043.x is the LATEST branch — normal, do not "upgrade".
# RDNA3/4 (variant B): 32.0.31xxx+ bundles HIP7 (amdhip64_7.dll) for Ollama ROCm.
$MinDriverBuildRdna34 = 31000
$OllamaDownloadUrl = 'https://ollama.com/download'
$OllamaSetupUrl = 'https://ollama.com/download/OllamaSetup.exe'
$AdrenalinDownloadUrl = 'https://www.amd.com/en/support/download/drivers.html'
$AmdAutoDetectUrl = 'https://www.amd.com/en/support/download/auto-detect-tool.html'
$AdrenalinWslDocUrl = 'https://rocm.docs.amd.com/projects/radeon-ryzen/en/docs-7.2/docs/install/installrad/wsl/install-radeon.html'

# GPU inference p50 for qwen2.5:0.5b on RX 5700 via Vulkan (project benchmarks).
$GpuLatencyP50Ms = 750
$CpuLatencyP50Ms = 1200

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Get-AmdGpuInfo {
    Get-CimInstance Win32_VideoController |
        Where-Object { $_.Name -match 'AMD|Radeon' -and $_.Name -notmatch 'Microsoft|Remote' }
}

function Get-RdnaGeneration([string]$GpuName) {
    # Coarse classification by marketing name; enough to pick the right driver branch.
    if ($GpuName -match 'RX\s*5\d{3}') { return 1 }   # RX 5300-5700 = RDNA1
    if ($GpuName -match 'RX\s*6\d{3}') { return 2 }   # RX 6000 = RDNA2
    if ($GpuName -match 'RX\s*7\d{3}') { return 3 }   # RX 7000 = RDNA3
    if ($GpuName -match 'RX\s*9\d{3}') { return 4 }   # RX 9000 = RDNA4
    return 0                                          # unknown / APU etc.
}

function Get-DriverBuildNumber([string]$DriverVersion) {
    if (-not $DriverVersion) { return $null }
    $parts = $DriverVersion -split '\.'
    if ($parts.Count -lt 3) { return $null }
    $build = 0
    if ([int]::TryParse($parts[2], [ref]$build)) { return $build }
    return $null
}

function Get-OllamaInstallDir {
    $cmd = Get-Command ollama -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return (Split-Path -Parent $cmd.Source) }
    $default = Join-Path $env:LOCALAPPDATA 'Programs\Ollama'
    if (Test-Path (Join-Path $default 'ollama.exe')) { return $default }
    return $null
}

function Test-VulkanBackendFiles {
    # (a) Main check: full installer bundles lib\ollama\vulkan\ggml-vulkan.dll.
    # Self-update may replace only ollama.exe and drop this directory.
    $dir = Get-OllamaInstallDir
    $dll = if ($dir) { Join-Path $dir 'lib\ollama\vulkan\ggml-vulkan.dll' } else { $null }
    [PSCustomObject]@{
        InstallDir    = $dir
        VulkanDllPath = $dll
        VulkanDllOk   = ($dll -and (Test-Path $dll))
    }
}

function Get-OllamaServerLogPath {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Ollama\server.log'),
        (Join-Path $env:LOCALAPPDATA 'Ollama\logs\server.log')
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

function Get-OllamaInferenceCompute {
    # (b) Last "inference compute" line: library=Vulkan + GPU description expected.
    $path = Get-OllamaServerLogPath
    if (-not $path) { return $null }
    $hit = Select-String -Path $path -Pattern 'inference compute' -ErrorAction SilentlyContinue |
        Select-Object -Last 1
    if (-not $hit) { return $null }
    $library = $null; $name = $null
    if ($hit.Line -match 'library=(\S+)') { $library = $Matches[1] }
    if ($hit.Line -match 'description="([^"]+)"') { $name = $Matches[1] }
    [PSCustomObject]@{
        Line    = $hit.Line
        Library = $library
        GpuName = $name
        IsVulkanGpu = ($library -eq 'Vulkan' -and $name -match 'AMD|Radeon')
    }
}

function Test-VulkanOffloadEvidence {
    # Disambiguates "ollama ps: 100% CPU" misreport: if the last model load
    # offloaded layers to Vulkan0, inference really runs on the GPU.
    $path = Get-OllamaServerLogPath
    if (-not $path) { return $false }
    $tail = Get-Content -Path $path -Tail 2000 -ErrorAction SilentlyContinue
    $offload = $tail | Select-String -Pattern 'offloaded (\d+)/(\d+) layers to GPU' |
        Select-Object -Last 1
    if (-not $offload) { return $false }
    if ($offload.Line -match 'offloaded (\d+)/(\d+) layers to GPU') {
        return ([int]$Matches[1] -gt 0)
    }
    return $false
}

function Get-OllamaPsProcessor {
    # (c) PROCESSOR column of "ollama ps" for the first loaded model.
    $ollama = Get-Command ollama -ErrorAction SilentlyContinue
    if (-not $ollama) { return $null }
    $psOut = & ollama ps 2>&1 | Out-String
    if ($psOut -match '(\d+%\s*GPU(?:/\d+%\s*CPU)?)') { return $Matches[1] }
    if ($psOut -match '(\d+%\s*CPU)') { return $Matches[1] }
    return $null   # no model loaded
}

function Test-HipRuntimeDlls {
    # Informational only: HIP7 is relevant for RDNA3/4 ROCm path, never for RDNA1/2.
    $hip6 = $null -ne (Get-Command amdhip64_6.dll -ErrorAction SilentlyContinue)
    $hip7 = $null -ne (Get-Command amdhip64_7.dll -ErrorAction SilentlyContinue)
    [PSCustomObject]@{
        Hip6Present = $hip6
        Hip7Present = $hip7
    }
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
    Write-Step 'Opening download pages'
    foreach ($url in @($OllamaDownloadUrl, $AmdAutoDetectUrl, $AdrenalinDownloadUrl)) {
        Write-Host "  $url"
        Start-Process $url
    }
}

function Show-Remediation {
    param(
        [string]$Reason,
        [bool]$VulkanDllMissing,
        [string]$InstallDir
    )
    Write-Host "`n--- Remediation (manual) ---" -ForegroundColor Yellow
    Write-Host "  Reason: $Reason"
    Write-Host ''
    Write-Host '  RX 5700 (RDNA1) GPU path = Ollama Vulkan backend, NOT Adrenalin/HIP7.' -ForegroundColor White
    Write-Host '  Driver 32.0.21043.x is the latest RDNA1 branch — do NOT chase build 31000+.' -ForegroundColor White
    Write-Host ''
    if ($VulkanDllMissing) {
        Write-Host '  Vulkan backend files are missing (known Ollama self-update breakage:' -ForegroundColor Red
        Write-Host '  the updater can replace only ollama.exe and drop lib\ollama\vulkan\).' -ForegroundColor Red
        Write-Host ''
    }
    Write-Host '  Steps (repair install):' -ForegroundColor Green
    Write-Host '  1. Quit Ollama from the system tray.'
    Write-Host "  2. Download the official installer: $OllamaSetupUrl"
    Write-Host '  3. Re-run it (restores lib\ollama\vulkan\):'
    Write-Host '       .\OllamaSetup.exe /VERYSILENT'
    Write-Host '  4. Ensure OLLAMA_VULKAN is not set to 0 (default = enabled):'
    Write-Host '       [Environment]::GetEnvironmentVariable("OLLAMA_VULKAN","User")'
    Write-Host '  5. Start Ollama, then verify:'
    Write-Host '       .\scripts\update-adrenalin-gpu.ps1 -VerifyAfterUpdate'
    Write-Host '       # server.log should show: inference compute ... library=Vulkan ... RX 5700'
    Write-Host '       # model load should show: offloaded N/N layers to GPU'
    Write-Host "     Target p50: ~$GpuLatencyP50Ms ms (GPU). CPU fallback is ~$CpuLatencyP50Ms ms+." -ForegroundColor DarkGray
    if ($InstallDir) {
        Write-Host ''
        Write-Host "  Install dir: $InstallDir" -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  RDNA3/4 only: ROCm/HIP7 path additionally needs Adrenalin build 31000+:' -ForegroundColor DarkGray
    Write-Host "    $AdrenalinDownloadUrl" -ForegroundColor DarkGray
    Write-Host "  WSL ROCm (RX 5700 NOT supported): $AdrenalinWslDocUrl" -ForegroundColor DarkGray
    Write-Host '  See also: docs/RX5700_WSL_GPU.md' -ForegroundColor DarkGray
}

Write-Host '=== Ollama GPU Path Check (AMD Radeon / RX 5700 = Vulkan) ===' -ForegroundColor Cyan

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

$needsAction = $false
$maxRdnaGen = 0

foreach ($g in $amdGpus) {
    $build = Get-DriverBuildNumber -DriverVersion $g.DriverVersion
    $gen = Get-RdnaGeneration -GpuName $g.Name
    if ($gen -gt $maxRdnaGen) { $maxRdnaGen = $gen }
    Write-Host ("  {0}" -f $g.Name)
    Write-Host ("    DriverVersion: {0} (build {1})" -f $g.DriverVersion, $build)
    if ($gen -in 1, 2) {
        if ($build -ge 21000 -and $build -lt 31000) {
            Write-Host '    Branch: RDNA1/2 variant A (32.0.21xxx) — this IS the latest for this GPU. Normal.' -ForegroundColor Green
            Write-Host '    Note: build 31019+ (HIP7) is RDNA3/4-only variant B — structurally unreachable here.' -ForegroundColor DarkGray
        } else {
            Write-Host '    RDNA1/2: driver branch unrecognized — Vulkan path is unaffected either way.' -ForegroundColor DarkGray
        }
    } elseif ($gen -ge 3) {
        if ($build -ge $MinDriverBuildRdna34) {
            Write-Host ("    RDNA3/4: build {0} >= {1} — HIP7/ROCm capable." -f $build, $MinDriverBuildRdna34) -ForegroundColor Green
        } else {
            Write-Host ("    RDNA3/4: build {0} < {1} — update Adrenalin for HIP7/ROCm GPU." -f $build, $MinDriverBuildRdna34) -ForegroundColor Yellow
            $needsAction = $true
        }
    } else {
        Write-Host '    Generation not classified — driver build check skipped (Vulkan path applies).' -ForegroundColor DarkGray
    }
}

Write-Step 'Ollama Vulkan backend files (main check)'
$files = Test-VulkanBackendFiles
$vulkanDllMissing = $false
if (-not $files.InstallDir) {
    Write-Host '  Ollama install dir not found (ollama not in PATH?).' -ForegroundColor Red
    $needsAction = $true
    $vulkanDllMissing = $true
} else {
    Write-Host ("  Install dir: {0}" -f $files.InstallDir) -ForegroundColor DarkGray
    if ($files.VulkanDllOk) {
        Write-Host ("  lib\ollama\vulkan\ggml-vulkan.dll: found") -ForegroundColor Green
    } else {
        Write-Host ("  lib\ollama\vulkan\ggml-vulkan.dll: MISSING") -ForegroundColor Red
        Write-Host '  Likely broken self-update (exe replaced, vulkan dir dropped).' -ForegroundColor Red
        Write-Host '  Fix: re-run official OllamaSetup.exe (supports /VERYSILENT).' -ForegroundColor Yellow
        $needsAction = $true
        $vulkanDllMissing = $true
    }
}

Write-Step 'OLLAMA_VULKAN environment'
$vulkanEnv = $env:OLLAMA_VULKAN
if ($null -eq $vulkanEnv) { $vulkanEnv = [Environment]::GetEnvironmentVariable('OLLAMA_VULKAN', 'User') }
if ($null -eq $vulkanEnv) { $vulkanEnv = [Environment]::GetEnvironmentVariable('OLLAMA_VULKAN', 'Machine') }
if ($vulkanEnv -eq '0') {
    Write-Host '  OLLAMA_VULKAN=0 — Vulkan backend DISABLED. Unset it or set to 1.' -ForegroundColor Red
    $needsAction = $true
} elseif ($vulkanEnv) {
    Write-Host ("  OLLAMA_VULKAN={0} (Vulkan enabled)" -f $vulkanEnv) -ForegroundColor Green
} else {
    Write-Host '  OLLAMA_VULKAN not set — default is enabled. OK.' -ForegroundColor Green
}

Write-Step 'server.log: inference compute backend'
$compute = Get-OllamaInferenceCompute
if (-not $compute) {
    Write-Host '  No "inference compute" line found (Ollama not started yet?).' -ForegroundColor Yellow
    $needsAction = $true
} elseif ($compute.IsVulkanGpu) {
    Write-Host ("  library={0} name=""{1}"" — Vulkan GPU detected." -f $compute.Library, $compute.GpuName) -ForegroundColor Green
} else {
    Write-Host ("  library={0} name=""{1}"" — GPU not on Vulkan path." -f $compute.Library, $compute.GpuName) -ForegroundColor Red
    $needsAction = $true
}

Write-Step 'ollama ps: PROCESSOR column'
$proc = Get-OllamaPsProcessor
$offloadOk = Test-VulkanOffloadEvidence
if ($null -eq $proc) {
    Write-Host '  No model loaded (or ollama unavailable) — skipping ps check.' -ForegroundColor DarkGray
} elseif ($proc -match 'GPU') {
    Write-Host ("  PROCESSOR: {0} — GPU active." -f $proc) -ForegroundColor Green
} elseif ($offloadOk) {
    Write-Host ("  PROCESSOR: {0} — but server.log shows layers offloaded to Vulkan0." -f $proc) -ForegroundColor Yellow
    Write-Host '  Known quirk: ollama ps may misreport the Vulkan backend as CPU. GPU is active.' -ForegroundColor Green
} else {
    Write-Host ("  PROCESSOR: {0} and no GPU offload evidence in server.log — CPU fallback." -f $proc) -ForegroundColor Red
    $needsAction = $true
}

Write-Step 'HIP runtime DLLs (informational — RDNA3/4 ROCm path only)'
$hip = Test-HipRuntimeDlls
Write-Host ("  amdhip64_6.dll (HIP6): {0}" -f $(if ($hip.Hip6Present) { 'found' } else { 'not found' })) -ForegroundColor DarkGray
Write-Host ("  amdhip64_7.dll (HIP7): {0}" -f $(if ($hip.Hip7Present) { 'found' } else { 'not found' })) -ForegroundColor DarkGray
if ($maxRdnaGen -le 2) {
    Write-Host '  RDNA1/2: HIP7 is unreachable and NOT required — Vulkan path is used instead.' -ForegroundColor DarkGray
    Write-Host '  The "AMD driver is too old" ROCm warning in logs is expected and harmless.' -ForegroundColor DarkGray
} elseif (-not $hip.Hip7Present) {
    Write-Host '  RDNA3/4: HIP7 missing — Adrenalin build 31000+ needed for the ROCm path.' -ForegroundColor Yellow
}

if ($VerifyAfterUpdate) {
    Write-Step 'Inference verification'
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
            $compute2 = Get-OllamaInferenceCompute
            $proc2 = Get-OllamaPsProcessor
            $offload2 = Test-VulkanOffloadEvidence
            $usingGpu = (($compute2 -and $compute2.IsVulkanGpu) -and (($proc2 -match 'GPU') -or $offload2))
            Write-Host ("  Inference OK ({0} ms)" -f $ms) -ForegroundColor Green
            if ($proc2) { Write-Host ("  ollama ps PROCESSOR: {0}" -f $proc2) }
            if ($usingGpu) {
                Write-Host '  GPU active (Vulkan backend; layers offloaded to GPU).' -ForegroundColor Green
            } else {
                Write-Host '  CPU inference — GPU not active.' -ForegroundColor Red
                Write-Host ("  Latency {0} ms vs GPU target ~{1} ms — likely CPU fallback." -f $ms, $GpuLatencyP50Ms) -ForegroundColor Yellow
                $needsAction = $true
            }
        } catch {
            Write-Host "  Ollama generate failed: $_" -ForegroundColor Red
            Write-Host '  Ensure Ollama is running (system tray).' -ForegroundColor Yellow
        }
    }
}

if ($needsAction) {
    Show-Remediation -Reason 'Vulkan backend files/env/log indicate GPU path is broken (or RDNA3/4 driver below 31000)' `
        -VulkanDllMissing $vulkanDllMissing -InstallDir $files.InstallDir
    exit 1
}

Write-Host "`nGPU path check passed — Ollama uses the Vulkan backend on this GPU." -ForegroundColor Green
exit 0
