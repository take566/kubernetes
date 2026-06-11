#Requires -Version 5.1
<#
.SYNOPSIS
  NVIDIA driver / CUDA Toolkit / Docker GPU preflight and install guidance (Windows).
.DESCRIPTION
  Audits nvidia-smi, CUDA Toolkit (nvcc), cuDNN, and docker --gpus on Windows 11.
.EXAMPLE
  .\scripts\install-nvidia-toolkit-windows.ps1
#>
[CmdletBinding()]
param(
    [switch]$InstallCudaWinget,
    [switch]$SkipDockerGpuTest,
    [string]$DockerGpuTestImage = 'nvidia/cuda:12.6.0-base-ubuntu22.04'
)

$ErrorActionPreference = 'Continue'
$script:FailCount = 0

function Write-Step([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "  OK: $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "  WARN: $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "  FAIL: $Message" -ForegroundColor Red; $script:FailCount++ }

function Get-NvidiaSmiFields {
    $out = & nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    $parts = ($out | Select-Object -First 1) -split ',\s*'
    [PSCustomObject]@{ Name = $parts[0]; DriverVersion = $parts[1]; MemoryTotal = $parts[2] }
}

function Get-CudaToolkitInfo {
    $nvcc = Get-Command nvcc -ErrorAction SilentlyContinue
    $cudaPath = $env:CUDA_PATH
    if (-not $cudaPath -and $nvcc) { $cudaPath = (Split-Path (Split-Path $nvcc.Source -Parent) -Parent) }
    $version = $null
    if ($nvcc) {
        $verLine = & nvcc --version 2>$null | Select-String 'release' | Select-Object -First 1
        if ($verLine) { $version = ($verLine -replace '.*release\s+', '').Trim() }
    }
    [PSCustomObject]@{ NvccPresent = [bool]$nvcc; NvccPath = if ($nvcc) { $nvcc.Source } else { $null }; CudaPath = $cudaPath; Version = $version }
}

function Test-CudnnPresent {
    $roots = @($env:CUDA_PATH, 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA', 'C:\Program Files\NVIDIA\CUDNN') | Where-Object { $_ -and (Test-Path $_) }
    foreach ($root in $roots) {
        $dlls = Get-ChildItem -Path $root -Recurse -Filter 'cudnn*.dll' -ErrorAction SilentlyContinue | Select-Object -First 3
        if ($dlls) { return [PSCustomObject]@{ Present = $true; Samples = @($dlls | ForEach-Object { $_.FullName }) } }
    }
    [PSCustomObject]@{ Present = $false; Samples = @() }
}

function Test-DockerDaemonRunning {
    docker info 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Test-DockerNvidiaRuntime {
    $info = docker info 2>&1 | Out-String
    return ($info -match 'nvidia')
}

function Invoke-DockerGpuSmokeTest([string]$Image) {
    Write-Step "Docker GPU smoke test ($Image)"
    $out = docker run --rm --gpus all $Image nvidia-smi 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Write-Fail 'docker run --gpus all failed'; Write-Host $out; return }
    if ($out -match 'NVIDIA-SMI') { Write-Ok 'Container sees GPU' } else { Write-Fail 'nvidia-smi missing in container' }
}

function Show-ManualCudaGuide {
    Write-Host '[CUDA Toolkit manual] https://developer.nvidia.com/cuda-downloads (Windows 11 x86_64). Pick Toolkit <= driver max CUDA runtime. Verify: nvcc --version' -ForegroundColor DarkGray
}
function Show-ManualCudnnGuide {
    Write-Host '[cuDNN manual] https://developer.nvidia.com/cudnn — copy bin/lib/include into %CUDA_PATH%. Optional for Docker vLLM/Ollama inference.' -ForegroundColor DarkGray
}
function Show-DockerGpuGuide {
    Write-Host '[Docker GPU] Docker Desktop -> Settings -> enable NVIDIA GPU; docker info should list nvidia runtime.' -ForegroundColor DarkGray
}

Write-Host '=== NVIDIA Toolkit Install / Verify (Windows) ===' -ForegroundColor Cyan

Write-Step 'NVIDIA driver'
$smi = Get-NvidiaSmiFields
if (-not $smi) { Write-Fail 'nvidia-smi unavailable'; Show-ManualCudaGuide }
else { Write-Ok ("GPU {0}, driver {1}, {2}" -f $smi.Name, $smi.DriverVersion, $smi.MemoryTotal) }

Write-Step 'CUDA Toolkit (nvcc)'
$cuda = Get-CudaToolkitInfo
if ($cuda.NvccPresent) { Write-Ok ("nvcc {0}" -f $cuda.Version); if ($cuda.CudaPath) { Write-Ok ("CUDA_PATH {0}" -f $cuda.CudaPath) } }
else {
    Write-Fail 'nvcc not on PATH'
    Show-ManualCudaGuide
    if ($InstallCudaWinget) {
        Write-Step 'winget install Nvidia.CUDA'
        winget install --id Nvidia.CUDA -e --accept-source-agreements --accept-package-agreements
    }
}

Write-Step 'cuDNN'
$cudnn = Test-CudnnPresent
if ($cudnn.Present) { Write-Ok 'cuDNN DLLs found'; $cudnn.Samples | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
else { Write-Warn 'cuDNN not detected (optional)'; Show-ManualCudnnGuide }

Write-Step 'Docker NVIDIA runtime'
if (-not (Test-DockerDaemonRunning)) { Write-Fail 'Docker daemon not running' }
elseif (Test-DockerNvidiaRuntime) { Write-Ok 'nvidia runtime in docker info' }
else { Write-Fail 'nvidia runtime missing'; Show-DockerGpuGuide }

if (-not $SkipDockerGpuTest -and (Test-DockerDaemonRunning)) { Invoke-DockerGpuSmokeTest -Image $DockerGpuTestImage }

Write-Step 'vLLM GTX 1650 hint'
Write-Host '  .\scripts\run-vllm-docker.ps1 -StopExisting  (0.75 util, max-model-len 2048, max-num-seqs 8, enforce-eager)' -ForegroundColor DarkGray

if ($script:FailCount -eq 0) { Write-Host 'Summary: critical checks passed.' -ForegroundColor Green; exit 0 }
Write-Host ("Summary: {0} failure(s)." -f $script:FailCount) -ForegroundColor Yellow
exit 1
