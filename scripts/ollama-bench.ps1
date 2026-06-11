#Requires -Version 5.1
<#
.SYNOPSIS
  Benchmark Ollama models via HTTP /api/generate (no TTY).
.PARAMETER Models
  One or more Ollama model tags.
.PARAMETER Prompt
  Prompt text sent to each model.
.PARAMETER BaseUrl
  Ollama API base URL (default http://127.0.0.1:11434).
.PARAMETER NumPredict
  Max tokens to generate (maps to options.num_predict).
.EXAMPLE
  .\scripts\ollama-bench.ps1 -Models qwen2.5:1.5b,sam860/LFM2:1.2b -Prompt "Say hello in one sentence."
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Models,

    [Parameter(Mandatory = $true)]
    [string]$Prompt,

    [string]$BaseUrl = 'http://127.0.0.1:11434',
    [int]$NumPredict = 256,
    [string]$OutputDir = ''
)

$ErrorActionPreference = 'Stop'

function Test-OllamaReachable {
    param([string]$Url)
    try {
        $null = Invoke-RestMethod -Uri "$Url/api/tags" -Method Get -TimeoutSec 10
        return $true
    } catch {
        return $false
    }
}

function Invoke-OllamaGenerate {
    param(
        [string]$Url,
        [string]$Model,
        [string]$Text,
        [int]$MaxTokens
    )

    $body = @{
        model   = $Model
        prompt  = $Text
        stream  = $false
        options = @{ num_predict = $MaxTokens }
    } | ConvertTo-Json -Depth 5 -Compress

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-RestMethod -Uri "$Url/api/generate" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 600
    $sw.Stop()

    $evalCount = [int]$response.eval_count
    $evalDurationNs = [double]$response.eval_duration
    $totalDurationNs = [double]$response.total_duration

    $tokensPerS = $null
    if ($evalCount -gt 0 -and $evalDurationNs -gt 0) {
        $tokensPerS = [math]::Round($evalCount / ($evalDurationNs / 1e9), 2)
    }

    $apiTotalS = if ($totalDurationNs -gt 0) { [math]::Round($totalDurationNs / 1e9, 2) } else { $null }

    [PSCustomObject]@{
        model         = $Model
        status        = 'OK'
        total_time_s  = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        tokens_per_s  = $tokensPerS
        notes         = "eval_count=$evalCount; api_total_s=$apiTotalS"
    }
}

Write-Host '=== Ollama HTTP Benchmark ===' -ForegroundColor Cyan
Write-Host "  Base URL: $BaseUrl"
Write-Host "  Models:   $($Models -join ', ')"

if (-not (Test-OllamaReachable -Url $BaseUrl)) {
    throw "Ollama not reachable at $BaseUrl 窶・start Ollama and ensure port 11434 is open."
}


$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$resolvedOut = Resolve-Path -Path (Join-Path $scriptDir '..') | Select-Object -ExpandProperty Path
$resultsDir = Join-Path $resolvedOut 'vllm\benchmark\results'
if ($OutputDir) {
    $resultsDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
}
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

$dateTag = Get-Date -Format 'yyyy-MM-dd'
$outFile = Join-Path $resultsDir "ollama-bench-$dateTag.json"

$results = New-Object System.Collections.Generic.List[object]

foreach ($model in $Models) {
    Write-Host "`n--- $model ---" -ForegroundColor Cyan
    try {
        $row = Invoke-OllamaGenerate -Url $BaseUrl -Model $model -Text $Prompt -MaxTokens $NumPredict
        Write-Host ("  OK  {0}s  {1} tok/s" -f $row.total_time_s, $row.tokens_per_s) -ForegroundColor Green
        $results.Add($row)
    } catch {
        Write-Host "  FAIL: $($_.Exception.Message)" -ForegroundColor Red
        $results.Add([PSCustomObject]@{
            model        = $model
            status       = 'FAIL'
            total_time_s = $null
            tokens_per_s = $null
            notes        = $_.Exception.Message
        })
    }
}

$json = $results | ConvertTo-Json -Depth 5
Set-Content -Path $outFile -Value $json -Encoding UTF8
Write-Host "`nWrote: $outFile" -ForegroundColor Green
