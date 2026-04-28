param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\settings.json')
)

$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'lib\config.ps1')
. (Join-Path $PSScriptRoot 'lib\logging.ps1')
. (Join-Path $PSScriptRoot 'lib\telegram.ps1')
. (Join-Path $PSScriptRoot 'lib\onec-http.ps1')

$config = Initialize-PosConfig -Path $ConfigPath

Initialize-PosLogging `
    -Path $config.logging.path `
    -MaxFileSizeMB $config.logging.maxFileSizeMB `
    -RetentionDays $config.logging.retentionDays `
    -Component 'watchdog'

if ($config.telegram.botToken) {
    Initialize-PosTelegram `
        -BotToken $config.telegram.botToken `
        -ChatId $config.telegram.chatId `
        -CooldownMinutes $config.telegram.cooldownMinutes
}

Initialize-OneCHttp `
    -BaseUrl $config.oneC.httpBaseUrl `
    -Username $config.oneC.clientUser `
    -Password $config.oneC.clientPassword

# --- State ---
$unhealthyCount = 0
$restartTimestamps = [System.Collections.ArrayList]::new()
$restartsBlocked = $false
$lastStartTime = $null
$processName = '1cv8'

Write-PosLog -Level INFO -Message "POS Watchdog started. Store: $($config.storeId)" -Component 'watchdog'

# --- Functions ---

function Test-OneCProcessAlive {
    $proc = Get-Process -Name $processName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) { return $null }

    return @{
        Pid        = $proc.Id
        Responding = $proc.Responding
        StartTime  = $proc.StartTime
        CPU        = $proc.CPU
    }
}

function Start-OneCClient {
    $exePath = $config.oneC.exePath
    $basePath = $config.oneC.basePath
    $user = $config.oneC.clientUser
    $password = $config.oneC.clientPassword

    $args = "ENTERPRISE /F`"$basePath`" /N`"$user`""
    if ($password) {
        $args += " /P`"$password`""
    }

    Write-PosLog -Level INFO -Message "Starting 1C client: $exePath" -Component 'watchdog'

    try {
        $proc = Start-Process -FilePath $exePath -ArgumentList $args -PassThru
    }
    catch {
        Write-PosLog -Level ERROR -Message "Failed to start 1C: $_" -Component 'watchdog'
        return $false
    }

    $timeout = $config.watchdog.processStartTimeoutSec
    $elapsed = 0
    $checkInterval = 5

    while ($elapsed -lt $timeout) {
        Start-Sleep -Seconds $checkInterval
        $elapsed += $checkInterval

        $check = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if ($check -and $check.MainWindowHandle -ne [IntPtr]::Zero) {
            Write-PosLog -Level INFO -Message "1C client started successfully (PID: $($proc.Id), took ${elapsed}s)" -Component 'watchdog'
            $script:lastStartTime = Get-Date
            return $true
        }
    }

    Write-PosLog -Level ERROR -Message "1C client start timeout (${timeout}s)" -Component 'watchdog'
    return $false
}

function Stop-OneCClient {
    $proc = Get-Process -Name $processName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) { return $true }

    Write-PosLog -Level INFO -Message "Stopping 1C client (PID: $($proc.Id))" -Component 'watchdog'

    try {
        $proc.CloseMainWindow() | Out-Null
    }
    catch {
        Write-PosLog -Level WARNING -Message "CloseMainWindow failed: $_" -Component 'watchdog'
    }

    $waited = 0
    while ($waited -lt 15) {
        Start-Sleep -Seconds 1
        $waited++
        $check = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if (-not $check) {
            Write-PosLog -Level INFO -Message '1C client stopped gracefully' -Component 'watchdog'
            Start-Sleep -Seconds 3
            return $true
        }
    }

    Write-PosLog -Level WARNING -Message '1C client did not stop gracefully, force killing' -Component 'watchdog'
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5

    $stillAlive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if ($stillAlive) {
        Write-PosLog -Level ERROR -Message '1C client could not be killed' -Component 'watchdog'
        return $false
    }

    return $true
}

function Restart-OneCClient {
    if ($restartsBlocked) {
        Write-PosLog -Level WARNING -Message 'Restarts blocked (too many restarts). Waiting for manual intervention.' -Component 'watchdog'
        return $false
    }

    $oneHourAgo = (Get-Date).AddHours(-1)
    $script:restartTimestamps = [System.Collections.ArrayList]@(
        $restartTimestamps | Where-Object { $_ -gt $oneHourAgo }
    )

    if ($restartTimestamps.Count -ge $config.watchdog.maxRestartsPerHour) {
        $script:restartsBlocked = $true
        Write-PosLog -Level CRITICAL -Message "Max restarts per hour ($($config.watchdog.maxRestartsPerHour)) exceeded. Blocking restarts." -Component 'watchdog'
        Send-TelegramAlert -Level CRITICAL -Message "1C client restarted $($config.watchdog.maxRestartsPerHour)+ times in 1 hour. Automatic restarts BLOCKED. Manual intervention required." -StoreId $config.storeId -BypassCooldown
        return $false
    }

    Write-PosLog -Level WARNING -Message 'Restarting 1C client' -Component 'watchdog'

    $stopped = Stop-OneCClient
    if (-not $stopped) {
        Write-PosLog -Level ERROR -Message 'Could not stop 1C for restart' -Component 'watchdog'
        return $false
    }

    $started = Start-OneCClient
    if ($started) {
        $restartTimestamps.Add((Get-Date)) | Out-Null
        Send-TelegramAlert -Level WARNING -Message "1C client restarted (restart #$($restartTimestamps.Count) this hour)" -StoreId $config.storeId
        return $true
    }

    return $false
}

function Test-FiscalHealth {
    $status = Get-FiscalQueueStatus

    if (-not $status.Available) {
        Write-PosLog -Level WARNING -Message "Fiscal status endpoint unavailable: $($status.Error)" -Component 'watchdog'
        return $false
    }

    $staleThreshold = $config.watchdog.fiscalQueueStaleMins * 60

    if ($status.PendingReceipts -gt 0 -and $status.OldestAgeSec -gt $staleThreshold) {
        Write-PosLog -Level WARNING -Message "Fiscal queue stale: $($status.PendingReceipts) pending, oldest $($status.OldestAgeSec)s" -Component 'watchdog'
        return $false
    }

    if ($status.PendingReceipts -eq 0 -or $status.OldestAgeSec -le $staleThreshold) {
        return $true
    }

    return $true
}

# --- Shared state for health endpoint ---
$stateFilePath = Join-Path $config.logging.path 'watchdog-state.json'

function Export-WatchdogState {
    param(
        [object]$ProcessInfo
    )

    $uptime = if ($ProcessInfo -and $ProcessInfo.StartTime) {
        ((Get-Date) - $ProcessInfo.StartTime).ToString('hh\:mm\:ss')
    } else { $null }

    $state = @{
        timestamp     = (Get-Date).ToString('o')
        oneCClient    = @{
            status        = if ($ProcessInfo) { 'running' } else { 'stopped' }
            pid           = if ($ProcessInfo) { $ProcessInfo.Pid } else { $null }
            responding    = if ($ProcessInfo) { $ProcessInfo.Responding } else { $false }
            uptime        = $uptime
            restartsToday = ($restartTimestamps | Where-Object { $_.Date -eq (Get-Date).Date }).Count
        }
        unhealthyCount = $unhealthyCount
        restartsBlocked = $restartsBlocked
    }

    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $stateFilePath -Encoding UTF8 -Force
}

# --- Main loop ---
Write-PosLog -Level INFO -Message 'Entering main loop' -Component 'watchdog'

$startAttempts = 0
$maxStartAttempts = 3

while ($true) {
    try {
        $procInfo = Test-OneCProcessAlive

        if (-not $procInfo) {
            Write-PosLog -Level WARNING -Message '1C client process not found' -Component 'watchdog'

            $startAttempts++
            if ($startAttempts -le $maxStartAttempts) {
                Write-PosLog -Level INFO -Message "Start attempt $startAttempts/$maxStartAttempts" -Component 'watchdog'
                $started = Start-OneCClient
                if ($started) {
                    $startAttempts = 0
                    $unhealthyCount = 0
                }
            }
            else {
                Write-PosLog -Level CRITICAL -Message "Failed to start 1C after $maxStartAttempts attempts" -Component 'watchdog'
                Send-TelegramAlert -Level CRITICAL -Message "Cannot start 1C client after $maxStartAttempts attempts. Manual intervention required." -StoreId $config.storeId -BypassCooldown
                $startAttempts = 0
                Start-Sleep -Seconds 60
            }
        }
        else {
            $startAttempts = 0

            if (-not $procInfo.Responding) {
                Write-PosLog -Level WARNING -Message "1C client not responding (PID: $($procInfo.Pid))" -Component 'watchdog'
                $unhealthyCount++
            }
            else {
                $healthy = Test-FiscalHealth
                if ($healthy) {
                    if ($unhealthyCount -gt 0) {
                        Write-PosLog -Level INFO -Message 'Fiscal health restored' -Component 'watchdog'
                    }
                    $unhealthyCount = 0
                }
                else {
                    $unhealthyCount++
                    Write-PosLog -Level WARNING -Message "Unhealthy count: $unhealthyCount/$($config.watchdog.unhealthyThreshold)" -Component 'watchdog'
                }
            }

            if ($unhealthyCount -ge $config.watchdog.unhealthyThreshold) {
                Write-PosLog -Level ERROR -Message "Unhealthy threshold reached ($unhealthyCount). Initiating restart." -Component 'watchdog'
                Restart-OneCClient
                $unhealthyCount = 0
            }
        }

        Export-WatchdogState -ProcessInfo $procInfo
    }
    catch {
        Write-PosLog -Level ERROR -Message "Watchdog loop error: $_" -Component 'watchdog'
    }

    Start-Sleep -Seconds $config.watchdog.checkIntervalSec
}
