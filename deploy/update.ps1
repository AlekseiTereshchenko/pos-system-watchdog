#Requires -RunAsAdministrator
param(
    [string]$InstallPath = 'C:\PosServices',
    [string]$SourcePath = (Split-Path $PSScriptRoot -Parent),
    [int]$HealthPort = 8095
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "`n>>> $Message" -ForegroundColor Cyan
}

$nssmPath = Join-Path $PSScriptRoot 'nssm.exe'
if (-not (Test-Path $nssmPath)) {
    $nssmSystem = Get-Command nssm -ErrorAction SilentlyContinue
    if ($nssmSystem) { $nssmPath = $nssmSystem.Source }
    else {
        Write-Host "ERROR: nssm.exe not found" -ForegroundColor Red
        exit 1
    }
}

# --- 1. Backup ---
Write-Step 'Creating backup'

$backupDir = "$InstallPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item -Path $InstallPath -Destination $backupDir -Recurse
Write-Host "Backup created: $backupDir" -ForegroundColor Green

# --- 2. Stop services ---
Write-Step 'Stopping services'

$serviceNames = @('PosWatchdog', 'PosScheduler', 'PosHealthMonitor')

foreach ($name in $serviceNames) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        & $nssmPath stop $name 2>$null
        Write-Host "$name stopped"
    }
}

Start-Sleep -Seconds 3

# --- 3. Update files (preserve config) ---
Write-Step 'Updating files'

$configBackup = Join-Path $InstallPath 'src\config\settings.json'
$savedConfig = $null
if (Test-Path $configBackup) {
    $savedConfig = Get-Content $configBackup -Raw
}

Copy-Item -Path (Join-Path $SourcePath 'src') -Destination $InstallPath -Recurse -Force

if ($savedConfig) {
    Set-Content -Path $configBackup -Value $savedConfig -Encoding UTF8
    Write-Host 'Config preserved' -ForegroundColor Green
}

# --- 4. Start services ---
Write-Step 'Starting services'

foreach ($name in $serviceNames) {
    Start-Service -Name $name -ErrorAction SilentlyContinue
    Write-Host "$name started" -ForegroundColor Green
}

# --- 5. Health check ---
Write-Step 'Verifying health'

Start-Sleep -Seconds 5

try {
    $health = Invoke-RestMethod -Uri "http://localhost:$HealthPort/health" -TimeoutSec 10
    Write-Host "Health: overall=$($health.overall)" -ForegroundColor Green
}
catch {
    Write-Host "WARNING: Health endpoint not responding. Rolling back..." -ForegroundColor Yellow

    foreach ($name in $serviceNames) {
        & $nssmPath stop $name 2>$null
    }
    Start-Sleep -Seconds 2

    Remove-Item -Path $InstallPath -Recurse -Force
    Copy-Item -Path $backupDir -Destination $InstallPath -Recurse

    foreach ($name in $serviceNames) {
        Start-Service -Name $name -ErrorAction SilentlyContinue
    }

    Write-Host "Rolled back to previous version from $backupDir" -ForegroundColor Red
    exit 1
}

Write-Host "`nUpdate complete. Backup: $backupDir" -ForegroundColor Green
