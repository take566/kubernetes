#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$NodeName = '',
    [string]$Overlay = 'kind/amd',
    [string]$Distro = 'Ubuntu-24.04',
    [switch]$UseWsl
)

$ErrorActionPreference = 'Stop'

function Convert-ToWslPath([string]$WindowsPath) {
    $full = (Resolve-Path $WindowsPath).Path
    if ($full -match '^([A-Za-z]):\\(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = ($Matches[2] -replace '\\', '/')
        return "/mnt/$drive/$rest"
    }
    return ($full -replace '\\', '/')
}

$repoRoot = Split-Path -Parent $PSScriptRoot

if ($UseWsl) {
    $wslRepo = Convert-ToWslPath $repoRoot
    $nodeArg = if ($NodeName) { "NODE_NAME='$NodeName' " } else { '' }
    $overlayArg = "OVERLAY='$Overlay' "
    $cmd = "cd '$wslRepo' && ${nodeArg}${overlayArg}./scripts/setup-amd-gpu-node.sh"
    wsl -d $Distro -- bash -lc $cmd
    if ($LASTEXITCODE -ne 0) { throw "WSL execution failed (exit $LASTEXITCODE)" }
    exit 0
}

if (-not $NodeName) {
    $NodeName = (& kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
}
if (-not $NodeName) { throw 'NODE_NAME could not be resolved.' }

Write-Host "=== Applying AMD GPU device plugin ===" -ForegroundColor Cyan
& kubectl apply -k (Join-Path $repoRoot 'kubeadm\addons\amd-gpu-device-plugin')
if ($LASTEXITCODE -ne 0) { throw 'kubectl apply failed.' }

Write-Host "=== Labeling node: $NodeName ===" -ForegroundColor Cyan
& kubectl label node $NodeName 'amd.com/gpu.present=true' --overwrite
& kubectl label node $NodeName 'workload=vllm-amd' --overwrite

Write-Host "=== Verifying allocatable AMD GPU ===" -ForegroundColor Cyan
$alloc = (& kubectl get node $NodeName -o jsonpath='{.status.allocatable.amd\.com/gpu}')
if ($alloc) {
    Write-Host "amd.com/gpu allocatable on ${NodeName}: $alloc" -ForegroundColor Green
} else {
    Write-Host "WARN: amd.com/gpu is not yet allocatable on ${NodeName}" -ForegroundColor Yellow
    Write-Host "Check plugin pods: kubectl get pods -n kube-system | findstr amd" -ForegroundColor Yellow
}

if (-not $alloc) {
    Write-Host ''
    Write-Host 'RX 5700 + WSL/kind: K8s GPU requires Linux ROCm host (/dev/kfd).' -ForegroundColor Yellow
    Write-Host 'GPU inference on this PC: .\scripts\setup-ollama-rx5700.ps1' -ForegroundColor Yellow
    exit 1
}

Write-Host ''
Write-Host "=== Applying vLLM AMD overlay: vllm/overlays/$Overlay/ ===" -ForegroundColor Cyan
$overlayPath = Join-Path $repoRoot ("vllm\overlays\" + ($Overlay -replace '/', '\'))
kubectl kustomize $overlayPath --load-restrictor LoadRestrictionsNone | kubectl apply -f -
if ($LASTEXITCODE -ne 0) { throw 'vLLM AMD overlay apply failed.' }
Write-Host 'Monitor: kubectl -n vllm get pods -l app=vllm -w' -ForegroundColor Cyan
