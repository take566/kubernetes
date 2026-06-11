#Requires -Version 5.1
<#
.SYNOPSIS
  Windows local ML stack setup: GPU detect, Ollama models, optional Docker vLLM.
.DESCRIPTION
  1. Runs detect-gpu.ps1
  2. Verifies Ollama at http://127.0.0.1:11434
  3. Pulls qwen2.5:0.5b if missing
  4. Creates :gtx1650 models from ollama/modelfiles/ when missing
  5. Ollama API smoke test
  6. Optionally starts Docker vLLM (Qwen2.5-0.5B)
.PARAMETER SkipVllmDocker
  Skip Docker vLLM container start.
.PARAMETER SmokeModel
  Model tag used for smoke test (default: qwen2.5:0.5b).
.EXAMPLE
  .\scripts\setup-vllm-windows.ps1
.EXAMPLE
  .\scripts\setup-vllm-windows.ps1 -SkipVllmDocker
#>
[CmdletBinding()]
param(
    [switch]$SkipVllmDocker,
    [string]$SmokeModel = 'qwen2.5:0.5b',
    [string]$OllamaBaseUrl = 'http://127.0.0.1:11434'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Test-OllamaReachable([string]$Url) {
    try {
        $null = Invoke-RestMethod -Uri "$Url/api/tags" -Method Get -TimeoutSec 10
        return $true
    } catch {
        return $false
    }
}

function Get-OllamaModelNames([string]$Url) {
    $tags = Invoke-RestMethod -Uri "$Url/api/tags" -Method Get -TimeoutSec 30
    if (-not $tags.models) { return @() }
    return @($tags.models | ForEach-Object { $_.name })
}

function Invoke-OllamaSmokeTest {
    param(
        [string]$Url,
        [string]$Model,
        [string]$Prompt = 'Reply with exactly: OK'
    )
    $body = @{
        model   = $Model
        prompt  = $Prompt
        stream  = $false
        options = @{ num_predict = 16 }
    } | ConvertTo-Json -Depth 5 -Compress

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-RestMethod -Uri "$Url/api/generate" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 120
    $sw.Stop()

    $evalCount = [int]$response.eval_count
    $evalDurationNs = [double]$response.eval_duration
    $tokensPerS = $null
    if ($evalCount -gt 0 -and $evalDurationNs -gt 0) {
        $tokensPerS = [math]::Round($evalCount / ($evalDurationNs / 1e9), 2)
    }

    [PSCustomObject]@{
        Model       = $Model
        Status      = 'OK'
        ElapsedSec  = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        TokensPerS  = $tokensPerS
        Response    = ($response.response -replace '\s+', ' ').Trim().Substring(0, [math]::Min(80, ($response.response -replace '\s+', ' ').Trim().Length))
    }
}

Write-Host '=== vLLM / Ollama Windows Setup (GTX 1650) ===' -ForegroundColor Cyan

Write-Step 'GPU preflight (detect-gpu.ps1)'
& (Join-Path $PSScriptRoot 'detect-gpu.ps1')

Write-Step 'Ollama connectivity'
if (-not (Test-OllamaReachable -Url $OllamaBaseUrl)) {
    throw "Ollama not reachable at $OllamaBaseUrl — install from https://ollama.com and start the app."
}
Write-Host "  Ollama API: OK ($OllamaBaseUrl)" -ForegroundColor Green

$installed = Get-OllamaModelNames -Url $OllamaBaseUrl

Write-Step 'Base model: qwen2.5:0.5b'
if ($installed -notcontains 'qwen2.5:0.5b') {
    Write-Host '  Pulling qwen2.5:0.5b ...'
    & ollama pull qwen2.5:0.5b
    if ($LASTEXITCODE -ne 0) { throw 'ollama pull qwen2.5:0.5b failed' }
    $installed = Get-OllamaModelNames -Url $OllamaBaseUrl
} else {
    Write-Host '  Already present' -ForegroundColor Green
}

Write-Step 'GTX 1650 custom models (Modelfiles)'
$ModelfileMap = @(
    @{ File = 'phi4-mini-gtx1650.Modelfile'; Name = 'phi4-mini:gtx1650' }
)
$ModelfilesDir = Join-Path $RepoRoot 'ollama\modelfiles'

foreach ($entry in $ModelfileMap) {
    $target = $entry.Name
    $modelfilePath = Join-Path $ModelfilesDir $entry.File
    if ($installed -contains $target) {
        Write-Host "  $target — already present" -ForegroundColor Green
        continue
    }
    if (-not (Test-Path $modelfilePath)) {
        Write-Host "  SKIP $target — Modelfile not found: $modelfilePath" -ForegroundColor Yellow
        continue
    }
    Write-Host "  Creating $target from $($entry.File) ..."
    & ollama create $target -f $modelfilePath
    if ($LASTEXITCODE -ne 0) { throw "ollama create $target failed" }
    $installed = Get-OllamaModelNames -Url $OllamaBaseUrl
}

Write-Step "Ollama smoke test ($SmokeModel)"
if ($installed -notcontains $SmokeModel) {
    throw "Smoke model '$SmokeModel' not installed. Pull or create it first."
}
try {
    $result = Invoke-OllamaSmokeTest -Url $OllamaBaseUrl -Model $SmokeModel
    Write-Host ("  PASS  {0}s  {1} tok/s" -f $result.ElapsedSec, $result.TokensPerS) -ForegroundColor Green
    Write-Host ("  Sample: {0}" -f $result.Response) -ForegroundColor DarkGray
} catch {
    throw "Ollama smoke test failed: $($_.Exception.Message)"
}

if (-not $SkipVllmDocker) {
    Write-Step 'Docker vLLM (optional, Qwen2.5-0.5B)'
    $runScript = Join-Path $PSScriptRoot 'run-vllm-docker.ps1'
    if (Test-Path $runScript) {
        try {
            & $runScript
        } catch {
            Write-Host "  Docker vLLM skipped: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host '  Retry later: .\scripts\run-vllm-docker.ps1' -ForegroundColor DarkGray
        }
    }
} else {
    Write-Host "`nSkipped Docker vLLM (-SkipVllmDocker)." -ForegroundColor DarkGray
}

Write-Host "`nSetup complete." -ForegroundColor Green
Write-Host '  Ollama:  ollama list'
Write-Host '  vLLM:    http://127.0.0.1:8000/v1/models  (if Docker container started)'
