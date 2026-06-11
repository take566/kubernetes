#Requires -Version 5.1
<#
.SYNOPSIS
  Windows AMD RX 5700 (8GB) — Ollama GPU stack setup (primary local inference path).
.DESCRIPTION
  Pulls recommended models, creates :rx5700 Modelfiles, runs smoke test and optional benchmark.
.PARAMETER SkipBenchmark
  Skip compare_models_ollama.ps1 after setup.
.PARAMETER CompareSet
  Passed to compare_models_ollama.ps1 (default | extended).
.EXAMPLE
  .\scripts\setup-ollama-rx5700.ps1
.EXAMPLE
  .\scripts\setup-ollama-rx5700.ps1 -CompareSet default -SkipBenchmark
#>
[CmdletBinding()]
param(
    [switch]$SkipBenchmark,

    [ValidateSet('default', 'extended', 'all')]
    [string]$CompareSet = 'default',

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

Write-Host '=== Ollama RX 5700 Setup (Windows GPU primary path) ===' -ForegroundColor Cyan

Write-Step 'GPU preflight'
& (Join-Path $PSScriptRoot 'detect-gpu.ps1')

Write-Step 'Ollama connectivity'
if (-not (Test-OllamaReachable -Url $OllamaBaseUrl)) {
    throw "Ollama not reachable at $OllamaBaseUrl — install from https://ollama.com"
}
Write-Host "  Ollama API: OK" -ForegroundColor Green

$installed = Get-OllamaModelNames -Url $OllamaBaseUrl

$pullModels = @(
    'qwen2.5:0.5b',
    'qwen2.5:1.5b',
    'sam860/LFM2:1.2b'
)

Write-Step 'Pull base models'
foreach ($m in $pullModels) {
    if ($installed -contains $m) {
        Write-Host "  $m — present" -ForegroundColor Green
        continue
    }
    Write-Host "  Pulling $m ..."
    & ollama pull $m
    if ($LASTEXITCODE -ne 0) { throw "ollama pull $m failed" }
    $installed = Get-OllamaModelNames -Url $OllamaBaseUrl
}

Write-Step 'RX5700 Modelfiles (:rx5700 tags)'
$ModelfileMap = @(
    @{ File = 'qwen2.5-0.5b-rx5700.Modelfile'; Name = 'qwen2.5:0.5b-rx5700' }
    @{ File = 'qwen2.5-1.5b-rx5700.Modelfile'; Name = 'qwen2.5:1.5b-rx5700' }
    @{ File = 'lfm2-1.2b-rx5700.Modelfile'; Name = 'sam860/LFM2:1.2b-rx5700' }
)
$ModelfilesDir = Join-Path $RepoRoot 'ollama\modelfiles'

foreach ($entry in $ModelfileMap) {
    $target = $entry.Name
    $modelfilePath = Join-Path $ModelfilesDir $entry.File
    if ($installed -contains $target) {
        Write-Host "  $target — present" -ForegroundColor Green
        continue
    }
    if (-not (Test-Path $modelfilePath)) {
        Write-Host "  SKIP $target — missing $($entry.File)" -ForegroundColor Yellow
        continue
    }
    Write-Host "  Creating $target ..."
    & ollama create $target -f $modelfilePath
    if ($LASTEXITCODE -ne 0) { throw "ollama create $target failed" }
    $installed = Get-OllamaModelNames -Url $OllamaBaseUrl
}

Write-Step 'Smoke test (qwen2.5:1.5b via OpenAI API)'
$benchScript = Join-Path $PSScriptRoot 'bench_ollama_openai.ps1'
if (Test-Path $benchScript) {
    $out = & $benchScript -Model 'qwen2.5:1.5b' -LatencySamples 3 -ThroughputRequests 5 -MaxTokens 32
    Write-Host "  Bench JSON: $out" -ForegroundColor DarkGray
} else {
    $body = @{ model = 'qwen2.5:1.5b'; prompt = 'Say OK'; stream = $false; options = @{ num_predict = 8 } } | ConvertTo-Json -Compress
    $null = Invoke-RestMethod -Uri "$OllamaBaseUrl/api/generate" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 120
    Write-Host '  /api/generate: OK' -ForegroundColor Green
}

if (-not $SkipBenchmark) {
    Write-Step "Model compare (COMPARE_SET=$CompareSet)"
    $env:COMPARE_SET = $CompareSet
    $compareScript = Join-Path $PSScriptRoot 'compare_models_ollama.ps1'
    if (Test-Path $compareScript) {
        & $compareScript
    }
}

Write-Host "`nSetup complete." -ForegroundColor Green
Write-Host '  Compare:  .\scripts\compare_models_ollama.ps1'
Write-Host '  OpenAI:   .\scripts\bench_ollama_openai.ps1 -HfId Qwen/Qwen2.5-1.5B-Instruct'
Write-Host '  Docs:     vllm/overlays/windows-local/README.md'
