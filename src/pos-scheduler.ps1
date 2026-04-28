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
    -Component 'scheduler'

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

$taskState = @{}
$taskRetries = @{}
$maxRetries = 3

foreach ($task in $config.scheduler.tasks) {
    $taskState[$task.name] = @{
        LastRun    = [datetime]::MinValue
        Running    = $false
        Job        = $null
        LastResult = $null
        LastError  = $null
        Duration   = $null
    }
    $taskRetries[$task.name] = 0
}

$maxParallel = if ($config.scheduler.PSObject.Properties['maxParallelTasks']) {
    $config.scheduler.maxParallelTasks
} else {
    3
}

Write-PosLog -Level INFO -Message "POS Scheduler started. Store: $($config.storeId), Tasks: $($config.scheduler.tasks.Count), MaxParallel: $maxParallel" -Component 'scheduler'

function Get-TaskRunScriptBlock {
    return {
        param($BaseUrl, $Endpoint, $TimeoutSec, $Username, $Password)

        $uri = "$BaseUrl$Endpoint"
        $params = @{
            Uri         = $uri
            Method      = 'POST'
            TimeoutSec  = $TimeoutSec
            ContentType = 'application/json; charset=utf-8'
        }

        if ($Username) {
            $secPwd = ConvertTo-SecureString $Password -AsPlainText -Force
            $params['Credential'] = New-Object System.Management.Automation.PSCredential($Username, $secPwd)
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $response = Invoke-RestMethod @params
            $sw.Stop()
            return @{ Success = $true; Data = $response; Duration = $sw.Elapsed.TotalSeconds; Error = $null }
        }
        catch {
            $sw.Stop()
            return @{ Success = $false; Data = $null; Duration = $sw.Elapsed.TotalSeconds; Error = $_.Exception.Message }
        }
    }
}

function Start-ScheduledTask {
    param(
        [object]$TaskConfig
    )

    $state = $taskState[$TaskConfig.name]

    if ($state.Running) {
        Write-PosLog -Level DEBUG -Message "Task '$($TaskConfig.name)' still running, skipped" -Component 'scheduler'
        return
    }

    $runningCount = ($taskState.Values | Where-Object { $_.Running }).Count
    if ($runningCount -ge $maxParallel) {
        Write-PosLog -Level DEBUG -Message "Max parallel ($maxParallel) reached, deferring '$($TaskConfig.name)'" -Component 'scheduler'
        return
    }

    $state.Running = $true
    $state.LastRun = Get-Date

    Write-PosLog -Level INFO -Message "Starting task '$($TaskConfig.name)' -> $($TaskConfig.endpoint)" -Component 'scheduler'

    $scriptBlock = Get-TaskRunScriptBlock
    $state.Job = Start-Job -ScriptBlock $scriptBlock -ArgumentList @(
        (Get-OneCHttpBaseUrl),
        $TaskConfig.endpoint,
        $TaskConfig.timeoutSec,
        $config.oneC.clientUser,
        $config.oneC.clientPassword
    )
}

function Complete-ScheduledTasks {
    foreach ($taskName in $taskState.Keys) {
        $state = $taskState[$taskName]
        if (-not $state.Running -or -not $state.Job) { continue }

        $job = $state.Job
        if ($job.State -notin @('Completed', 'Failed', 'Stopped')) { continue }

        try {
            $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
        }
        catch {
            $result = @{ Success = $false; Error = $_.Exception.Message; Duration = 0 }
        }

        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

        $state.Running = $false
        $state.Job = $null

        if ($result -and $result.Success) {
            $state.LastResult = 'success'
            $state.LastError = $null
            $state.Duration = "$([math]::Round($result.Duration, 1))s"
            $taskRetries[$taskName] = 0
            Write-PosLog -Level INFO -Message "Task '$taskName' completed in $($state.Duration)" -Component 'scheduler'
        }
        else {
            $errorMsg = if ($result) { $result.Error } else { 'Job returned no result' }
            $state.LastResult = 'error'
            $state.LastError = $errorMsg
            $state.Duration = if ($result) { "$([math]::Round($result.Duration, 1))s" } else { 'N/A' }
            $taskRetries[$taskName]++

            Write-PosLog -Level ERROR -Message "Task '$taskName' failed (attempt $($taskRetries[$taskName])/$maxRetries): $errorMsg" -Component 'scheduler'

            if ($taskRetries[$taskName] -ge $maxRetries) {
                Send-TelegramAlert -Level WARNING -Message "Task '$taskName' failed $maxRetries times: $errorMsg" -StoreId $config.storeId
                $taskRetries[$taskName] = 0
            }
        }
    }
}

function Test-TaskDue {
    param([object]$TaskConfig)

    if (-not $TaskConfig.enabled) { return $false }

    $state = $taskState[$TaskConfig.name]
    $elapsed = (Get-Date) - $state.LastRun
    return $elapsed.TotalSeconds -ge $TaskConfig.intervalSec
}

# --- Shared state file for health endpoint ---
$stateFilePath = Join-Path $config.logging.path 'scheduler-state.json'

function Export-SchedulerState {
    $export = @{}
    foreach ($taskName in $taskState.Keys) {
        $s = $taskState[$taskName]
        $export[$taskName] = @{
            lastRun    = if ($s.LastRun -gt [datetime]::MinValue) { $s.LastRun.ToString('o') } else { $null }
            running    = $s.Running
            lastResult = $s.LastResult
            lastError  = $s.LastError
            duration   = $s.Duration
        }
    }
    $export | ConvertTo-Json -Depth 5 | Set-Content -Path $stateFilePath -Encoding UTF8 -Force
}

# --- Main loop ---
Write-PosLog -Level INFO -Message 'Entering main loop' -Component 'scheduler'

while ($true) {
    try {
        Complete-ScheduledTasks

        foreach ($task in $config.scheduler.tasks) {
            if (Test-TaskDue -TaskConfig $task) {
                Start-ScheduledTask -TaskConfig $task
            }
        }

        Export-SchedulerState
    }
    catch {
        Write-PosLog -Level ERROR -Message "Scheduler loop error: $_" -Component 'scheduler'
    }

    Start-Sleep -Seconds 5
}
