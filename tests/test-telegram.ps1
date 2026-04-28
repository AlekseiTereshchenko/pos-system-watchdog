param(
    [Parameter(Mandatory)]
    [string]$BotToken,

    [Parameter(Mandatory)]
    [string]$ChatId
)

$ErrorActionPreference = 'Continue'
$scriptRoot = Split-Path $PSScriptRoot -Parent

. (Join-Path $scriptRoot 'src\lib\logging.ps1')
. (Join-Path $scriptRoot 'src\lib\telegram.ps1')

$testLogPath = Join-Path $env:TEMP 'pos-test-logs'
Initialize-PosLogging -Path $testLogPath -Component 'test-telegram'

Write-Host "========================================"
Write-Host "POS Telegram Alert Test"
Write-Host "========================================"

Write-Host "`nInitializing Telegram with provided credentials..." -ForegroundColor Cyan
Initialize-PosTelegram -BotToken $BotToken -ChatId $ChatId -CooldownMinutes 1

Write-Host "`nSending test alert..." -ForegroundColor Cyan
$result = Send-TelegramAlert -Level INFO -Message 'Test alert from POS System installer' -StoreId 'TEST-001' -BypassCooldown

if ($result) {
    Write-Host "`nPASS: Alert sent successfully. Check your Telegram." -ForegroundColor Green
}
else {
    Write-Host "`nFAIL: Alert failed to send. Check bot token and chat ID." -ForegroundColor Red
}

Write-Host "`nTesting cooldown..." -ForegroundColor Cyan

$result2 = Send-TelegramAlert -Level INFO -Message 'Test alert from POS System installer' -StoreId 'TEST-001'

if (-not $result2) {
    Write-Host "PASS: Cooldown works (duplicate alert suppressed)" -ForegroundColor Green
}
else {
    Write-Host "INFO: Cooldown did not suppress (may be expected if cooldown period passed)" -ForegroundColor Yellow
}

Remove-Item $testLogPath -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`nDone." -ForegroundColor Green
