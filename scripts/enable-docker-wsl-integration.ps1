#Requires -Version 5.1
<#
.SYNOPSIS
  Enable Docker Desktop WSL integration and verify docker inside WSL.
.DESCRIPTION
  Sets EnableIntegrationWithDefaultWslDistro=true in settings-store.json,
  backs up the file, restarts Docker Desktop, and runs `wsl docker info`.
.EXAMPLE
  .\scripts\enable-docker-wsl-integration.ps1
.EXAMPLE
  .\scripts\enable-docker-wsl-integration.ps1 -Distro Ubuntu-24.04
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
    $proc = Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue
    return [bool]$proc
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

function Set-WslIntegrationEnabled {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Docker settings not found: $Path`nInstall and launch Docker Desktop once, then re-run."
    }

    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    Copy-Item -Path $Path -Destination $backupPath -Force
    Write-Host "  Backup: $backupPath" -ForegroundColor DarkGray

    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    $settings = $raw | ConvertFrom-Json

    $changed = $false
    if ($settings.PSObject.Properties['EnableIntegrationWithDefaultWslDistro']) {
        if ($settings.EnableIntegrationWithDefaultWslDistro -ne $true) {
            $settings.EnableIntegrationWithDefaultWslDistro = $true
            $changed = $true
        }
    } else {
        $settings | Add-Member -NotePropertyName 'EnableIntegrationWithDefaultWslDistro' -NotePropertyValue $true
        $changed = $true
    }

    if (-not $changed) {
        Write-Host '  EnableIntegrationWithDefaultWslDistro already true' -ForegroundColor Green
        return
    }

    ($settings | ConvertTo-Json -Depth 20) + "`n" | Set-Content -Path $Path -Encoding UTF8 -NoNewline
    Write-Host '  Set EnableIntegrationWithDefaultWslDistro=true' -ForegroundColor Green
}

function Test-WslDockerInfo {
    param([string]$Name)

    Write-Step "Verifying WSL docker info ($Name)"
    $output = wsl -d $Name -- docker info 2>&1
    $exit = $LASTEXITCODE
    if ($exit -eq 0) {
        Write-Host '  WSL docker info: OK' -ForegroundColor Green
        return $true
    }

    Write-Host '  WSL docker info: FAILED' -ForegroundColor Red
    Write-Host ($output | Out-String)
    Write-Host '  Hint: Docker Desktop -> Settings -> Resources -> WSL Integration -> enable this distro' -ForegroundColor Yellow
    return $false
}

Write-Host '=== Enable Docker Desktop WSL Integration ===' -ForegroundColor Cyan

Write-Step 'Updating Docker Desktop settings'
Set-WslIntegrationEnabled -Path $settingsPath

if (-not $SkipRestart) {
    if (Test-DockerDesktopRunning) {
        Stop-DockerDesktop
    }
    Start-DockerDesktop
} else {
    Write-Host '  Skipped Docker restart (-SkipRestart)' -ForegroundColor Yellow
}

$hostOk = $false
try {
    docker info 2>$null | Out-Null
    $hostOk = ($LASTEXITCODE -eq 0)
} catch {
    $hostOk = $false
}

if (-not $hostOk) {
    Write-Host 'WARN: Host docker info failed — WSL check may also fail' -ForegroundColor Yellow
}

$wslOk = Test-WslDockerInfo -Name $Distro
if (-not $wslOk) {
    exit 1
}

Write-Host "`nDone. Re-run .\scripts\detect-gpu.ps1 to confirm WSL Docker integration." -ForegroundColor Green
