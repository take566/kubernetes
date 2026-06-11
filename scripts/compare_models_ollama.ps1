#Requires -Version 5.1
<#
.SYNOPSIS
  Compare Ollama models mapped from vLLM model-candidates (local GPU fallback).
.PARAMETER CompareSet
  Candidate set: default | extended | all
.PARAMETER Models
  Space-separated HuggingFace model IDs (overrides CompareSet)
.PARAMETER Prompt
  Benchmark prompt sent to each model.
.PARAMETER BaseUrl
  Ollama API base URL.
.EXAMPLE
  $env:COMPARE_SET = 'extended'; .\scripts\compare_models_ollama.ps1
.EXAMPLE
  .\scripts\compare_models_ollama.ps1 -Models 'Qwen/Qwen2.5-1.5B-Instruct LiquidAI/LFM2.5-1.2B-Instruct'
#>
[CmdletBinding()]
param(
    [ValidateSet('default', 'extended', 'all')]
    [string]$CompareSet = $(if ($env:COMPARE_SET) { $env:COMPARE_SET } else { 'default' }),

    [string]$Models = $(if ($env:MODELS) { $env:MODELS } else { '' }),

    [string]$Prompt = $(if ($env:BENCH_PROMPT) { $env:BENCH_PROMPT } else {
        'Explain Kubernetes GPU scheduling in two short sentences.'
    }),

    [string]$BaseUrl = $(if ($env:OLLAMA_BASE_URL) { $env:OLLAMA_BASE_URL } else { 'http://127.0.0.1:11434' }),

    [int]$NumPredict = $(if ($env:BENCH_NUM_PREDICT) { [int]$env:BENCH_NUM_PREDICT } else { 256 })
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$MapFile = Join-Path $RepoRoot 'vllm\benchmark\ollama-model-map.json'
$CandidatesFile = Join-Path $RepoRoot 'vllm\benchmark\model-candidates.yaml'
$ResultsDir = Join-Path $RepoRoot 'vllm\benchmark\results'
$BenchScript = Join-Path $PSScriptRoot 'ollama-bench.ps1'

function Get-ModelCandidatesFromYaml {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "model-candidates.yaml not found: $Path"
    }

    $text = Get-Content -Path $Path -Raw -Encoding UTF8

    $jsonBlock = $null
    if ($text -match '(?ms)MODEL_CANDIDATES:\s*\|\s*\r?\n\s+\[(.*?)\]\s*\r?\n') {
        $jsonBlock = '[' + $Matches[1].Trim() + ']'
    } else {
        throw 'Could not parse MODEL_CANDIDATES JSON array from model-candidates.yaml'
    }

    $candidates = $jsonBlock | ConvertFrom-Json
    $extendedLine = ''
    if ($text -match 'EXTENDED_COMPARE_SET:\s*"([^"]+)"') {
        $extendedLine = $Matches[1]
    }

    [PSCustomObject]@{
        Candidates   = $candidates
        ExtendedIds  = @($extendedLine -split '\s+' | Where-Object { $_ })
    }
}

function Get-CompareCandidateIds {
    param(
        [object]$YamlData,
        [string]$SetName
    )

    $defaultIds = @(
        'facebook/opt-125m',
        'Qwen/Qwen2.5-0.5B-Instruct',
        'Qwen/Qwen2.5-1.5B-Instruct'
    )

    switch ($SetName) {
        'extended' { return $YamlData.ExtendedIds }
        'all' { return ($defaultIds + $YamlData.ExtendedIds | Select-Object -Unique) }
        default { return $defaultIds }
    }
}

Write-Host '=== Ollama model comparison (local) ===' -ForegroundColor Cyan
Write-Host "  compare_set: $CompareSet"
Write-Host "  map:         $MapFile"

if (-not (Test-Path $MapFile)) {
    throw "Ollama model map not found: $MapFile"
}
if (-not (Test-Path $BenchScript)) {
    throw "ollama-bench.ps1 not found: $BenchScript"
}

$mapDoc = Get-Content -Path $MapFile -Raw -Encoding UTF8 | ConvertFrom-Json
$map = @{}
foreach ($prop in $mapDoc.mappings.PSObject.Properties) {
    $map[$prop.Name] = [string]$prop.Value
}

$yamlData = Get-ModelCandidatesFromYaml -Path $CandidatesFile

if ($Models.Trim()) {
    $hfIds = @($Models -split '\s+' | Where-Object { $_ })
    $CompareSet = 'custom'
} else {
    $hfIds = Get-CompareCandidateIds -YamlData $yamlData -SetName $CompareSet
}

Write-Host "  candidates:  $($hfIds.Count) HuggingFace IDs"

$ollamaModels = New-Object System.Collections.Generic.List[string]
$entries = New-Object System.Collections.Generic.List[object]

foreach ($hfId in $hfIds) {
    if (-not $map.ContainsKey($hfId)) {
        Write-Host "  SKIP (no Ollama map): $hfId" -ForegroundColor Yellow
        $entries.Add([PSCustomObject]@{
            hf_id      = $hfId
            ollama_tag = $null
            status     = 'SKIP'
            notes      = 'No entry in ollama-model-map.json'
        })
        continue
    }

    $tag = $map[$hfId]
    $ollamaModels.Add($tag)
    $entries.Add([PSCustomObject]@{
        hf_id      = $hfId
        ollama_tag = $tag
        status     = 'PENDING'
        notes      = $null
    })
}

$uniqueTags = $ollamaModels | Select-Object -Unique
if ($uniqueTags.Count -eq 0) {
    throw 'No mappable Ollama models to benchmark.'
}

Write-Host "  ollama tags: $($uniqueTags -join ', ')"

New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
$timestamp = Get-Date -Format 'yyyy-MM-ddTHHmmss'
$tempDir = Join-Path $ResultsDir "ollama-compare-tmp-$timestamp"
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

& $BenchScript `
    -Models $uniqueTags `
    -Prompt $Prompt `
    -BaseUrl $BaseUrl `
    -NumPredict $NumPredict `
    -OutputDir $tempDir

$benchFiles = Get-ChildItem -Path $tempDir -Filter 'ollama-bench-*.json' | Sort-Object LastWriteTime -Descending
if (-not $benchFiles) {
    throw 'ollama-bench.ps1 did not produce output JSON.'
}

$benchResults = Get-Content -Path $benchFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
$benchByTag = @{}
foreach ($row in @($benchResults)) {
    $benchByTag[$row.model] = $row
}

$mergedResults = New-Object System.Collections.Generic.List[object]
foreach ($entry in $entries) {
    if ($entry.status -eq 'SKIP') {
        $mergedResults.Add($entry)
        continue
    }

    $tag = $entry.ollama_tag
    if ($benchByTag.ContainsKey($tag)) {
        $b = $benchByTag[$tag]
        $mergedResults.Add([PSCustomObject]@{
            hf_id         = $entry.hf_id
            ollama_tag    = $tag
            status        = $b.status
            total_time_s  = $b.total_time_s
            tokens_per_s  = $b.tokens_per_s
            notes         = $b.notes
        })
    } else {
        $mergedResults.Add([PSCustomObject]@{
            hf_id         = $entry.hf_id
            ollama_tag    = $tag
            status        = 'FAIL'
            total_time_s  = $null
            tokens_per_s  = $null
            notes         = 'Benchmark result missing for tag'
        })
    }
}

$outFile = Join-Path $ResultsDir "ollama-compare-$timestamp.json"
$payload = [PSCustomObject]@{
    recorded_at  = (Get-Date).ToUniversalTime().ToString('o')
    compare_set  = $CompareSet
    gpu_profile  = $mapDoc.gpu_profile
    base_url     = $BaseUrl
    prompt       = $Prompt
    num_predict  = $NumPredict
    map_file     = 'vllm/benchmark/ollama-model-map.json'
    results      = $mergedResults
}

$payload | ConvertTo-Json -Depth 6 | Set-Content -Path $outFile -Encoding UTF8

Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
foreach ($r in $mergedResults) {
    $label = if ($r.hf_id) { $r.hf_id } else { $r.ollama_tag }
    if ($r.status -eq 'OK') {
        Write-Host ("  OK   {0} -> {1}  {2}s  {3} tok/s" -f $label, $r.ollama_tag, $r.total_time_s, $r.tokens_per_s) -ForegroundColor Green
    } elseif ($r.status -eq 'SKIP') {
        Write-Host ("  SKIP {0}" -f $label) -ForegroundColor Yellow
    } else {
        Write-Host ("  FAIL {0} -> {1}  {2}" -f $label, $r.ollama_tag, $r.notes) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host "Wrote: $outFile" -ForegroundColor Green
Write-Output $outFile
