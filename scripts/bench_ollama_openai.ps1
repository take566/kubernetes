#Requires -Version 5.1
<#
.SYNOPSIS
  Run bench_vllm.py against Ollama OpenAI-compatible API (/v1/chat/completions).
.DESCRIPTION
  Resolves HuggingFace model IDs via vllm/benchmark/ollama-model-map.json when needed.
  Output JSON matches vLLM bench format for BENCHMARK_RESULTS.md.
.PARAMETER Model
  Ollama tag (qwen2.5:1.5b) or HuggingFace ID (Qwen/Qwen2.5-1.5B-Instruct).
.PARAMETER HfId
  HuggingFace ID — looks up Ollama tag in ollama-model-map.json (overrides -Model when set).
.EXAMPLE
  .\scripts\bench_ollama_openai.ps1 -Model qwen2.5:1.5b
.EXAMPLE
  .\scripts\bench_ollama_openai.ps1 -HfId Qwen/Qwen2.5-1.5B-Instruct
#>
[CmdletBinding()]
param(
    [string]$Model = $(if ($env:OLLAMA_MODEL) { $env:OLLAMA_MODEL } else { 'qwen2.5:1.5b' }),

    [string]$HfId = $(if ($env:HF_MODEL_ID) { $env:HF_MODEL_ID } else { '' }),

    [string]$BaseUrl = $(if ($env:OLLAMA_OPENAI_BASE_URL) { $env:OLLAMA_OPENAI_BASE_URL } else { 'http://127.0.0.1:11434/v1' }),

    [string]$Prompt = $(if ($env:BENCH_PROMPT) { $env:BENCH_PROMPT } else {
        'Write a short paragraph about Kubernetes GPU scheduling.'
    }),

    [int]$MaxTokens = $(if ($env:BENCH_MAX_TOKENS) { [int]$env:BENCH_MAX_TOKENS } else { 64 }),

    [int]$LatencySamples = $(if ($env:BENCH_LATENCY_SAMPLES) { [int]$env:BENCH_LATENCY_SAMPLES } else { 10 }),

    [int]$ThroughputRequests = $(if ($env:BENCH_THROUGHPUT_REQUESTS) { [int]$env:BENCH_THROUGHPUT_REQUESTS } else { 20 }),

    [string]$OutputFile = $(if ($env:BENCH_OUTPUT_FILE) { $env:BENCH_OUTPUT_FILE } else { '' })
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$BenchPy = Join-Path $RepoRoot 'vllm\benchmark\scripts\bench_vllm.py'
$MapFile = Join-Path $RepoRoot 'vllm\benchmark\ollama-model-map.json'
$ResultsDir = Join-Path $RepoRoot 'vllm\benchmark\results'

function Resolve-OllamaTag {
    param([string]$IdOrTag)

    if ($IdOrTag -notmatch '/') {
        return $IdOrTag
    }

    if (-not (Test-Path $MapFile)) {
        throw "HuggingFace ID requires ollama-model-map.json: $MapFile"
    }

    $mapDoc = Get-Content -Path $MapFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $tag = $mapDoc.mappings.$IdOrTag
    if (-not $tag) {
        throw "No Ollama mapping for HuggingFace ID: $IdOrTag"
    }
    return [string]$tag
}

function Test-OllamaOpenAi {
    param([string]$RootV1)
    $root = $RootV1.TrimEnd('/v1').TrimEnd('/')
    try {
        $null = Invoke-RestMethod -Uri "$root/api/tags" -Method Get -TimeoutSec 10
        return $true
    } catch {
        return $false
    }
}

$ollamaTag = if ($HfId) { Resolve-OllamaTag -IdOrTag $HfId } else { Resolve-OllamaTag -IdOrTag $Model }

Write-Host '=== Ollama OpenAI benchmark (bench_vllm.py) ===' -ForegroundColor Cyan
Write-Host "  ollama tag: $ollamaTag"
Write-Host "  base_url:   $BaseUrl"

if (-not (Test-OllamaOpenAi -RootV1 $BaseUrl)) {
    throw "Ollama not reachable. Start Ollama and verify http://127.0.0.1:11434/api/tags"
}

if (-not (Test-Path $BenchPy)) {
    throw "bench_vllm.py not found: $BenchPy"
}

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    $python = Get-Command python3 -ErrorAction SilentlyContinue
}
if (-not $python) {
    throw 'python or python3 is required for bench_vllm.py'
}

try {
    & $python.Source -m pip install --quiet aiohttp 2>$null
} catch {
    Write-Host '  WARN: pip install aiohttp failed — ensure aiohttp is installed' -ForegroundColor Yellow
}

New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
if (-not $OutputFile) {
    $safe = ($ollamaTag -replace '[:/\\]', '_')
    $OutputFile = Join-Path $ResultsDir "bench-ollama-openai-$safe-$(Get-Date -Format 'yyyy-MM-ddTHHmmss').json"
}

$env:BENCH_SKIP_HEALTH = '1'

$jsonOut = & $python.Source $BenchPy `
    --base-url $BaseUrl `
    --model $ollamaTag `
    --prompt $Prompt `
    --max-tokens $MaxTokens `
    --latency-samples $LatencySamples `
    --throughput-requests $ThroughputRequests `
    --skip-health

if ($LASTEXITCODE -ne 0) {
    throw "bench_vllm.py exited with code $LASTEXITCODE"
}

$jsonOut | Set-Content -Path $OutputFile -Encoding UTF8
Write-Host "Wrote: $OutputFile" -ForegroundColor Green
Write-Output $OutputFile
