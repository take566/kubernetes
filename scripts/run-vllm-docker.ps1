#Requires -Version 5.1
<#
.SYNOPSIS
  Run vLLM OpenAI-compatible server in Docker (NVIDIA GPU, GTX 1650 4GB tuned).
.DESCRIPTION
  Starts vllm/vllm-openai:latest with Qwen2.5-0.5B-Instruct and low-memory flags.
.PARAMETER Port
  Host port mapped to container 8000.
.PARAMETER StopExisting
  Stop and remove existing container named vllm-gtx1650 before starting.
.EXAMPLE
  .\scripts\run-vllm-docker.ps1
.EXAMPLE
  .\scripts\run-vllm-docker.ps1 -StopExisting
#>
[CmdletBinding()]
param(
    [int]$Port = 8000,
    [switch]$StopExisting
)

$ErrorActionPreference = 'Stop'

$ContainerName = 'vllm-gtx1650'
$Image = 'vllm/vllm-openai:latest'
$Model = 'Qwen/Qwen2.5-0.5B-Instruct'

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

Write-Step 'Checking Docker daemon'
docker info 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker daemon is not running. Start Docker Desktop first.'
}

if ($StopExisting) {
    $existing = docker ps -a -q -f "name=^${ContainerName}$" 2>$null
    if ($existing) {
        Write-Step "Removing existing container: $ContainerName"
        docker rm -f $ContainerName | Out-Null
    }
}

$running = docker ps -q -f "name=^${ContainerName}$" 2>$null
if ($running) {
    Write-Host "Container $ContainerName is already running (port $Port)." -ForegroundColor Green
    Write-Host "  Health: http://127.0.0.1:${Port}/v1/models"
    return
}

Write-Step "Starting $ContainerName ($Model)"
docker run -d `
    --name $ContainerName `
    --gpus all `
    -p "${Port}:8000" `
    $Image `
    --model $Model `
    --gpu-memory-utilization 0.85 `
    --max-model-len 2048 `
    --max-num-seqs 32 `
    --host 0.0.0.0 `
    --port 8000

if ($LASTEXITCODE -ne 0) {
    throw 'docker run failed. Ensure NVIDIA Container Toolkit is installed (Docker Desktop → Settings → Resources → GPU).'
}

Write-Host "vLLM started: http://127.0.0.1:${Port}/v1/models" -ForegroundColor Green
Write-Host 'Logs: docker logs -f vllm-gtx1650'
