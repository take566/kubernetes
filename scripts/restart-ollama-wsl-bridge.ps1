#Requires -Version 5.1
<#
.SYNOPSIS
  Restart Ollama so OLLAMA_HOST=0.0.0.0:11434 takes effect (after configure-ollama-wsl-bridge.ps1).
#>
$ErrorActionPreference = 'Stop'
$hostVal = [Environment]::GetEnvironmentVariable('OLLAMA_HOST', 'User')
if (-not $hostVal) { $hostVal = '0.0.0.0:11434' }

Get-Process ollama -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process 'ollama app' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'ollama'
$psi.Arguments = 'serve'
$psi.UseShellExecute = $false
$psi.Environment['OLLAMA_HOST'] = $hostVal
$null = [System.Diagnostics.Process]::Start($psi)

Start-Sleep -Seconds 3
Write-Host "OLLAMA_HOST=$hostVal"
netstat -an | Select-String '11434'
