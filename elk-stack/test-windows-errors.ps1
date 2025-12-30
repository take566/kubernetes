# Windows Error Log Checker and ELK Stack Integration
# This script checks Windows error logs and sends them to ELK Stack

param(
    [Parameter(Mandatory=$false)]
    [string]$ElkStackHost = "localhost",
    
    [Parameter(Mandatory=$false)]
    [int]$ElkStackPort = 5000,
    
    [Parameter(Mandatory=$false)]
    [int]$DaysBack = 7,
    
    [Parameter(Mandatory=$false)]
    [switch]$ShowOnly,
    
    [Parameter(Mandatory=$false)]
    [switch]$ShowVerbose
)

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
        Write-Warning "Failed to get log '$LogName': $($_.Exception.Message)"
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
    
    return $EventData | ConvertTo-Json -Depth 3
}

# Function to send data to ELK Stack via Logstash
function Send-ToElkStack {
    param(
        [string]$JsonData,
        [string]$ElkHost,
        [int]$Port
    )
    
    try {
        $TcpClient = New-Object System.Net.Sockets.TcpClient
        $TcpClient.Connect($ElkHost, $Port)
        $Stream = $TcpClient.GetStream()
        
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($JsonData + "`n")
        $Stream.Write($Bytes, 0, $Bytes.Length)
        
        $TcpClient.Close()
        return $true
    }
    catch {
        Write-Warning "Failed to send to ELK Stack: $($_.Exception.Message)"
        return $false
    }
}

# Main execution
try {
    Write-Host "Checking error logs for the past $DaysBack days..." -ForegroundColor Yellow
    Write-Host ""
    
    # Define logs to check
    $LogsToCheck = @(
        @{ Name = "Application"; Type = "Error" },
        @{ Name = "System"; Type = "Error" },
        @{ Name = "Security"; Type = "Error" }
    )
    
    $AllErrors = @()
    $TotalErrors = 0
    
    foreach ($LogConfig in $LogsToCheck) {
        Write-Host "Checking log '$($LogConfig.Name)'..." -ForegroundColor Cyan
        
        $Events = Get-WindowsEventLogs -LogName $LogConfig.Name -EntryType $LogConfig.Type -DaysBack $DaysBack
        
        if ($Events.Count -gt 0) {
            Write-Host "  -> Found $($Events.Count) errors" -ForegroundColor Red
            $TotalErrors += $Events.Count
            
            foreach ($Event in $Events) {
                $AllErrors += $Event
                
                if ($ShowVerbose) {
                    Write-Host "    [$($Event.TimeGenerated)] $($Event.Source) - ID: $($Event.EventID)" -ForegroundColor Gray
                    Write-Host "    $($Event.Message.Substring(0, [Math]::Min(100, $Event.Message.Length)))..." -ForegroundColor Gray
                    Write-Host ""
                }
            }
        } else {
            Write-Host "  -> No errors found" -ForegroundColor Green
        }
        Write-Host ""
    }
    
    # Summary
    Write-Host "=== Error Log Summary ===" -ForegroundColor Yellow
    Write-Host "Total Errors: $TotalErrors" -ForegroundColor Red
    Write-Host "Check Period: Past $DaysBack days" -ForegroundColor Cyan
    Write-Host "Check Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host ""
    
    if ($TotalErrors -eq 0) {
        Write-Host "No errors found!" -ForegroundColor Green
    } else {
        # Show top error sources
        $TopErrors = $AllErrors | Group-Object Source | Sort-Object Count -Descending | Select-Object -First 5
        Write-Host "Top Error Sources:" -ForegroundColor Yellow
        foreach ($ErrorGroup in $TopErrors) {
            Write-Host "  $($ErrorGroup.Name): $($ErrorGroup.Count) events" -ForegroundColor White
        }
        Write-Host ""
    }
    
    # Send to ELK Stack if not ShowOnly mode
    if (-not $ShowOnly -and $TotalErrors -gt 0) {
        Write-Host "Sending error data to ELK Stack..." -ForegroundColor Yellow
        
        $SuccessCount = 0
        foreach ($Event in $AllErrors) {
            $JsonData = Convert-EventToJson -Event $Event
            if (Send-ToElkStack -JsonData $JsonData -ElkHost $ElkStackHost -Port $ElkStackPort) {
                $SuccessCount++
            }
        }
        
        Write-Host "ELK Stack transmission completed: $SuccessCount/$TotalErrors events" -ForegroundColor Green
        Write-Host ""
        Write-Host "To check in Kibana:" -ForegroundColor Yellow
        Write-Host "1. Access http://$ElkStackHost:5601" -ForegroundColor White
        Write-Host "2. Create index pattern 'logstash-*'" -ForegroundColor White
        Write-Host "3. Filter by 'tags: error-check'" -ForegroundColor White
    }
    
    Write-Host ""
    Write-Host "=== System Information ===" -ForegroundColor Yellow
    $ComputerInfo = Get-ComputerInfo
    Write-Host "Computer Name: $($ComputerInfo.CsName)" -ForegroundColor White
    Write-Host "OS: $($ComputerInfo.WindowsProductName)" -ForegroundColor White
    Write-Host "OS Version: $($ComputerInfo.WindowsVersion)" -ForegroundColor White
    Write-Host "Last Boot Time: $($ComputerInfo.OsLastBootUpTime)" -ForegroundColor White
    Write-Host "Uptime: $([Math]::Round($(Get-Uptime).TotalDays, 1)) days" -ForegroundColor White
}
catch {
    Write-Error "Error occurred during script execution: $($_.Exception.Message)"
    exit 1
}
