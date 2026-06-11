#Requires -Version 5.1
<#
.SYNOPSIS
  WSL ROCm install helper — preflight, interactive sudo install, post-shutdown verify.
.DESCRIPTION
  ROCm install requires an interactive WSL sudo session (password prompt). This script:
  1. Runs WSL GPU preflight
  2. Prints copy-paste commands OR opens Windows Terminal / wsl for interactive install
  3. Reminds you to run `wsl --shutdown` after ROCm install, then re-runs preflight

  Prerequisites (helm, pciutils, wget) also need sudo — use -PrerequisitesOnly or the
  interactive command block from install-wsl-rocm-interactive.sh.

.EXAMPLE
  .\scripts\install-wsl-rocm.ps1
  .\scripts\install-wsl-rocm.ps1 -PreflightOnly
  .\scripts\install-wsl-rocm.ps1 -PrerequisitesOnly
  .\scripts\install-wsl-rocm.ps1 -OpenTerminal
#>
[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu-24.04',
    [switch]$PreflightOnly,
    [switch]$PrerequisitesOnly,
    [switch]$OpenTerminal,
    [switch]$SkipTerminal
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-RepoRoot {
    $root = Split-Path -Parent $PSScriptRoot
    if (-not (Test-Path (Join-Path $root 'scripts\install-wsl-rocm.sh'))) {
        throw "Repo root not found (expected scripts\install-wsl-rocm.sh under $root)"
    }
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

function Invoke-WslBash {
    param(
        [string]$DistroName,
        [string]$Command
    )
    wsl -d $DistroName -- bash -lc $Command
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed (exit $LASTEXITCODE): $Command"
    }
}

function Test-WslDistro([string]$Name) {
    $list = wsl -l -q 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return ($list | ForEach-Object { $_.Trim("`0").Trim() } | Where-Object { $_ -eq $Name })
}

function Open-InteractiveWslTerminal {
    param(
        [string]$DistroName,
        [string]$WslRepoRoot
    )

    $inner = "cd '$WslRepoRoot' && echo '=== ROCm install (sudo password required) ===' && echo 'Run: sudo ./scripts/install-wsl-rocm.sh' && echo 'Or paste commands from: ./scripts/install-wsl-rocm-interactive.sh' && exec bash -l"
    $escaped = $inner -replace "'", "'\\''"

    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($wt) {
        Write-Step "Opening Windows Terminal (WSL: $DistroName)"
        Start-Process wt.exe -ArgumentList @('-w', '0', 'new-tab', '-p', 'Ubuntu-24.04', 'wsl', '-d', $DistroName, '--', 'bash', '-lc', $inner)
        return $true
    }

    Write-Step "Opening wsl.exe interactive session ($DistroName)"
    Start-Process wsl.exe -ArgumentList @('-d', $DistroName, '--', 'bash', '-lc', $inner)
    return $true
}

$repoRoot = Get-RepoRoot
$wslRepo = Convert-ToWslPath $repoRoot

Write-Host '=== WSL ROCm Install Helper ===' -ForegroundColor Cyan
Write-Host "Repo (WSL): $wslRepo" -ForegroundColor DarkGray

if (-not (Test-WslDistro $Distro)) {
    throw "WSL distro not found: $Distro. Install Ubuntu 24.04 first."
}

Write-Step 'WSL GPU preflight'
Invoke-WslBash -DistroName $Distro -Command "cd '$wslRepo' && ./scripts/setup-wsl-gpu-preflight.sh"

if ($PreflightOnly) {
    Write-Host "`nPreflight only (-PreflightOnly). Done." -ForegroundColor Green
    exit 0
}

if ($PrerequisitesOnly) {
    Write-Step 'Prerequisites install requires interactive sudo in WSL'
    Invoke-WslBash -DistroName $Distro -Command "cd '$wslRepo' && ./scripts/install-wsl-rocm-interactive.sh '$wslRepo'"
    Write-Host "`nPaste the prerequisites block in your WSL terminal, then re-run preflight." -ForegroundColor Yellow
    exit 0
}

Write-Step 'Interactive install commands (sudo password required — cannot run from PowerShell)'
Invoke-WslBash -DistroName $Distro -Command "cd '$wslRepo' && ./scripts/install-wsl-rocm-interactive.sh '$wslRepo'"

if (-not $SkipTerminal) {
    if ($OpenTerminal -or -not $PSBoundParameters.ContainsKey('OpenTerminal')) {
        try {
            Open-InteractiveWslTerminal -DistroName $Distro -WslRepoRoot $wslRepo | Out-Null
            Write-Host '  Terminal opened — complete sudo install there, then return here.' -ForegroundColor Green
        } catch {
            Write-Host "  WARN: Could not open terminal: $_" -ForegroundColor Yellow
            Write-Host '  Copy the command block above into an existing WSL window.' -ForegroundColor Yellow
        }
    }
}

Write-Host ''
Write-Host '=== After ROCm install completes in WSL ===' -ForegroundColor Yellow
Write-Host @'
1. From PowerShell (recommended — reload WSL GPU driver stack):
     wsl --shutdown
   Wait a few seconds, then reopen WSL.

2. Re-run preflight:
     .\scripts\install-wsl-rocm.ps1 -PreflightOnly

3. Optional prerequisites (if lspci/helm/wget still missing):
     .\scripts\install-wsl-rocm.ps1 -PrerequisitesOnly

Docs: docs\LOCAL_GPU_SETUP_WINDOWS.md section 4
'@ -ForegroundColor DarkGray

Write-Host "`nWaiting for you to finish interactive sudo install in WSL." -ForegroundColor Cyan
Write-Host "When done, run: wsl --shutdown  then  .\scripts\install-wsl-rocm.ps1 -PreflightOnly" -ForegroundColor Cyan
