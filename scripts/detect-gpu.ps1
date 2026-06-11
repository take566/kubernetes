#Requires -Version 5.1
<#
.SYNOPSIS
  Preflight: detect local GPU and ML stack readiness (Windows host).
.EXAMPLE
  .\scripts\detect-gpu.ps1
#>
$ErrorActionPreference = 'Continue'

function Test-Command($name) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    [PSCustomObject]@{ Tool = $name; Present = [bool]$cmd; Path = if ($cmd) { $cmd.Source } else { $null } }
}

function Normalize-WslText([string]$text) {
    if (-not $text) { return '' }
    return ($text -replace "`0", '').Trim()
}

function Get-WslDefaultDistro {
    $line = Normalize-WslText ((cmd /c "wsl -l -q" 2>$null | Select-Object -First 1))
    if ($line) { return $line }
    return 'Ubuntu-24.04'
}

function Test-WslDxg([string]$distro) {
    wsl -d $distro -e test -e /dev/dxg 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return 'dxg-ok' }
    return 'dxg-missing'
}

Write-Host "=== Local GPU Preflight (Windows) ===" -ForegroundColor Cyan

$gpus = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Microsoft|Remote' }
if (-not $gpus) {
    Write-Host "WARN: No discrete GPU detected via Win32_VideoController" -ForegroundColor Yellow
} else {
    foreach ($g in $gpus) {
        $vramGiB = if ($g.AdapterRAM -and $g.AdapterRAM -gt 0) { [math]::Round($g.AdapterRAM / 1GB, 2) } else { 'n/a' }
        Write-Host ("GPU: {0}" -f $g.Name)
        Write-Host ("  DriverVersion: {0}" -f $g.DriverVersion)
        Write-Host ("  Status: {0}" -f $g.Status)
        Write-Host ("  AdapterRAM (reported): {0} GiB" -f $vramGiB)
        if ($g.Name -match '5700 XT|5700' -and $vramGiB -lt 6) {
            Write-Host "  Note: WMI often under-reports VRAM; RX 5700 is typically 8 GiB" -ForegroundColor DarkGray
        }
        if ($g.Name -match 'GTX 1650|1650') {
            Write-Host "  Profile: GTX 1650 — 4 GiB VRAM; use models <= 3B, num_ctx 2048-4096" -ForegroundColor DarkYellow
            Write-Host "  Quick start: .\scripts\setup-vllm-windows.ps1" -ForegroundColor DarkGray
        }
        if ($g.Name -match 'AMD|Radeon') {
            Write-Host "  Vendor: AMD — Windows display driver OK; ROCm is Linux/WSL only" -ForegroundColor DarkYellow
            if ($g.Name -match '5700|5600|5500|Navi 10|RDNA') {
                Write-Host "  Note: RX 5000 (gfx1010) is NOT officially ROCm-supported; community workaround required" -ForegroundColor Yellow
            }
        }
        if ($g.Name -match 'NVIDIA|GeForce|RTX|GTX') {
            Write-Host "  Vendor: NVIDIA — CUDA driver + nvidia-smi; Ollama (Windows) or Docker vLLM recommended" -ForegroundColor DarkYellow
            if ($g.Name -match '1650' -and $vramGiB -le 4.5) {
                Write-Host "  VRAM hint: prefer qwen2.5:0.5b, phi4-mini:gtx1650; avoid 7B+ on 4GB" -ForegroundColor Yellow
            }
        }
    }
}

Write-Host "`n--- Tooling ---" -ForegroundColor Cyan
@('nvidia-smi', 'rocm-smi', 'docker', 'kubectl', 'kind', 'wsl') | ForEach-Object {
    $t = Test-Command $_
    $status = if ($t.Present) { 'OK' } else { 'MISSING' }
    $color = if ($t.Present) { 'Green' } else { 'Red' }
    Write-Host ("  {0,-12} {1}" -f $t.Tool, $status) -ForegroundColor $color
}

Write-Host "`n--- Docker daemon ---" -ForegroundColor Cyan
try {
    docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "  Docker daemon: running" -ForegroundColor Green }
    else { Write-Host "  Docker daemon: NOT running (start Docker Desktop)" -ForegroundColor Red }
} catch {
    Write-Host "  Docker daemon: NOT running" -ForegroundColor Red
}

Write-Host "`n--- WSL ---" -ForegroundColor Cyan
try {
    # Avoid wsl --status (localized output garbles in some terminals).
    $defaultDistro = Get-WslDefaultDistro
    Write-Host ("  Default distro: {0}" -f $defaultDistro)
    $wslVerbose = Normalize-WslText ((cmd /c "wsl -l -v" 2>$null | Out-String))
    if ($wslVerbose -match 'Ubuntu-24.04') {
        Write-Host "  Ubuntu-24.04: installed" -ForegroundColor Green
    }
    $running = ([regex]::Matches($wslVerbose, 'Running')).Count
    Write-Host ("  Running distros: {0}" -f $running)
    $dxg = Test-WslDxg $defaultDistro
    $dxgColor = if ($dxg -eq 'dxg-ok') { 'Green' } else { 'Yellow' }
    Write-Host ("  WSL GPU device (/dev/dxg): {0}" -f $dxg) -ForegroundColor $dxgColor
} catch {
    Write-Host "  WSL check failed" -ForegroundColor Yellow
}

Write-Host "`n--- WSL Docker integration ---" -ForegroundColor Cyan
$wslDistro = 'Ubuntu-24.04'
try {
    $defaultDistro = Get-WslDefaultDistro
    if ($defaultDistro) { $wslDistro = $defaultDistro }
    wsl -d $wslDistro -- docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host ("  wsl -d {0} -- docker info: OK" -f $wslDistro) -ForegroundColor Green
    } else {
        Write-Host ("  wsl -d {0} -- docker info: MISSING" -f $wslDistro) -ForegroundColor Red
        Write-Host "  Hint: run .\scripts\enable-docker-wsl-integration.ps1" -ForegroundColor Yellow
    }
} catch {
    Write-Host ("  wsl -d {0} -- docker info: MISSING" -f $wslDistro) -ForegroundColor Red
    Write-Host "  Hint: run .\scripts\enable-docker-wsl-integration.ps1" -ForegroundColor Yellow
}

Write-Host "`n--- Recommendations ---" -ForegroundColor Cyan
$isNvidia = $gpus | Where-Object { $_.Name -match 'NVIDIA|GeForce|RTX|GTX' }
$isGtx1650 = $gpus | Where-Object { $_.Name -match '1650' }
$isAmd = $gpus | Where-Object { $_.Name -match 'AMD|Radeon' }

if ($isGtx1650) {
    Write-Host "  1. Run .\scripts\setup-vllm-windows.ps1 (Ollama + optional Docker vLLM)"
    Write-Host "  2. Models: qwen2.5:0.5b, phi4-mini:gtx1650 — see ollama/modelfiles/README.md"
    Write-Host "  3. Docker vLLM: .\scripts\run-vllm-docker.ps1 (Qwen2.5-0.5B, max-model-len 2048)"
    Write-Host "  4. K8s GPU benchmark: kubeadm or GitHub Actions (kind is CI-only, no GPU)"
} elseif ($isNvidia) {
    Write-Host "  1. Verify nvidia-smi; install Ollama for quick GPU inference on Windows"
    Write-Host "  2. Docker vLLM: .\scripts\run-vllm-docker.ps1 (tune --gpu-memory-utilization for VRAM)"
    Write-Host "  3. Full setup: .\scripts\setup-vllm-windows.ps1"
    Write-Host "  4. K8s benchmark: kubeadm NVIDIA overlay or GitHub Actions self-hosted runner"
} elseif ($isAmd) {
    Write-Host "  1. GPU inference (primary): .\scripts\setup-ollama-rx5700.ps1"
    Write-Host "  2. Model compare: .\scripts\compare_models_ollama.ps1"
    Write-Host "  3. OpenAI bench: .\scripts\bench_ollama_openai.ps1 -HfId Qwen/Qwen2.5-1.5B-Instruct"
    Write-Host "  4. WSL ROCm on RX 5700: not supported — see docs/LOCAL_GPU_SETUP_WINDOWS.md"
    Write-Host "  5. K8s manifest CI: kind (no GPU) or Actions vLLM Ollama Benchmark"
} else {
    Write-Host "  1. Start Docker Desktop if using containers or kind"
    Write-Host "  2. Quick local model smoke: Ollama (Windows)"
    Write-Host "  3. See docs/LOCAL_GPU_SETUP_WINDOWS.md"
}
