# Windows Event Log Collection Setup Script for ELK Stack
# This script configures Winlogbeat to send Windows event logs to ELK Stack

param(
    [Parameter(Mandatory=$true)]
    [string]$ElkStackHost,
    
    [Parameter(Mandatory=$false)]
    [int]$ElkStackPort = 5044,
    
    [Parameter(Mandatory=$false)]
    [string]$WinlogbeatVersion = "8.11.0",
    
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

# Check if running as administrator
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "このスクリプトは管理者権限で実行する必要があります。"
    exit 1
}

Write-Host "Windows Event Log Collection Setup for ELK Stack" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green

# Set variables
$WinlogbeatDir = "C:\ProgramData\winlogbeat"
$WinlogbeatConfigFile = "$WinlogbeatDir\winlogbeat.yml"
$WinlogbeatLogFile = "$WinlogbeatDir\logs\winlogbeat.log"
$DownloadUrl = "https://artifacts.elastic.co/downloads/beats/winlogbeat/winlogbeat-$WinlogbeatVersion-windows-x86_64.zip"

# Function to download and extract Winlogbeat
function Install-Winlogbeat {
    Write-Host "Winlogbeatをインストールしています..." -ForegroundColor Yellow
    
    # Create temporary directory
    $TempDir = "$env:TEMP\winlogbeat-install"
    if (Test-Path $TempDir) {
        Remove-Item $TempDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $TempDir | Out-Null
    
    try {
        # Download Winlogbeat
        Write-Host "Winlogbeat $WinlogbeatVersion をダウンロードしています..." -ForegroundColor Yellow
        $ZipFile = "$TempDir\winlogbeat.zip"
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipFile -UseBasicParsing
        
        # Extract Winlogbeat
        Write-Host "Winlogbeatを展開しています..." -ForegroundColor Yellow
        Expand-Archive -Path $ZipFile -DestinationPath $TempDir -Force
        
        # Copy files to ProgramData
        $ExtractedDir = Get-ChildItem $TempDir -Directory | Where-Object { $_.Name -like "winlogbeat-*" } | Select-Object -First 1
        if (-not $ExtractedDir) {
            throw "展開されたディレクトリが見つかりません"
        }
        
        if (Test-Path $WinlogbeatDir) {
            Remove-Item $WinlogbeatDir -Recurse -Force
        }
        Copy-Item $ExtractedDir.FullName $WinlogbeatDir -Recurse -Force
        
        Write-Host "Winlogbeatが正常にインストールされました" -ForegroundColor Green
    }
    catch {
        Write-Error "Winlogbeatのインストールに失敗しました: $($_.Exception.Message)"
        exit 1
    }
    finally {
        # Clean up temporary directory
        if (Test-Path $TempDir) {
            Remove-Item $TempDir -Recurse -Force
        }
    }
}

# Function to create Winlogbeat configuration
function Set-WinlogbeatConfig {
    Write-Host "Winlogbeat設定を作成しています..." -ForegroundColor Yellow
    
    $ConfigContent = @"
winlogbeat.event_logs:
  - name: Application
    ignore_older: 24h
    level: info
    
  - name: System
    ignore_older: 24h
    level: info
    
  - name: Security
    ignore_older: 24h
    level: info
    
  - name: Microsoft-Windows-Sysmon/Operational
    ignore_older: 24h
    level: info
    
  - name: Microsoft-Windows-PowerShell/Operational
    ignore_older: 24h
    level: info
    
  - name: Microsoft-Windows-Windows Defender/Operational
    ignore_older: 24h
    level: info
    
  - name: Microsoft-Windows-TaskScheduler/Operational
    ignore_older: 24h
    level: info
    
  - name: Microsoft-Windows-DNS-Client/Operational
    ignore_older: 24h
    level: info
    
  - name: Microsoft-Windows-NetworkProfile/Operational
    ignore_older: 24h
    level: info
    
  - name: Microsoft-Windows-WLAN-AutoConfig/Operational
    ignore_older: 24h
    level: info
    
  - name: Microsoft-Windows-TerminalServices-LocalSessionManager/Operational
    ignore_older: 24h
    level: info
    
  - name: Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational
    ignore_older: 24h
    level: info

output.logstash:
  hosts: ["$ElkStackHost`:$ElkStackPort"]
  
setup.kibana:
  host: "$ElkStackHost`:5601"
  
setup.template.settings:
  index.number_of_shards: 1
  index.number_of_replicas: 0
  index.refresh_interval: 5s
  
setup.template.name: "winlogbeat"
setup.template.pattern: "winlogbeat-*"

# Processors for data enrichment
processors:
  - add_host_metadata:
      when.not.contains.tags: forwarded
      
  - add_cloud_metadata: ~
  
  - add_docker_metadata: ~
  
  - add_kubernetes_metadata: ~

# Logging configuration
logging.level: info
logging.to_files: true
logging.files:
  path: C:\ProgramData\winlogbeat\logs
  name: winlogbeat
  keepfiles: 7
  permissions: 0644
  
# Monitoring
monitoring.enabled: false

# HTTP endpoint for stats
http.enabled: true
http.host: localhost
http.port: 5066
"@

    try {
        $ConfigContent | Out-File -FilePath $WinlogbeatConfigFile -Encoding UTF8 -Force
        Write-Host "Winlogbeat設定ファイルが作成されました: $WinlogbeatConfigFile" -ForegroundColor Green
    }
    catch {
        Write-Error "設定ファイルの作成に失敗しました: $($_.Exception.Message)"
        exit 1
    }
}

# Function to install Winlogbeat as Windows service
function Install-WinlogbeatService {
    Write-Host "Winlogbeatサービスをインストールしています..." -ForegroundColor Yellow
    
    try {
        # Change to Winlogbeat directory
        Push-Location $WinlogbeatDir
        
        # Install service
        & ".\winlogbeat.exe" install service -c $WinlogbeatConfigFile
        
        Write-Host "Winlogbeatサービスがインストールされました" -ForegroundColor Green
    }
    catch {
        Write-Error "Winlogbeatサービスのインストールに失敗しました: $($_.Exception.Message)"
        exit 1
    }
    finally {
        Pop-Location
    }
}

# Function to setup Elasticsearch template
function Set-ElasticsearchTemplate {
    Write-Host "Elasticsearchテンプレートを設定しています..." -ForegroundColor Yellow
    
    try {
        # Change to Winlogbeat directory
        Push-Location $WinlogbeatDir
        
        # Setup template
        & ".\winlogbeat.exe" setup --template -c $WinlogbeatConfigFile -E output.logstash.enabled=false -E output.elasticsearch.hosts=["$ElkStackHost`:9200"]
        
        Write-Host "Elasticsearchテンプレートが設定されました" -ForegroundColor Green
    }
    catch {
        Write-Warning "Elasticsearchテンプレートの設定に失敗しました（ELKスタックが起動していない可能性があります）: $($_.Exception.Message)"
    }
    finally {
        Pop-Location
    }
}

# Function to start Winlogbeat service
function Start-WinlogbeatService {
    Write-Host "Winlogbeatサービスを開始しています..." -ForegroundColor Yellow
    
    try {
        Start-Service winlogbeat
        Write-Host "Winlogbeatサービスが開始されました" -ForegroundColor Green
        
        # Wait a moment and check status
        Start-Sleep -Seconds 3
        $ServiceStatus = Get-Service winlogbeat
        Write-Host "サービス状態: $($ServiceStatus.Status)" -ForegroundColor Cyan
    }
    catch {
        Write-Error "Winlogbeatサービスの開始に失敗しました: $($_.Exception.Message)"
        exit 1
    }
}

# Function to configure Windows Firewall
function Set-WindowsFirewall {
    Write-Host "Windowsファイアウォールを設定しています..." -ForegroundColor Yellow
    
    try {
        # Allow Winlogbeat outbound connections
        New-NetFirewallRule -DisplayName "Winlogbeat Outbound" -Direction Outbound -Protocol TCP -RemotePort $ElkStackPort -Action Allow -ErrorAction SilentlyContinue
        
        Write-Host "Windowsファイアウォールが設定されました" -ForegroundColor Green
    }
    catch {
        Write-Warning "Windowsファイアウォールの設定に失敗しました: $($_.Exception.Message)"
    }
}

# Main execution
try {
    Write-Host "ELK Stack Host: $ElkStackHost" -ForegroundColor Cyan
    Write-Host "ELK Stack Port: $ElkStackPort" -ForegroundColor Cyan
    Write-Host "Winlogbeat Version: $WinlogbeatVersion" -ForegroundColor Cyan
    Write-Host ""
    
    # Check if Winlogbeat is already installed
    if ((Test-Path $WinlogbeatDir) -and -not $Force) {
        $Response = Read-Host "Winlogbeatは既にインストールされています。再インストールしますか？ (y/N)"
        if ($Response -ne "y" -and $Response -ne "Y") {
            Write-Host "インストールをキャンセルしました" -ForegroundColor Yellow
            exit 0
        }
    }
    
    # Check if Winlogbeat service is running
    $WinlogbeatService = Get-Service winlogbeat -ErrorAction SilentlyContinue
    if ($WinlogbeatService -and $WinlogbeatService.Status -eq "Running") {
        Write-Host "Winlogbeatサービスを停止しています..." -ForegroundColor Yellow
        Stop-Service winlogbeat -Force
    }
    
    # Install Winlogbeat
    Install-Winlogbeat
    
    # Create configuration
    Set-WinlogbeatConfig
    
    # Install service
    Install-WinlogbeatService
    
    # Setup Elasticsearch template
    Set-ElasticsearchTemplate
    
    # Configure firewall
    Set-WindowsFirewall
    
    # Start service
    Start-WinlogbeatService
    
    Write-Host ""
    Write-Host "Windows Event Log Collection Setup が完了しました！" -ForegroundColor Green
    Write-Host "=================================================" -ForegroundColor Green
    Write-Host "設定ファイル: $WinlogbeatConfigFile" -ForegroundColor Cyan
    Write-Host "ログファイル: $WinlogbeatLogFile" -ForegroundColor Cyan
    Write-Host "サービス名: winlogbeat" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "次の手順:" -ForegroundColor Yellow
    Write-Host "1. ELKスタックが起動していることを確認" -ForegroundColor White
    Write-Host "2. Kibanaでインデックスパターン 'winlogbeat-*' を作成" -ForegroundColor White
    Write-Host "3. Windows Events Overview ダッシュボードをインポート" -ForegroundColor White
    Write-Host ""
    Write-Host "サービス管理コマンド:" -ForegroundColor Yellow
    Write-Host "  開始: Start-Service winlogbeat" -ForegroundColor White
    Write-Host "  停止: Stop-Service winlogbeat" -ForegroundColor White
    Write-Host "  状態: Get-Service winlogbeat" -ForegroundColor White
    Write-Host "  ログ: Get-Content $WinlogbeatLogFile -Tail 50" -ForegroundColor White
}
catch {
    Write-Error "セットアップ中にエラーが発生しました: $($_.Exception.Message)"
    exit 1
}
