#Requires -Version 5.1
<#
.SYNOPSIS
  Disable Docker Desktop WSL integration to protect kubeadm/kubelet on WSL distros.
.DESCRIPTION
  Sets EnableIntegrationWithDefaultWslDistro=false, backs up settings-store.json,
  restarts Docker Desktop, and verifies kubeadm WSL has no /Docker/host mount.
  Mirror of enable-docker-wsl-integration.ps1 — use for kubeadm WSL clusters.
.PARAMETER Distro
  WSL distro name to check (default: Ubuntu-24.04).
.PARAMETER SkipRestart
  Skip Docker Desktop restart after settings change.
.EXAMPLE
  .\scripts\disable-docker-wsl-integration.ps1
.EXAMPLE
  .\scripts\disable-docker-wsl-integration.ps1 -Distro Ubuntu-24.04
#>
[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu-24.04',
    [switch]$SkipRestart
)

$ErrorActionPreference = 'Stop'

$settingsPath = Join-Path $env:APPDATA 'Docker\settings-store.json'
$backupDir = Join-Path $env:APPDATA 'Docker\backups'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupPath = Join-Path $backupDir "settings-store.json.$timestamp.bak"

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-DockerDesktopRunning {
    return [bool](Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)
}

function Stop-DockerDesktop {
    Write-Step 'Stopping Docker Desktop (if running)'
    $null = docker desktop stop 2>$null
    Start-Sleep -Seconds 3
    Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "  Waiting for Docker Desktop to exit (pid $($_.Id))..."
        $_.WaitForExit(30000) | Out-Null
    }
}

function Start-DockerDesktop {
    Write-Step 'Starting Docker Desktop'
    $dockerExe = Join-Path ${env:ProgramFiles} 'Docker\Docker\Docker Desktop.exe'
    if (-not (Test-Path $dockerExe)) {
        throw "Docker Desktop not found at: $dockerExe"
    }
    Start-Process -FilePath $dockerExe | Out-Null
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        docker info 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host '  Docker daemon is running' -ForegroundColor Green
            return
        }
        Start-Sleep -Seconds 5
    }
    throw 'Docker daemon did not become ready within 3 minutes'
}

function Set-WslIntegrationDisabled {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Host "  Docker settings not found: $Path" -ForegroundColor Yellow
        Write-Host '  Manual: Docker Desktop → Settings → Resources → WSL Integration → OFF for kubeadm distro' -ForegroundColor Yellow
        return $false
    }

    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    Copy-Item -Path $Path -Destination $backupPath -Force
    Write-Host "  Backup: $backupPath" -ForegroundColor DarkGray

    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    $settings = $raw | ConvertFrom-Json

    $changed = $false
    if ($settings.PSObject.Properties['EnableIntegrationWithDefaultWslDistro']) {
        if ($settings.EnableIntegrationWithDefaultWslDistro -ne $false) {
            $settings.EnableIntegrationWithDefaultWslDistro = $false
            $changed = $true
        }
    } else {
        $settings | Add-Member -NotePropertyName 'EnableIntegrationWithDefaultWslDistro' -NotePropertyValue $false
        $changed = $true
    }

    if (-not $changed) {
        Write-Host '  EnableIntegrationWithDefaultWslDistro already false' -ForegroundColor Green
        return $true
    }

    ($settings | ConvertTo-Json -Depth 20) + "`n" | Set-Content -Path $Path -Encoding UTF8 -NoNewline
    Write-Host '  Set EnableIntegrationWithDefaultWslDistro=false' -ForegroundColor Green
    return $true
}

function Test-WslKubeadmMounts {
    param([string]$Name)

    Write-Step "Checking WSL mounts ($Name)"
    $dockerHost = wsl -d $Name -e bash -lc "mount | grep -E '/Docker/host|docker-desktop-bind-mounts' || true" 2>&1
    $badLines = wsl -d $Name -e bash -lc "bash /mnt/d/work/kubernetes/kubeadm/scripts/check-wsl-mounts.sh 2>/dev/null || true" 2>&1

    $issues = @()
    if ($dockerHost -match '/Docker/host') {
        $issues += '/Docker/host is mounted (kubelet risk)'
    }
    if ($dockerHost -match 'docker-desktop-bind-mounts') {
        $issues += 'docker-desktop-bind-mounts present (WSL integration active)'
    }
    if ($badLines -and $badLines.Trim()) {
        $issues += "check-wsl-mounts: $($badLines.Trim())"
    }

    if ($issues.Count -eq 0) {
        Write-Host '  WSL mount check: OK' -ForegroundColor Green
        return $true
    }

    foreach ($i in $issues) {
        Write-Host "  WARN: $i" -ForegroundColor Yellow
    }
    Write-Host '  Run in WSL: sudo kubeadm/scripts/recover-wsl-kubelet.sh' -ForegroundColor DarkYellow
    return $false
}

Write-Host '=== Disable Docker Desktop WSL Integration (kubeadm) ===' -ForegroundColor Cyan

Write-Step 'Updating Docker Desktop settings'
$settingsOk = Set-WslIntegrationDisabled -Path $settingsPath

if ($settingsOk -and -not $SkipRestart) {
    if (Test-DockerDesktopRunning) { Stop-DockerDesktop }
    Start-DockerDesktop
    Write-Host '  Tip: wsl --shutdown then reopen WSL to drop stale docker-desktop mounts' -ForegroundColor DarkGray
} elseif ($SkipRestart) {
    Write-Host '  Skipped Docker restart (-SkipRestart)' -ForegroundColor Yellow
}

Write-Host "`n--- Manual UI steps (recommended) ---" -ForegroundColor Cyan
Write-Host '  Docker Desktop → Settings → Resources → WSL Integration'
Write-Host "  → Disable integration for: $Distro (kubeadm node)"
Write-Host '  → Keep enabled only for dev distros that need docker CLI in WSL'
Write-Host '  → wsl --shutdown (closes all WSL sessions)'

$mountOk = Test-WslKubeadmMounts -Name $Distro
if (-not $mountOk) { exit 1 }

Write-Host "`nDone. kubeadm uses containerd — WSL docker CLI is not required on the node distro." -ForegroundColor Green
