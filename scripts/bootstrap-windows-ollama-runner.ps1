#Requires -Version 5.1
<#
.SYNOPSIS
  Install and register a GitHub Actions self-hosted runner on Windows for Ollama GPU benchmarks.
.DESCRIPTION
  Downloads actions-runner (win-x64), runs preflight checks (Ollama + gh CLI), obtains a
  registration token via GitHub API, and configures the runner with labels for
  vllm-ollama-benchmark.yaml (self-hosted, Windows, ollama).
.PARAMETER RunnerDir
  Directory to install the runner (default: %USERPROFILE%\actions-runner).
.PARAMETER RepoUrl
  GitHub repository URL (default: https://github.com/take566/kubernetes).
.PARAMETER Labels
  Comma-separated runner labels (default: self-hosted,Windows,ollama).
.PARAMETER InstallService
  Install and start the runner as a Windows service (svc.cmd install && start).
.PARAMETER Force
  Re-configure even when .runner already exists.
.EXAMPLE
  .\scripts\bootstrap-windows-ollama-runner.ps1
.EXAMPLE
  .\scripts\bootstrap-windows-ollama-runner.ps1 -InstallService
.EXAMPLE
  .\scripts\bootstrap-windows-ollama-runner.ps1 -RunnerDir D:\runners\actions -Force
#>
[CmdletBinding()]
param(
    [string]$RunnerDir = (Join-Path $env:USERPROFILE 'actions-runner'),

    [string]$RepoUrl = 'https://github.com/take566/kubernetes',

    [string]$Labels = 'self-hosted,Windows,ollama',

    [switch]$InstallService,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "  OK: $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Host "  WARN: $Message" -ForegroundColor Yellow
}

function Write-Skip([string]$Message) {
    Write-Host "  SKIP: $Message" -ForegroundColor Yellow
}

function Get-RepoSlugFromUrl([string]$Url) {
    $normalized = $Url.TrimEnd('/')
    if ($normalized -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$') {
        return "$($Matches.owner)/$($Matches.repo)"
    }
    throw "Cannot parse GitHub repo from RepoUrl: $Url (expected https://github.com/OWNER/REPO)"
}

function Test-GhCliReady {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'gh CLI is not installed. Install from https://cli.github.com and run: gh auth login'
    }
    gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'gh CLI is not logged in. Run: gh auth login'
    }
}

function Test-TokenPrefixWarning {
    param(
        [string]$Label,
        [string]$Token
    )
    if ([string]::IsNullOrWhiteSpace($Token)) { return }
    if ($Token.StartsWith('gho_')) {
        Write-Warn "$Label looks like gh CLI OAuth (gho_*). Use a classic PAT (ghp_*) with repo + workflow scopes for K8s github-runners-secret and long-lived runner registration."
    }
}

function Test-GhAuthTokenPrefix {
    try {
        $token = gh auth token 2>$null
        if ($LASTEXITCODE -eq 0 -and $token) {
            Test-TokenPrefixWarning -Label 'gh auth token' -Token $token.Trim()
        }
    } catch {
        # Non-fatal; registration token API may still succeed.
    }
}

function Test-K8sGithubRunnersSecretPrefix {
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) { return }
    try {
        $b64 = kubectl get secret github-runners-secret -n github-runners `
            -o jsonpath='{.data.github_token}' 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($b64)) { return }
        $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
        Test-TokenPrefixWarning -Label 'K8s secret github-runners-secret (github-runners/github-runners-secret)' -Token $decoded.Trim()
    } catch {
        # Non-fatal; cluster may be unreachable.
    }
}

function Test-OllamaPreflight {
    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        throw 'ollama is not on PATH. Install from https://ollama.com and ensure the daemon is running.'
    }
    $version = & ollama --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ollama --version failed: $version"
    }
    Write-Ok "ollama ($($version -join ' '))"

    $tagsUrl = 'http://127.0.0.1:11434/api/tags'
    try {
        $null = Invoke-RestMethod -Uri $tagsUrl -Method Get -TimeoutSec 10
        Write-Ok "Ollama API reachable ($tagsUrl)"
    } catch {
        throw "Ollama API not reachable at $tagsUrl — start the Ollama service/app first."
    }
}

function Get-RegistrationToken([string]$RepoSlug) {
    $json = gh api "repos/$RepoSlug/actions/runners/registration-token" -X POST 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to obtain registration token via gh api (repos/$RepoSlug): $json"
    }
    $parsed = $json | ConvertFrom-Json
    if (-not $parsed.token) {
        throw 'Registration token response did not include a token field.'
    }
    return $parsed.token
}

function Get-LatestRunnerAsset {
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/actions/runner/releases/latest' -Method Get
    $asset = $release.assets | Where-Object { $_.name -like 'actions-runner-win-x64-*.zip' } | Select-Object -First 1
    if (-not $asset) {
        throw 'Could not find actions-runner-win-x64-*.zip in latest actions/runner release.'
    }
    return $asset
}

function Ensure-RunnerDownloaded([string]$TargetDir) {
    $configCmd = Join-Path $TargetDir 'config.cmd'
    if (Test-Path -LiteralPath $configCmd) {
        Write-Skip "Runner binaries already present ($TargetDir)"
        return
    }

    Write-Step 'Downloading latest actions-runner (win-x64)'
    $asset = Get-LatestRunnerAsset
    Write-Host "  Release: $($asset.name)" -ForegroundColor DarkGray

    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    $zipPath = Join-Path $env:TEMP $asset.name

    if (Test-Path -LiteralPath $zipPath) {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            [void][System.IO.Compression.ZipFile]::OpenRead($zipPath)
        } catch {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path -LiteralPath $zipPath)) {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing
    }

    if (Test-Path -LiteralPath $TargetDir) {
        Get-ChildItem -LiteralPath $TargetDir -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $TargetDir)
    if (-not (Test-Path -LiteralPath $configCmd)) {
        throw "Extract completed but config.cmd not found under $TargetDir"
    }
    Write-Ok "Runner extracted to $TargetDir"
}

function Test-RunnerConfigured([string]$TargetDir) {
    $runnerFile = Join-Path $TargetDir '.runner'
    return (Test-Path -LiteralPath $runnerFile)
}

function Invoke-RunnerConfigure {
    param(
        [string]$TargetDir,
        [string]$Url,
        [string]$RegistrationToken,
        [string]$LabelList,
        [switch]$Replace
    )

    $configArgs = @(
        '--unattended',
        '--url', $Url,
        '--token', $RegistrationToken,
        '--labels', $LabelList
    )
    if ($Replace) {
        $configArgs += '--replace'
    }

    Push-Location -LiteralPath $TargetDir
    try {
        & .\config.cmd @configArgs
        if ($LASTEXITCODE -ne 0) {
            throw "config.cmd failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
    Write-Ok "Runner configured (labels: $LabelList)"
}

function Install-RunnerService([string]$TargetDir) {
    $svcCmd = Join-Path $TargetDir 'svc.cmd'
    $runnerService = Join-Path $TargetDir 'bin\RunnerService.exe'

    Push-Location -LiteralPath $TargetDir
    try {
        if (Test-Path -LiteralPath $svcCmd) {
            & .\svc.cmd install
            if ($LASTEXITCODE -ne 0) { throw "svc.cmd install failed with exit code $LASTEXITCODE" }
            Write-Ok 'Runner service installed (svc.cmd)'

            & .\svc.cmd start
            if ($LASTEXITCODE -ne 0) { throw "svc.cmd start failed with exit code $LASTEXITCODE" }
            Write-Ok 'Runner service started (svc.cmd)'
            return
        }

        if (Test-Path -LiteralPath $runnerService) {
            & $runnerService install
            if ($LASTEXITCODE -ne 0) { throw "RunnerService.exe install failed with exit code $LASTEXITCODE" }
            Write-Ok 'Runner service installed (RunnerService.exe)'

            & $runnerService start
            if ($LASTEXITCODE -ne 0) { throw "RunnerService.exe start failed with exit code $LASTEXITCODE" }
            Write-Ok 'Runner service started (RunnerService.exe)'
            return
        }

        throw "No service installer found (expected svc.cmd or bin\RunnerService.exe under $TargetDir)"
    } finally {
        Pop-Location
    }
}

Write-Host '=== Bootstrap Windows Ollama GitHub Actions Runner ===' -ForegroundColor Cyan

Write-Step 'Preflight: gh CLI'
Test-GhCliReady
Write-Ok 'gh CLI authenticated'
Test-GhAuthTokenPrefix
Test-K8sGithubRunnersSecretPrefix

Write-Step 'Preflight: Ollama'
Test-OllamaPreflight

$repoSlug = Get-RepoSlugFromUrl -Url $RepoUrl
Write-Step "Runner target: $RunnerDir (repo: $repoSlug)"

Ensure-RunnerDownloaded -TargetDir $RunnerDir

$alreadyConfigured = Test-RunnerConfigured -TargetDir $RunnerDir
if ($alreadyConfigured -and -not $Force) {
    Write-Skip "Runner already configured (.runner exists). Use -Force to re-register."
} else {
    Write-Step 'Register runner with GitHub'
    $regToken = Get-RegistrationToken -RepoSlug $repoSlug
    Invoke-RunnerConfigure `
        -TargetDir $RunnerDir `
        -Url $RepoUrl `
        -RegistrationToken $regToken `
        -LabelList $Labels `
        -Replace:($alreadyConfigured -or $Force)
}

if ($InstallService) {
    Write-Step 'Install runner Windows service'
    Install-RunnerService -TargetDir $RunnerDir
} else {
    Write-Host "`nTo run interactively: cd `"$RunnerDir`" ; .\run.cmd" -ForegroundColor DarkGray
    Write-Host "To install as a service: re-run with -InstallService" -ForegroundColor DarkGray
}

Write-Host "`n=== Bootstrap complete ===" -ForegroundColor Green
Write-Host "Verify: gh api repos/$repoSlug/actions/runners --jq '.runners[] | {name, labels: [.labels[].name]}'"
Write-Host "Benchmark: gh workflow run vllm-ollama-benchmark.yaml -f compare_set=default -f run_benchmark=true"
