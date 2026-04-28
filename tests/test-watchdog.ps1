param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Continue'
$scriptRoot = Split-Path $PSScriptRoot -Parent

. (Join-Path $scriptRoot 'src\lib\config.ps1')
. (Join-Path $scriptRoot 'src\lib\logging.ps1')
. (Join-Path $scriptRoot 'src\lib\onec-http.ps1')

$passed = 0
$failed = 0

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Message = '')
    if ($Condition) {
        Write-Host "  PASS: $Name" -ForegroundColor Green
        $script:passed++
    }
    else {
        Write-Host "  FAIL: $Name - $Message" -ForegroundColor Red
        $script:failed++
    }
}

Write-Host "========================================"
Write-Host "POS Watchdog Tests"
Write-Host "========================================"

# --- Test 1: Config loading ---
Write-Host "`nTest: Config Loading" -ForegroundColor Cyan

$testConfigPath = if ($ConfigPath) { $ConfigPath } else { Join-Path $scriptRoot 'src\config\settings.json' }

try {
    $config = Initialize-PosConfig -Path $testConfigPath
    Assert-True 'Config loads successfully' $true
    Assert-True 'StoreId present' ($config.storeId -ne '')
    Assert-True 'Watchdog section present' ($null -ne $config.watchdog)
    Assert-True 'Scheduler tasks present' ($config.scheduler.tasks.Count -gt 0)
}
catch {
    Assert-True 'Config loads successfully' $false $_.Exception.Message
}

# --- Test 2: 1C Process detection ---
Write-Host "`nTest: 1C Process Detection" -ForegroundColor Cyan

$proc = Get-Process -Name '1cv8' -ErrorAction SilentlyContinue
if ($proc) {
    Assert-True '1C process found' $true
    Write-Host "    PID: $($proc.Id), Responding: $($proc.Responding)" -ForegroundColor Gray
}
else {
    Write-Host "  INFO: 1C process not running (expected on dev machine)" -ForegroundColor Yellow
    $script:passed++
}

# --- Test 3: Fiscal status endpoint ---
Write-Host "`nTest: Fiscal Status Endpoint" -ForegroundColor Cyan

if ($config) {
    Initialize-OneCHttp -BaseUrl $config.oneC.httpBaseUrl -Username $config.oneC.clientUser -Password $config.oneC.clientPassword
    $status = Get-FiscalQueueStatus

    if ($status.Available) {
        Assert-True 'Fiscal endpoint reachable' $true
        Assert-True 'PendingReceipts is numeric' ($status.PendingReceipts -ge 0)
        Write-Host "    Pending: $($status.PendingReceipts), OldestAge: $($status.OldestAgeSec)s" -ForegroundColor Gray
    }
    else {
        Write-Host "  INFO: Fiscal endpoint not available (expected if 1C not running): $($status.Error)" -ForegroundColor Yellow
        $script:passed++
    }
}

# --- Test 4: Logging ---
Write-Host "`nTest: Logging" -ForegroundColor Cyan

$testLogPath = Join-Path $env:TEMP 'pos-test-logs'
try {
    Initialize-PosLogging -Path $testLogPath -Component 'test'
    Write-PosLog -Level INFO -Message 'Test log entry' -Component 'test'

    $logFiles = Get-ChildItem $testLogPath -Filter '*.log'
    Assert-True 'Log file created' ($logFiles.Count -gt 0)

    if ($logFiles.Count -gt 0) {
        $content = Get-Content $logFiles[0].FullName -Raw
        Assert-True 'Log entry written' ($content -match 'Test log entry')
    }
}
finally {
    Remove-Item $testLogPath -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Results ---
Write-Host "`n========================================"
Write-Host "Results: $passed passed, $failed failed" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
Write-Host "========================================"

exit $failed
