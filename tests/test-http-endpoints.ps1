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
Test-Endpoint -Name 'ПодготовкаДанныхKafka' -Endpoint '/sched/kafka-prepare'
Test-Endpoint -Name 'ВыгрузкаДанныхKafka' -Endpoint '/sched/kafka-export'
Test-Endpoint -Name 'АктуализацияДанныхЗаказовKafka' -Endpoint '/sched/orders-kafka-sync'
Test-Endpoint -Name 'ЗагрузкаЗаказовНаСамовывоз' -Endpoint '/sched/pickup-orders'
Test-Endpoint -Name 'АктуализацияОстатков' -Endpoint '/sched/stock-update'
Test-Endpoint -Name 'ЗагрузкаЦенНоменклатуры' -Endpoint '/sched/price-update'
Test-Endpoint -Name 'РасчетПопулярностиТоваров' -Endpoint '/sched/popularity-calc'
Test-Endpoint -Name 'ЗагрузкаШтрихкодовНоменклатуры' -Endpoint '/sched/barcodes-update'
Test-Endpoint -Name 'ЗаполнениеПризнакаУчетаСерий' -Endpoint '/sched/series-flag'
Test-Endpoint -Name 'АктуализацияБанковскихСчетов' -Endpoint '/sched/bank-accounts'
Test-Endpoint -Name 'ЗагрузкаДанныхСкладов' -Endpoint '/sched/warehouses-update'
Test-Endpoint -Name 'СведенияНоменклатуры' -Endpoint '/sched/nomenclature-info'
Test-Endpoint -Name 'ЗагрузкаДанныхТорговыхТочек' -Endpoint '/sched/stores-update'
Test-Endpoint -Name 'ЗагрузкаДанныхТранспортныхКомпаний' -Endpoint '/sched/transport-update'
Test-Endpoint -Name 'АктуализацияМаркАкций' -Endpoint '/sched/promo-marks'
Test-Endpoint -Name 'АктуализацияСтатусовЗаказов' -Endpoint '/sched/order-statuses'
Test-Endpoint -Name 'ЗагрузкаСведенийОСотрудниках' -Endpoint '/sched/employees-update'

Write-Host "`n========================================"
Write-Host "Results: $passed passed, $failed failed" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
Write-Host "========================================"

exit $failed
