#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory)]
    [string]$StoreId,

    [string]$InstallPath = 'C:\PosServices',
    [string]$SourcePath = (Split-Path $PSScriptRoot -Parent),

    [string]$OneCExePath,
    [string]$OneCBasePath,
    [string]$OneCUser = 'КассирАвто',
    [string]$OneCPassword = '',
    [string]$HttpBaseUrl = 'http://localhost/retail/hs',

    [string]$TelegramBotToken = '',
    [string]$TelegramChatId = '',

    [int]$HealthPort = 8095
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "`n>>> $Message" -ForegroundColor Cyan
}

# --- 1. Copy files ---
Write-Step "Copying files to $InstallPath"

if (Test-Path $InstallPath) {
    Write-Host "Directory exists, backing up config..."
    $backupDir = "$InstallPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -Path (Join-Path $InstallPath 'src\config\settings.json') -Destination "$backupDir-settings.json" -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null

Copy-Item -Path (Join-Path $SourcePath 'src') -Destination $InstallPath -Recurse -Force

# --- 2. Configure settings.json ---
Write-Step "Configuring settings.json for store $StoreId"

$configPath = Join-Path $InstallPath 'src\config\settings.json'
$config = Get-Content $configPath -Raw | ConvertFrom-Json

$config.storeId = $StoreId

if ($OneCExePath) { $config.oneC.exePath = $OneCExePath }
if ($OneCBasePath) { $config.oneC.basePath = $OneCBasePath }
$config.oneC.clientUser = $OneCUser
$config.oneC.clientPassword = $OneCPassword
$config.oneC.httpBaseUrl = $HttpBaseUrl

$config.telegram.botToken = $TelegramBotToken
$config.telegram.chatId = $TelegramChatId
$config.health.port = $HealthPort

$config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8

# --- 3. Create log directory ---
Write-Step "Creating log directory: $($config.logging.path)"
New-Item -ItemType Directory -Path $config.logging.path -Force | Out-Null

# --- 4. Check NSSM ---
Write-Step 'Checking NSSM'

$nssmPath = Join-Path $PSScriptRoot 'nssm.exe'
if (-not (Test-Path $nssmPath)) {
    $nssmSystem = Get-Command nssm -ErrorAction SilentlyContinue
    if ($nssmSystem) {
        $nssmPath = $nssmSystem.Source
    }
    else {
        Write-Host "ERROR: nssm.exe not found in $PSScriptRoot and not in PATH." -ForegroundColor Red
        Write-Host "Download NSSM from https://nssm.cc/download and place nssm.exe in deploy/"
        exit 1
    }
}

# --- 5. Register services ---
Write-Step 'Registering Windows services via NSSM'

$psExe = (Get-Command powershell.exe).Source
$srcPath = Join-Path $InstallPath 'src'

$services = @(
    @{
        Name   = 'PosWatchdog'
        Script = 'pos-watchdog.ps1'
        Desc   = 'POS System - 1C Client Watchdog'
    },
    @{
        Name   = 'PosScheduler'
        Script = 'pos-scheduler.ps1'
        Desc   = 'POS System - HTTP Task Scheduler'
    },
    @{
        Name   = 'PosHealthMonitor'
        Script = 'pos-health.ps1'
        Desc   = 'POS System - Health Monitor Endpoint'
    }
)

foreach ($svc in $services) {
    $existingSvc = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
    if ($existingSvc) {
        Write-Host "Service $($svc.Name) already exists, removing..."
        & $nssmPath stop $svc.Name 2>$null
        & $nssmPath remove $svc.Name confirm 2>$null
        Start-Sleep -Seconds 2
    }

    $scriptPath = Join-Path $srcPath $svc.Script

    & $nssmPath install $svc.Name $psExe "-ExecutionPolicy Bypass -NoProfile -File `"$scriptPath`""
    & $nssmPath set $svc.Name DisplayName $svc.Desc
    & $nssmPath set $svc.Name Description $svc.Desc
    & $nssmPath set $svc.Name Start SERVICE_AUTO_START
    & $nssmPath set $svc.Name AppStdout (Join-Path $config.logging.path "$($svc.Name)-stdout.log")
    & $nssmPath set $svc.Name AppStderr (Join-Path $config.logging.path "$($svc.Name)-stderr.log")
    & $nssmPath set $svc.Name AppRotateFiles 1
    & $nssmPath set $svc.Name AppRotateBytes 10485760

    Write-Host "Service $($svc.Name) registered" -ForegroundColor Green
}

# --- 6. Firewall rule ---
Write-Step "Opening port $HealthPort in Windows Firewall"

$ruleName = "POS Health Monitor (Port $HealthPort)"
$existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

if (-not $existingRule) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $HealthPort -Action Allow | Out-Null
    Write-Host "Firewall rule created" -ForegroundColor Green
}
else {
    Write-Host "Firewall rule already exists"
}

# --- 7. Start services ---
Write-Step 'Starting services'

foreach ($svc in $services) {
    Start-Service -Name $svc.Name
    Write-Host "Service $($svc.Name) started" -ForegroundColor Green
}

# --- 8. Health check ---
Write-Step 'Verifying health endpoint'

$maxWait = 30
$elapsed = 0
$healthOk = $false

while ($elapsed -lt $maxWait) {
    Start-Sleep -Seconds 3
    $elapsed += 3

    try {
        $health = Invoke-RestMethod -Uri "http://localhost:$HealthPort/health" -TimeoutSec 5
        Write-Host "Health response: overall=$($health.overall)" -ForegroundColor Green
        $healthOk = $true
        break
    }
    catch {
        Write-Host "Waiting for health endpoint... (${elapsed}s)"
    }
}

if (-not $healthOk) {
    Write-Host "`nWARNING: Health endpoint did not respond within ${maxWait}s. Check logs at $($config.logging.path)" -ForegroundColor Yellow
}

# --- Done ---
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "Installation complete for store $StoreId" -ForegroundColor Green
Write-Host "Services: PosWatchdog, PosScheduler, PosHealthMonitor" -ForegroundColor Green
Write-Host "Health:   http://localhost:$HealthPort/health" -ForegroundColor Green
Write-Host "Logs:     $($config.logging.path)" -ForegroundColor Green
Write-Host "Config:   $configPath" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
