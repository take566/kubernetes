#Requires -Version 5.1
<#
.SYNOPSIS
  Expose Windows Ollama to WSL / kubeadm pods (non-ROCm GPU path for AMD RX 5700).
.DESCRIPTION
  1. Sets OLLAMA_HOST=0.0.0.0:11434 (user env) so WSL can reach the host via its gateway IP.
  2. Adds an inbound Windows Firewall rule for TCP 11434 (WSL virtual network).
  3. Prints restart instructions for Ollama.

  Run from elevated PowerShell if -ConfigureFirewall is used and rule creation fails.
.PARAMETER Port
  Ollama listen port (default 11434).
.PARAMETER ConfigureFirewall
  Create/update firewall rule (requires admin).
.PARAMETER SkipEnv
  Skip OLLAMA_HOST user environment variable.
.EXAMPLE
  .\scripts\configure-ollama-wsl-bridge.ps1 -ConfigureFirewall
#>
[CmdletBinding()]
param(
    [int]$Port = 11434,
    [switch]$ConfigureFirewall,
    [switch]$SkipEnv
)

$ErrorActionPreference = 'Stop'
$hostValue = "0.0.0.0:${Port}"

Write-Host '=== Ollama WSL / Kubernetes bridge (Windows host) ===' -ForegroundColor Cyan

if (-not $SkipEnv) {
    $current = [Environment]::GetEnvironmentVariable('OLLAMA_HOST', 'User')
    if ($current -ne $hostValue) {
        [Environment]::SetEnvironmentVariable('OLLAMA_HOST', $hostValue, 'User')
        $env:OLLAMA_HOST = $hostValue
        Write-Host "  OLLAMA_HOST set to $hostValue (User)" -ForegroundColor Green
    } else {
        Write-Host "  OLLAMA_HOST already $hostValue" -ForegroundColor Green
    }
}

if ($ConfigureFirewall) {
    $ruleName = 'Ollama WSL kubeadm bridge'
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($existing) {
        Set-NetFirewallRule -DisplayName $ruleName -Enabled True | Out-Null
        Write-Host "  Firewall rule updated: $ruleName" -ForegroundColor Green
    } else {
        New-NetFirewallRule `
            -DisplayName $ruleName `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort $Port `
            -Profile Private `
            -Description 'Allow WSL2/kubeadm pods to reach Windows Ollama for AMD GPU inference' | Out-Null
        Write-Host "  Firewall rule created: $ruleName" -ForegroundColor Green
    }
} else {
    Write-Host '  Tip: re-run with -ConfigureFirewall (admin) if WSL cannot connect' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  1. Restart Ollama: .\scripts\restart-ollama-wsl-bridge.ps1'
Write-Host '  2. Verify: netstat -an | findstr 11434  → should show 0.0.0.0:11434 LISTENING'
Write-Host '  3. From WSL: ./kubeadm/scripts/register-windows-ollama-external.sh'
Write-Host ''

$listening = netstat -an | Select-String "0\.0\.0\.0:${Port}\s+.*LISTENING"
if ($listening) {
    Write-Host "  Listen check: OK ($listening)" -ForegroundColor Green
} else {
    $loopback = netstat -an | Select-String "127\.0\.0\.1:${Port}\s+.*LISTENING"
    if ($loopback) {
        Write-Host '  Listen check: still 127.0.0.1 only — restart Ollama after setting OLLAMA_HOST' -ForegroundColor Yellow
    } else {
        Write-Host '  Listen check: Ollama not listening — start Ollama first' -ForegroundColor Yellow
    }
}
