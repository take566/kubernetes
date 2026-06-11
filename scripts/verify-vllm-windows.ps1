#Requires -Version 5.1
<#
.SYNOPSIS
  One-shot health check for Windows GTX 1650 vLLM + Ollama stack.
.DESCRIPTION
  Runs NVIDIA/Docker preflight (install-nvidia-toolkit-windows.ps1), optional Ollama smoke,
  and vLLM /health + /v1/chat/completions when the Docker container is reachable.
.PARAMETER SkipDockerGpuTest
  Pass through to install-nvidia-toolkit-windows.ps1 (faster repeat checks).
.PARAMETER SkipVllmChat
  Only hit /health and /v1/models, skip chat completion test.
.PARAMETER VllmBaseUrl
  OpenAI-compatible base URL (default http://127.0.0.1:8000).
.PARAMETER OllamaBaseUrl
  Ollama API base (default http://127.0.0.1:11434).
.EXAMPLE
  .\scripts\verify-vllm-windows.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipDockerGpuTest,
    [switch]$SkipVllmChat,
    [string]$VllmBaseUrl = 'http://127.0.0.1:8000',
    [string]$OllamaBaseUrl = 'http://127.0.0.1:11434',
    [string]$OllamaSmokeModel = 'qwen2.5:0.5b'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path

function Write-Step([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }

Write-Host '=== verify-vllm-windows (GTX 1650) ===' -ForegroundColor Cyan

Write-Step 'NVIDIA / Docker preflight'
$installArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $RepoRoot 'scripts\install-nvidia-toolkit-windows.ps1'))
if ($SkipDockerGpuTest) { $installArgs += '-SkipDockerGpuTest' }
& powershell @installArgs
if ($LASTEXITCODE -ne 0) { throw 'install-nvidia-toolkit-windows.ps1 reported failures.' }

Write-Step 'Ollama API'
try {
    $null = Invoke-RestMethod -Uri "$OllamaBaseUrl/api/tags" -Method Get -TimeoutSec 10
    Write-Host '  OK: Ollama reachable' -ForegroundColor Green
    $body = @{ model = $OllamaSmokeModel; prompt = 'Reply with exactly: OK'; stream = $false; options = @{ num_predict = 8 } } | ConvertTo-Json -Compress
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod -Uri "$OllamaBaseUrl/api/generate" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 120
    $sw.Stop()
    Write-Host ("  OK: smoke {0} ({1:F1}s)" -f $OllamaSmokeModel, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
} catch {
    Write-Host "  WARN: Ollama check failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Step 'Docker vLLM container'
$running = docker ps -q -f 'name=^vllm-gtx1650$' 2>$null
if (-not $running) {
    Write-Host '  WARN: vllm-gtx1650 not running. Start: .\scripts\run-vllm-docker.ps1 -StopExisting' -ForegroundColor Yellow
    exit 0
}
Write-Host '  OK: vllm-gtx1650 running' -ForegroundColor Green

Write-Step 'vLLM HTTP'
try {
    $health = Invoke-WebRequest -Uri "$VllmBaseUrl/health" -Method Get -TimeoutSec 30 -UseBasicParsing
    if ($health.StatusCode -ne 200) { throw "health HTTP $($health.StatusCode)" }
    Write-Host '  OK: GET /health' -ForegroundColor Green
    $models = Invoke-RestMethod -Uri "$VllmBaseUrl/v1/models" -Method Get -TimeoutSec 30
    $id = ($models.data | Select-Object -First 1).id
    Write-Host ("  OK: GET /v1/models ({0})" -f $id) -ForegroundColor Green
    if (-not $SkipVllmChat) {
        $chatBody = @{
            model    = $id
            messages = @(@{ role = 'user'; content = 'Say hi in one word' })
            max_tokens = 8
        } | ConvertTo-Json -Depth 5 -Compress
        $chat = Invoke-RestMethod -Uri "$VllmBaseUrl/v1/chat/completions" -Method Post -Body $chatBody -ContentType 'application/json' -TimeoutSec 120
        $text = $chat.choices[0].message.content
        Write-Host ("  OK: POST /v1/chat/completions -> {0}" -f ($text -replace '\s+', ' ').Trim()) -ForegroundColor Green
    }
} catch {
    throw "vLLM HTTP check failed: $($_.Exception.Message)"
}

Write-Host "`nAll verify steps completed." -ForegroundColor Green
