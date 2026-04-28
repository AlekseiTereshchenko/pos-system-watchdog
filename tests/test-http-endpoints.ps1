param(
    [string]$BaseUrl = 'http://localhost/retail/hs'
)

$ErrorActionPreference = 'Continue'
$passed = 0
$failed = 0

function Test-Endpoint {
    param(
        [string]$Name,
        [string]$Endpoint,
        [string]$Method = 'POST',
        [int]$TimeoutSec = 30
    )

    $uri = "$BaseUrl$Endpoint"
    Write-Host "`nTesting: $Name ($Method $uri)" -ForegroundColor Cyan

    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-RestMethod -Uri $uri -Method $Method -TimeoutSec $TimeoutSec -ContentType 'application/json'
        $sw.Stop()

        Write-Host "  PASS - Response received in $([math]::Round($sw.Elapsed.TotalSeconds, 2))s" -ForegroundColor Green
        Write-Host "  Response: $($response | ConvertTo-Json -Compress -Depth 3)" -ForegroundColor Gray
        $script:passed++
        return $true
    }
    catch {
        $sw.Stop()
        Write-Host "  FAIL - $($_.Exception.Message)" -ForegroundColor Red
        $script:failed++
        return $false
    }
}

Write-Host "========================================"
Write-Host "POS HTTP Endpoints Test"
Write-Host "Base URL: $BaseUrl"
Write-Host "========================================"

Test-Endpoint -Name 'Fiscal Status' -Endpoint '/sched/fiscal-status' -Method 'GET'
Test-Endpoint -Name 'Kafka Export' -Endpoint '/sched/kafka-export'
Test-Endpoint -Name 'Orders Sync' -Endpoint '/sched/orders-sync'
Test-Endpoint -Name 'Price Update' -Endpoint '/sched/price-update'
Test-Endpoint -Name 'Stock Update' -Endpoint '/sched/stock-update'
Test-Endpoint -Name 'NSI Sync' -Endpoint '/sched/nsi-sync'

Write-Host "`n========================================"
Write-Host "Results: $passed passed, $failed failed" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
Write-Host "========================================"

exit $failed
