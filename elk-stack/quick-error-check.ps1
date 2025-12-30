# Quick Windows Error Check Script
# このスクリプトはWindowsのエラーログを素早く確認します

Write-Host "Windows エラーログ クイックチェック" -ForegroundColor Green
Write-Host "===================================" -ForegroundColor Green
Write-Host ""

# システム情報
Write-Host "システム情報:" -ForegroundColor Yellow
$ComputerInfo = Get-ComputerInfo -ErrorAction SilentlyContinue
if ($ComputerInfo) {
    Write-Host "  コンピューター名: $($ComputerInfo.CsName)" -ForegroundColor White
    Write-Host "  OS: $($ComputerInfo.WindowsProductName)" -ForegroundColor White
    Write-Host "  最終起動: $($ComputerInfo.OsLastBootUpTime)" -ForegroundColor White
} else {
    Write-Host "  コンピューター名: $env:COMPUTERNAME" -ForegroundColor White
    Write-Host "  ユーザー名: $env:USERNAME" -ForegroundColor White
}
Write-Host ""

# 最近のエラーログを確認
Write-Host "最近のエラーログ (過去24時間):" -ForegroundColor Yellow

# Application エラー
Write-Host "Application ログ:" -ForegroundColor Cyan
try {
    $AppErrors = Get-EventLog -LogName Application -EntryType Error -Newest 5 -ErrorAction SilentlyContinue
    if ($AppErrors) {
        foreach ($Error in $AppErrors) {
            Write-Host "  [$($Error.TimeGenerated)] $($Error.Source) (ID: $($Error.EventID))" -ForegroundColor Red
            Write-Host "    $($Error.Message.Substring(0, [Math]::Min(100, $Error.Message.Length)))..." -ForegroundColor Gray
        }
    } else {
        Write-Host "  エラーなし" -ForegroundColor Green
    }
} catch {
    Write-Host "  ログの取得に失敗" -ForegroundColor Red
}

Write-Host ""

# System エラー
Write-Host "System ログ:" -ForegroundColor Cyan
try {
    $SysErrors = Get-EventLog -LogName System -EntryType Error -Newest 5 -ErrorAction SilentlyContinue
    if ($SysErrors) {
        foreach ($Error in $SysErrors) {
            Write-Host "  [$($Error.TimeGenerated)] $($Error.Source) (ID: $($Error.EventID))" -ForegroundColor Red
            Write-Host "    $($Error.Message.Substring(0, [Math]::Min(100, $Error.Message.Length)))..." -ForegroundColor Gray
        }
    } else {
        Write-Host "  エラーなし" -ForegroundColor Green
    }
} catch {
    Write-Host "  ログの取得に失敗" -ForegroundColor Red
}

Write-Host ""

# システムの健康状態
Write-Host "システムの健康状態:" -ForegroundColor Yellow

# ディスク使用量
$Disks = Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }
foreach ($Disk in $Disks) {
    $FreeSpaceGB = [Math]::Round($Disk.FreeSpace / 1GB, 2)
    $TotalSpaceGB = [Math]::Round($Disk.Size / 1GB, 2)
    $UsagePercent = [Math]::Round((($Disk.Size - $Disk.FreeSpace) / $Disk.Size) * 100, 1)
    
    $Color = if ($UsagePercent -gt 90) { "Red" } elseif ($UsagePercent -gt 80) { "Yellow" } else { "Green" }
    Write-Host "  $($Disk.DeviceID) 使用率: $UsagePercent% ($FreeSpaceGB GB / $TotalSpaceGB GB)" -ForegroundColor $Color
}

# メモリ使用量
$Memory = Get-WmiObject -Class Win32_OperatingSystem
$TotalMemoryGB = [Math]::Round($Memory.TotalVisibleMemorySize / 1MB, 2)
$FreeMemoryGB = [Math]::Round($Memory.FreePhysicalMemory / 1MB, 2)
$MemoryUsagePercent = [Math]::Round((($Memory.TotalVisibleMemorySize - $Memory.FreePhysicalMemory) / $Memory.TotalVisibleMemorySize) * 100, 1)

$MemoryColor = if ($MemoryUsagePercent -gt 90) { "Red" } elseif ($MemoryUsagePercent -gt 80) { "Yellow" } else { "Green" }
Write-Host "  メモリ使用率: $MemoryUsagePercent% ($FreeMemoryGB GB / $TotalMemoryGB GB)" -ForegroundColor $MemoryColor

# CPU使用率
try {
    $CPU = Get-WmiObject -Class Win32_Processor | Measure-Object -Property LoadPercentage -Average
    $CPUUsage = [Math]::Round($CPU.Average, 1)
    $CPUColor = if ($CPUUsage -gt 90) { "Red" } elseif ($CPUUsage -gt 80) { "Yellow" } else { "Green" }
    Write-Host "  CPU使用率: $CPUUsage%" -ForegroundColor $CPUColor
} catch {
    Write-Host "  CPU使用率: 取得不可" -ForegroundColor Gray
}

Write-Host ""

# ネットワーク接続の確認
Write-Host "ネットワーク接続:" -ForegroundColor Yellow
try {
    $NetworkAdapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
    foreach ($Adapter in $NetworkAdapters) {
        Write-Host "  $($Adapter.Name): $($Adapter.Status)" -ForegroundColor Green
    }
} catch {
    Write-Host "  ネットワークアダプター情報の取得に失敗" -ForegroundColor Red
}

Write-Host ""

# 最近の警告も確認
Write-Host "最近の警告 (過去24時間):" -ForegroundColor Yellow
try {
    $Warnings = Get-EventLog -LogName Application -EntryType Warning -Newest 3 -ErrorAction SilentlyContinue
    if ($Warnings) {
        foreach ($Warning in $Warnings) {
            Write-Host "  [$($Warning.TimeGenerated)] $($Warning.Source) (ID: $($Warning.EventID))" -ForegroundColor Yellow
            Write-Host "    $($Warning.Message.Substring(0, [Math]::Min(80, $Warning.Message.Length)))..." -ForegroundColor Gray
        }
    } else {
        Write-Host "  警告なし" -ForegroundColor Green
    }
} catch {
    Write-Host "  警告の取得に失敗" -ForegroundColor Red
}

Write-Host ""
Write-Host "詳細なエラーログを確認する場合:" -ForegroundColor Yellow
Write-Host "  .\check-windows-errors.ps1 -Verbose" -ForegroundColor White
Write-Host ""
Write-Host "ELKスタックにエラーログを送信する場合:" -ForegroundColor Yellow
Write-Host "  .\check-windows-errors.ps1 -ElkStackHost localhost" -ForegroundColor White
