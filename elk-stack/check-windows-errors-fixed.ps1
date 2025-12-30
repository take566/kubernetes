# Windows Error Log Checker and ELK Stack Integration
# このスクリプトはWindowsのエラーログを確認し、ELKスタックに送信します

param(
    [Parameter(Mandatory=$false)]
    [string]$ElkStackHost = "localhost",
    
    [Parameter(Mandatory=$false)]
    [int]$ElkStackPort = 5044,
    
    [Parameter(Mandatory=$false)]
    [int]$DaysBack = 7,
    
    [Parameter(Mandatory=$false)]
    [switch]$ShowOnly,
    
    [Parameter(Mandatory=$false)]
    [switch]$Verbose
)

# Check if running as administrator
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "このスクリプトは管理者権限で実行することを推奨します。"
}

Write-Host "Windows Error Log Checker for ELK Stack" -ForegroundColor Green
Write-Host "=======================================" -ForegroundColor Green
Write-Host ""

# Function to get Windows event logs
function Get-WindowsEventLogs {
    param(
        [string]$LogName,
        [string]$EntryType,
        [int]$DaysBack,
        [int]$MaxEvents = 100
    )
    
    try {
        $StartTime = (Get-Date).AddDays(-$DaysBack)
        
        if ($LogName -eq "Application" -or $LogName -eq "System") {
            # Use Get-EventLog for classic logs
            $Events = Get-EventLog -LogName $LogName -EntryType $EntryType -After $StartTime -Newest $MaxEvents -ErrorAction SilentlyContinue
        } else {
            # Use Get-WinEvent for modern logs
            $FilterHashtable = @{
                LogName = $LogName
                Level = switch ($EntryType) {
                    "Error" { 2 }
                    "Warning" { 3 }
                    "Information" { 4 }
                    default { 0,1,2,3,4,5 }
                }
                StartTime = $StartTime
            }
            
            $Events = Get-WinEvent -FilterHashtable $FilterHashtable -MaxEvents $MaxEvents -ErrorAction SilentlyContinue
        }
        
        return $Events
    }
    catch {
        Write-Warning "ログ '$LogName' の取得に失敗しました: $($_.Exception.Message)"
        return @()
    }
}

# Function to convert event to JSON for ELK Stack
function Convert-EventToJson {
    param([object]$Event)
    
    $EventData = @{
        timestamp = $Event.TimeGenerated.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        log_level = switch ($Event.LevelDisplayName) {
            "Error" { "ERROR" }
            "Warning" { "WARN" }
            "Information" { "INFO" }
            "Critical" { "CRITICAL" }
            "Verbose" { "DEBUG" }
            default { $Event.LevelDisplayName }
        }
        event_id = $Event.EventID
        event_source = $Event.Source
        computer_name = $Event.MachineName
        message = $Event.Message
        log_name = $Event.Log
        category = $Event.Category
        keywords = $Event.KeywordsDisplayNames -join ", "
        process_id = $Event.ProcessId
        thread_id = $Event.ThreadId
        user_id = $Event.UserId
        host = @{
            name = $env:COMPUTERNAME
            os = @{
                name = (Get-WmiObject -Class Win32_OperatingSystem).Caption
                version = (Get-WmiObject -Class Win32_OperatingSystem).Version
            }
        }
        tags = @("windows", "eventlog", "error-check")
    }
    
    # Add additional fields for modern events
    if ($Event -is [System.Diagnostics.Eventing.Reader.EventLogRecord]) {
        $EventData.event_level = $Event.LevelDisplayName
        $EventData.task = $Event.TaskDisplayName
        $EventData.opcode = $Event.OpcodeDisplayName
        $EventData.channel = $Event.LogName
        
        # Parse event data
        if ($Event.Properties) {
            $Properties = @{}
            for ($i = 0; $i -lt $Event.Properties.Count; $i++) {
                $Properties["Property$i"] = $Event.Properties[$i].Value
            }
            $EventData.event_data = $Properties
        }
    }
    
    return $EventData | ConvertTo-Json -Depth 3
}

# Function to send data to ELK Stack via Logstash
function Send-ToElkStack {
    param(
        [string]$JsonData,
        [string]$Host,
        [int]$Port
    )
    
    try {
        $TcpClient = New-Object System.Net.Sockets.TcpClient
        $TcpClient.Connect($Host, $Port)
        $Stream = $TcpClient.GetStream()
        
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($JsonData + "`n")
        $Stream.Write($Bytes, 0, $Bytes.Length)
        
        $TcpClient.Close()
        return $true
    }
    catch {
        Write-Warning "ELKスタックへの送信に失敗しました: $($_.Exception.Message)"
        return $false
    }
}

# Main execution
try {
    Write-Host "過去 $DaysBack 日間のエラーログを確認しています..." -ForegroundColor Yellow
    Write-Host ""
    
    # Define logs to check
    $LogsToCheck = @(
        @{ Name = "Application"; Type = "Error" },
        @{ Name = "System"; Type = "Error" },
        @{ Name = "Security"; Type = "Error" },
        @{ Name = "Microsoft-Windows-Kernel-General/Operational"; Type = "Error" },
        @{ Name = "Microsoft-Windows-DNS-Client/Operational"; Type = "Error" },
        @{ Name = "Microsoft-Windows-WLAN-AutoConfig/Operational"; Type = "Error" }
    )
    
    $AllErrors = @()
    $TotalErrors = 0
    
    foreach ($LogConfig in $LogsToCheck) {
        Write-Host "ログ '$($LogConfig.Name)' を確認中..." -ForegroundColor Cyan
        
        $Events = Get-WindowsEventLogs -LogName $LogConfig.Name -EntryType $LogConfig.Type -DaysBack $DaysBack
        
        if ($Events.Count -gt 0) {
            Write-Host "  → $($Events.Count) 件のエラーが見つかりました" -ForegroundColor Red
            $TotalErrors += $Events.Count
            
            foreach ($Event in $Events) {
                $AllErrors += $Event
                
                if ($Verbose) {
                    Write-Host "    [$($Event.TimeGenerated)] $($Event.Source) - ID: $($Event.EventID)" -ForegroundColor Gray
                    Write-Host "    $($Event.Message.Substring(0, [Math]::Min(100, $Event.Message.Length)))..." -ForegroundColor Gray
                    Write-Host ""
                }
            }
        } else {
            Write-Host "  → エラーは見つかりませんでした" -ForegroundColor Green
        }
        Write-Host ""
    }
    
    # Summary
    Write-Host "=== エラーログサマリー ===" -ForegroundColor Yellow
    Write-Host "総エラー数: $TotalErrors" -ForegroundColor Red
    Write-Host "確認期間: 過去 $DaysBack 日間" -ForegroundColor Cyan
    Write-Host "確認日時: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host ""
    
    if ($TotalErrors -eq 0) {
        Write-Host "🎉 エラーは見つかりませんでした！" -ForegroundColor Green
    } else {
        # Show top error sources
        $TopErrors = $AllErrors | Group-Object Source | Sort-Object Count -Descending | Select-Object -First 5
        Write-Host "上位エラーソース:" -ForegroundColor Yellow
        foreach ($ErrorGroup in $TopErrors) {
            Write-Host "  $($ErrorGroup.Name): $($ErrorGroup.Count) 件" -ForegroundColor White
        }
        Write-Host ""
        
        # Show recent errors
        $RecentErrors = $AllErrors | Sort-Object TimeGenerated -Descending | Select-Object -First 3
        Write-Host "最近のエラー:" -ForegroundColor Yellow
        foreach ($Error in $RecentErrors) {
            Write-Host "  [$($Error.TimeGenerated)] $($Error.Source) - ID: $($Error.EventID)" -ForegroundColor White
            Write-Host "    $($Error.Message.Substring(0, [Math]::Min(150, $Error.Message.Length)))..." -ForegroundColor Gray
            Write-Host ""
        }
    }
    
    # Send to ELK Stack if not ShowOnly mode
    if (-not $ShowOnly -and $TotalErrors -gt 0) {
        Write-Host "ELKスタックにエラーデータを送信中..." -ForegroundColor Yellow
        
        $SuccessCount = 0
        foreach ($Event in $AllErrors) {
            $JsonData = Convert-EventToJson -Event $Event
            if (Send-ToElkStack -JsonData $JsonData -Host $ElkStackHost -Port $ElkStackPort) {
                $SuccessCount++
            }
        }
        
        Write-Host "ELKスタックへの送信完了: $SuccessCount/$TotalErrors 件" -ForegroundColor Green
        Write-Host ""
        Write-Host "Kibanaで確認する場合:" -ForegroundColor Yellow
        Write-Host "1. http://$ElkStackHost`:5601 にアクセス" -ForegroundColor White
        Write-Host "2. インデックスパターン 'logstash-*' を作成" -ForegroundColor White
        Write-Host "3. Discoverで 'tags: error-check' でフィルター" -ForegroundColor White
    }
    
    Write-Host ""
    Write-Host "=== システム情報 ===" -ForegroundColor Yellow
    $ComputerInfo = Get-ComputerInfo
    Write-Host "コンピューター名: $($ComputerInfo.CsName)" -ForegroundColor White
    Write-Host "OS: $($ComputerInfo.WindowsProductName)" -ForegroundColor White
    Write-Host "OSバージョン: $($ComputerInfo.WindowsVersion)" -ForegroundColor White
    Write-Host "最終起動時刻: $($ComputerInfo.OsLastBootUpTime)" -ForegroundColor White
    Write-Host "稼働時間: $([Math]::Round($(Get-Uptime).TotalDays, 1)) 日" -ForegroundColor White
}
catch {
    Write-Error "スクリプト実行中にエラーが発生しました: $($_.Exception.Message)"
    exit 1
}
