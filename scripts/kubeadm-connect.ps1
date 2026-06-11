#Requires -Version 5.1
<#
.SYNOPSIS
  Prepare kubectl access to a remote kubeadm cluster from Windows (merge kubeconfig, SSH tunnel, verify GPU).
#>
param(
    [ValidateSet('status', 'fetch', 'merge', 'tunnel', 'verify')]
    [string] $Action = 'status',
    [string] $KubeconfigPath = '',
    [string] $ContextName = 'kubeadm-prod',
    [string] $Context = '',
    [string] $SshTarget = '',
    [int] $LocalPort = 16443,
    [string] $RemoteHost = '127.0.0.1',
    [int] $RemotePort = 6443,
    [string] $ServerUrl = ''
)

$ErrorActionPreference = 'Stop'
$kubeDir = Join-Path $env:USERPROFILE '.kube'
$mainConfig = Join-Path $kubeDir 'config'

function Write-Section([string]$title) {
    Write-Host ""
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Invoke-Kubectl {
    param([string[]]$Args)
    & kubectl @Args
    if ($LASTEXITCODE -ne 0) { throw "kubectl failed: $($Args -join ' ')" }
}

function Get-ControlPlaneDns {
    param([string]$ServerUrl, [string]$SshTarget)
    if ($ServerUrl) {
        if ($ServerUrl -match '^https?://([^:/]+)') { return $Matches[1] }
    }
    if ($SshTarget) {
        $hostPart = ($SshTarget -split '@')[-1]
        return ($hostPart -split ':')[0]
    }
    return ''
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$defaultKubeadmConfig = Join-Path $kubeDir 'config-kubeadm'
$exportScript = Join-Path $repoRoot 'kubeadm\scripts\08-export-kubeconfig.sh'

switch ($Action) {
    'status' {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        Write-Section 'kubectl contexts'
        kubectl config get-contexts
        Write-Section 'Notes'
        Write-Host 'awx context = minikube profile (not kubeadm). See docs/kubeadm-connect.md'
        $kubeadmCfg = Join-Path $kubeDir 'config-kubeadm'
        if (Test-Path $kubeadmCfg) {
            Write-Host "Found: $kubeadmCfg"
        } else {
            Write-Host "Missing: $kubeadmCfg (scp from control-plane admin.conf)"
        }
        foreach ($ctx in @('awx', 'kind-dev', $ContextName)) {
            if (-not $ctx) { continue }
            Write-Host ""
            Write-Host "--- cluster-info: $ctx ---"
            $out = kubectl --context=$ctx cluster-info 2>&1
            if ($LASTEXITCODE -eq 0) {
                $out | Select-Object -First 3
            } else {
                Write-Host "  unreachable ($($out | Select-Object -First 1))"
            }
        }
        $ErrorActionPreference = $prevEap
    }
    'fetch' {
        if (-not $SshTarget) { throw 'Specify -SshTarget user@host' }
        if (-not (Test-Path $exportScript)) { throw "Missing export script: $exportScript" }
        $cpDns = Get-ControlPlaneDns -ServerUrl $ServerUrl -SshTarget $SshTarget
        if (-not $cpDns) { throw 'Could not determine CONTROL_PLANE_DNS; pass -ServerUrl or -SshTarget' }
        $dest = if ($KubeconfigPath) { $KubeconfigPath } else { $defaultKubeadmConfig }
        if (-not (Test-Path $kubeDir)) { New-Item -ItemType Directory -Path $kubeDir | Out-Null }
        $remoteTmp = "/tmp/kubeadm-export-$([System.Guid]::NewGuid().ToString('N')).conf"
        & scp $exportScript "${SshTarget}:/tmp/08-export-kubeconfig.sh"
        if ($LASTEXITCODE -ne 0) { throw 'scp export script failed' }
        & ssh $SshTarget "chmod +x /tmp/08-export-kubeconfig.sh && sudo CONTROL_PLANE_DNS=$cpDns /tmp/08-export-kubeconfig.sh $remoteTmp && rm -f /tmp/08-export-kubeconfig.sh"
        if ($LASTEXITCODE -ne 0) { throw 'remote export failed' }
        $kubeContent = (& ssh $SshTarget "sudo cat $remoteTmp")
        if ($LASTEXITCODE -ne 0) { throw 'fetch kubeconfig failed' }
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText("$dest.tmp", ($kubeContent -join "`n") + "`n", $utf8NoBom)
        & ssh $SshTarget "sudo rm -f $remoteTmp"
        Move-Item -Force "$dest.tmp" $dest
        Write-Host "Fetched kubeconfig to $dest"
        & $PSCommandPath -Action merge -KubeconfigPath $dest -ContextName $ContextName -ServerUrl $ServerUrl
    }
    'merge' {
        if (-not $KubeconfigPath) { throw 'Specify -KubeconfigPath to admin.conf copy' }
        if (-not (Test-Path $KubeconfigPath)) { throw "Kubeconfig not found: $KubeconfigPath" }
        if (-not (Test-Path $kubeDir)) { New-Item -ItemType Directory -Path $kubeDir | Out-Null }
        $backup = "$mainConfig.bak.$(Get-Date -Format yyyyMMddHHmmss)"
        if (Test-Path $mainConfig) { Copy-Item $mainConfig $backup -Force; Write-Host "Backup: $backup" }
        $env:KUBECONFIG = if (Test-Path $mainConfig) { "$mainConfig;$KubeconfigPath" } else { $KubeconfigPath }
        kubectl config view --flatten | Set-Content $mainConfig -Encoding utf8
        Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue
        $srcCtx = (kubectl config get-contexts -o name | Select-String 'kubernetes-admin' | Select-Object -First 1)
        if ($srcCtx) { $srcCtx = $srcCtx.ToString().Trim() }
        if (-not $srcCtx) {
            $srcCtx = (kubectl config get-contexts -o name | Where-Object { $_ -ne 'kind-dev' -and $_ -ne 'awx' } | Select-Object -First 1)
        }
        if ($srcCtx -and $srcCtx -ne $ContextName) {
            kubectl config rename-context $srcCtx $ContextName 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Context rename skipped (may already be $ContextName)"
            }
        }
        if ($ServerUrl) {
            $cluster = kubectl config view -o jsonpath="{.contexts[?(@.name==``"$ContextName``")].context.cluster}"
            kubectl config set-cluster $cluster --server=$ServerUrl
        }
        kubectl config use-context $ContextName
        Write-Host "Merged into $mainConfig; current context: $ContextName"
    }
    'tunnel' {
        if (-not $SshTarget) { throw 'Specify -SshTarget user@host' }
        Write-Host "Starting SSH tunnel: localhost:${LocalPort} -> ${RemoteHost}:${RemotePort} via $SshTarget"
        Write-Host 'Leave this window open. Use Ctrl+C to stop.'
        & ssh -N -L "${LocalPort}:${RemoteHost}:${RemotePort}" $SshTarget
    }
    'verify' {
        $useCtx = if ($Context) { $Context } else { $ContextName }
        Write-Section "nodes ($useCtx)"
        Invoke-Kubectl @('--context', $useCtx, 'get', 'nodes', '-o', 'wide')
        Write-Section 'GPU allocatable (nvidia.com/gpu, amd.com/gpu)'
        kubectl --context=$useCtx get nodes -o custom-columns=NAME:.metadata.name,NVIDIA_GPU:.status.allocatable.nvidia\.com/gpu,AMD_GPU:.status.allocatable.amd\.com/gpu
        Write-Section 'nvidia device plugin pods'
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        kubectl --context=$useCtx get pods -A -l app=nvidia-device-plugin-daemonset 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'No nvidia-device-plugin pods found (label may differ or addon not applied).'
        }
        Write-Section 'amdgpu device plugin pods'
        kubectl --context=$useCtx get pods -A -l name=amdgpu-dp-ds 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'No amdgpu-dp-ds pods found (label may differ or addon not applied).'
        }
        $ErrorActionPreference = $prevEap
    }
}
