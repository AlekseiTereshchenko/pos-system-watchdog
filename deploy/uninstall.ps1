#Requires -RunAsAdministrator
param(
    [string]$InstallPath = 'C:\PosServices',
    [switch]$RemoveFiles,
    [switch]$RemoveLogs
)

$ErrorActionPreference = 'Continue'

function Write-Step {
    param([string]$Message)
    Write-Host "`n>>> $Message" -ForegroundColor Cyan
}

$nssmPath = Join-Path $PSScriptRoot 'nssm.exe'
if (-not (Test-Path $nssmPath)) {
    $nssmSystem = Get-Command nssm -ErrorAction SilentlyContinue
    if ($nssmSystem) { $nssmPath = $nssmSystem.Source }
    else {
        Write-Host "WARNING: nssm.exe not found, will use sc.exe" -ForegroundColor Yellow
        $nssmPath = $null
    }
}

# --- 1. Stop and remove services ---
Write-Step 'Stopping and removing services'

$serviceNames = @('PosWatchdog', 'PosScheduler', 'PosHealthMonitor')

foreach ($name in $serviceNames) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Host "Service $name not found, skipping"
        continue
    }

    Write-Host "Stopping $name..."
    if ($nssmPath) {
        & $nssmPath stop $name 2>$null
        Start-Sleep -Seconds 2
        & $nssmPath remove $name confirm 2>$null
    }
    else {
        Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        sc.exe delete $name 2>$null
    }
    Write-Host "Service $name removed" -ForegroundColor Green
}

# --- 2. Remove firewall rule ---
Write-Step 'Removing firewall rule'

Get-NetFirewallRule -DisplayName 'POS Health Monitor*' -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

Write-Host 'Firewall rules removed' -ForegroundColor Green

# --- 3. Remove files ---
if ($RemoveFiles) {
    Write-Step "Removing installation files: $InstallPath"
    if (Test-Path $InstallPath) {
        Remove-Item -Path $InstallPath -Recurse -Force
        Write-Host 'Files removed' -ForegroundColor Green
    }
}
else {
    Write-Host "`nFiles preserved at $InstallPath (use -RemoveFiles to delete)"
}

if ($RemoveLogs) {
    Write-Step 'Removing logs'
    $configPath = Join-Path $InstallPath 'src\config\settings.json'
    if (Test-Path $configPath) {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        if (Test-Path $config.logging.path) {
            Remove-Item -Path $config.logging.path -Recurse -Force
            Write-Host 'Logs removed' -ForegroundColor Green
        }
    }
}

Write-Host "`nUninstallation complete." -ForegroundColor Green
