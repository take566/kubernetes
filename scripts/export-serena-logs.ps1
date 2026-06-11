#Requires -Version 5.1
<#
.SYNOPSIS
  Export Serena logs from Elasticsearch to local JSONL without a Kubernetes Job.

.DESCRIPTION
  Runs vllm/components/serena-export/scripts/serena_export.py against a local or
  port-forwarded Elasticsearch instance. Useful on Windows dev machines.

.PARAMETER EsUrl
  Elasticsearch URL (default: http://localhost:9200).

.PARAMETER Index
  Index name (default: logs-serena).

.PARAMETER MinQuality
  Minimum serena.quality.score (default: 0.6).

.PARAMETER OutputDir
  Output directory (default: .\dataset).

.PARAMETER PortForward
  Start kubectl port-forward to elasticsearch:9200 in elk-stack namespace.

.EXAMPLE
  .\scripts\export-serena-logs.ps1 -PortForward

.EXAMPLE
  .\scripts\export-serena-logs.ps1 -EsUrl http://localhost:9200 -OutputDir D:\dataset
#>
[CmdletBinding()]
param(
    [string] $EsUrl = "http://localhost:9200",
    [string] $Index = "logs-serena",
    [double] $MinQuality = 0.6,
    [string] $OutputDir = (Join-Path (Get-Location) "dataset"),
    [switch] $PortForward,
    [string] $Namespace = "elk-stack",
    [string] $Python = "python"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$ExportScript = Join-Path $RepoRoot "vllm\components\serena-export\scripts\serena_export.py"

if (-not (Test-Path $ExportScript)) {
    throw "Export script not found: $ExportScript"
}

$pfJob = $null
if ($PortForward) {
    Write-Host "Starting port-forward svc/elasticsearch 9200:9200 -n $Namespace ..."
    $pfJob = Start-Job -ScriptBlock {
        param($Ns)
        kubectl port-forward svc/elasticsearch 9200:9200 -n $Ns
    } -ArgumentList $Namespace
    Start-Sleep -Seconds 3
}

try {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    $env:ES_URL = $EsUrl
    $env:ES_INDEX = $Index
    $env:MIN_QUALITY = [string]$MinQuality
    $env:OUTPUT_DIR = $OutputDir
    $env:MARK_EXPORTED = "false"

    Write-Host "Exporting from $EsUrl index=$Index min_quality=$MinQuality -> $OutputDir"
    & $Python $ExportScript
    if ($LASTEXITCODE -ne 0) {
        throw "serena_export.py exited with code $LASTEXITCODE"
    }

    $latest = Get-ChildItem -Path $OutputDir -Filter "serena-export-*.jsonl" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($latest) {
        $lines = (Get-Content $latest.FullName | Measure-Object -Line).Lines
        Write-Host "Wrote $($latest.FullName) ($lines lines)"
    }
}
finally {
    if ($pfJob) {
        Stop-Job $pfJob -ErrorAction SilentlyContinue
        Remove-Job $pfJob -Force -ErrorAction SilentlyContinue
    }
}
