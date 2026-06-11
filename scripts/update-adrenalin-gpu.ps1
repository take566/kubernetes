#Requires -Version 5.1
<#
.SYNOPSIS
  Detect outdated AMD Adrenalin driver and guide GPU recovery for Ollama (RX 5700).
.DESCRIPTION
  Cannot auto-install drivers. Compares WMI DriverVersion, scans Ollama logs for
  "AMD driver is too old", and prints remediation steps with download links.
.PARAMETER Fix
  Print remediation only (no install). Alias for default behavior.
.EXAMPLE
  .\scripts\update-adrenalin-gpu.ps1
.EXAMPLE
  .\scripts\update-adrenalin-gpu.ps1 -VerifyAfterUpdate
#>
[CmdletBinding()]
param(
    [switch]$VerifyAfterUpdate
)

$ErrorActionPreference = 'Stop'

# Minimum recommended Adrenalin (Windows display driver for Ollama DirectML).
# Format: major.minor.build (WMI often reports 32.0.<build>.<revision>).
$MinDriverBuild = 24000
$AdrenalinDownloadUrl = 'https://www.amd.com/en/support/download/drivers.html'
$AdrenalinWslDocUrl = 'https://rocm.docs.amd.com/projects/radeon-ryzen/en/docs-7.2/docs/install/installrad/wsl/install-radeon.html'

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Get-AmdGpuInfo {
    Get-CimInstance Win32_VideoController |
        Where-Object { $_.Name -match 'AMD|Radeon' -and $_.Name -notmatch 'Microsoft|Remote' }
}

function Test-DriverBuildSufficient([string]$DriverVersion) {
    if (-not $DriverVersion) { return $false }
    $parts = $DriverVersion -split '\.'
    if ($parts.Count -lt 3) { return $false }
    $build = 0
    [void][int]::TryParse($parts[2], [ref]$build)
    if ($build -ge $MinDriverBuild) { return $true }
    # Some Adrenalin builds use 31.x with high build numbers — treat 31.0.24000+ as OK too.
    if ($parts[0] -eq '31' -and $build -ge $MinDriverBuild) { return $true }
    return $false
}

function Get-OllamaDriverWarning {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Ollama\server.log'),
        (Join-Path $env:LOCALAPPDATA 'Ollama\logs\server.log')
    )
    foreach ($path in $candidates) {
        if (-not (Test-Path $path)) { continue }
        $tail = Get-Content -Path $path -Tail 200 -ErrorAction SilentlyContinue
        $hit = $tail | Select-String -Pattern 'AMD driver is too old|falling back to CPU|no compatible GPUs' -SimpleMatch:$false
        if ($hit) { return $hit | Select-Object -First 1 -ExpandProperty Line }
    }
    return $null
}

function Show-Remediation {
    param([string]$Reason)
    Write-Host "`n--- Remediation (manual) ---" -ForegroundColor Yellow
    Write-Host "  Reason: $Reason"
    Write-Host "  1. Download latest AMD Software: Adrenalin Edition from:"
    Write-Host "     $AdrenalinDownloadUrl"
    Write-Host "  2. Run installer (Express or Full). Reboot if prompted."
    Write-Host "  3. Restart Ollama from system tray (Quit → start again)."
    Write-Host "  4. Verify:"
    Write-Host "       .\scripts\update-adrenalin-gpu.ps1 -VerifyAfterUpdate"
    Write-Host "       .\scripts\bench_ollama_openai.ps1 -Model qwen2.5:1.5b -LatencySamples 3"
    Write-Host ""
    Write-Host "  WSL ROCm (optional, RX 5700 NOT supported for compute): $AdrenalinWslDocUrl" -ForegroundColor DarkGray
    Write-Host "  See also: docs/RX5700_WSL_GPU.md" -ForegroundColor DarkGray
}

Write-Host '=== AMD Adrenalin GPU Driver Check (Ollama / RX 5700) ===' -ForegroundColor Cyan

Write-Step 'GPU detection'
$amdGpus = @(Get-AmdGpuInfo)
if ($amdGpus.Count -eq 0) {
    Write-Host '  No AMD GPU detected — script is for RX 5700 / Radeon Windows path.' -ForegroundColor Yellow
    exit 0
}

$needsUpdate = $false
foreach ($g in $amdGpus) {
    $ok = Test-DriverBuildSufficient -DriverVersion $g.DriverVersion
    $color = if ($ok) { 'Green' } else { 'Yellow' }
    Write-Host ("  {0}" -f $g.Name)
    Write-Host ("    DriverVersion: {0}" -f $g.DriverVersion) -ForegroundColor $color
    Write-Host ("    Minimum build (3rd component): >= {0}" -f $MinDriverBuild) -ForegroundColor DarkGray
    if (-not $ok) { $needsUpdate = $true }
}

Write-Step 'Ollama log scan'
$logWarn = Get-OllamaDriverWarning
if ($logWarn) {
    Write-Host "  WARN: $logWarn" -ForegroundColor Red
    $needsUpdate = $true
} else {
    Write-Host '  No "driver too old" message in recent Ollama logs.' -ForegroundColor Green
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
            $null = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 60
            $sw.Stop()
            Write-Host ("  Inference OK ({0} ms) — compare with CPU baseline (~1200ms+)" -f $sw.ElapsedMilliseconds) -ForegroundColor Green
            if ($sw.ElapsedMilliseconds -gt 1000) {
                Write-Host '  Still slow — GPU may not be active; re-check logs.' -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  Ollama generate failed: $_" -ForegroundColor Red
        }
    }
}

if ($needsUpdate) {
    Show-Remediation -Reason 'Driver build below minimum and/or Ollama reports outdated AMD driver'
    exit 1
}

Write-Host "`nDriver check passed." -ForegroundColor Green
exit 0
