param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\settings.json')
)

$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'lib\config.ps1')
. (Join-Path $PSScriptRoot 'lib\logging.ps1')

$config = Initialize-PosConfig -Path $ConfigPath

Initialize-PosLogging `
    -Path $config.logging.path `
    -MaxFileSizeMB $config.logging.maxFileSizeMB `
    -RetentionDays $config.logging.retentionDays `
    -Component 'health'

$port = $config.health.port
$prefix = "http://+:$port/"

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
    Write-PosLog -Level INFO -Message "Health endpoint listening on port $port" -Component 'health'
}
catch {
    Write-PosLog -Level CRITICAL -Message "Failed to start HTTP listener on port ${port}: $_" -Component 'health'
    exit 1
}

function Read-JsonState {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return $null }

    try {
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8
        return $raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Build-HealthResponse {
    $logsPath = $config.logging.path

    $watchdogState = Read-JsonState -Path (Join-Path $logsPath 'watchdog-state.json')
    $schedulerState = Read-JsonState -Path (Join-Path $logsPath 'scheduler-state.json')

    $oneCStatus = if ($watchdogState -and $watchdogState.oneCClient) {
        $watchdogState.oneCClient
    }
    else {
        @{ status = 'unknown' }
    }

    $schedulerTasks = if ($schedulerState) { $schedulerState } else { @{} }

    $overall = 'healthy'
    if ($oneCStatus.status -eq 'stopped') { $overall = 'unhealthy' }
    if ($watchdogState -and $watchdogState.restartsBlocked) { $overall = 'critical' }
    if ($oneCStatus.status -eq 'unknown') { $overall = 'degraded' }

    $hasFailedTasks = $false
    foreach ($prop in $schedulerTasks.PSObject.Properties) {
        if ($prop.Value.lastResult -eq 'error') { $hasFailedTasks = $true; break }
    }
    if ($hasFailedTasks -and $overall -eq 'healthy') { $overall = 'degraded' }

    return @{
        storeId      = $config.storeId
        timestamp    = (Get-Date).ToString('o')
        overall      = $overall
        oneCClient   = $oneCStatus
        scheduler    = $schedulerTasks
    }
}

function Send-JsonResponse {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [object]$Data,
        [int]$StatusCode = 200
    )

    $json = $Data | ConvertTo-Json -Depth 10 -Compress
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)

    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.ContentLength64 = $buffer.Length
    $Response.Headers.Add('Access-Control-Allow-Origin', '*')

    $Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Response.OutputStream.Close()
}

# --- Main loop ---
Write-PosLog -Level INFO -Message 'Entering main loop' -Component 'health'

try {
    while ($listener.IsListening) {
        try {
            $context = $listener.GetContext()
            $request = $context.Request
            $response = $context.Response

            $path = $request.Url.AbsolutePath.TrimEnd('/')

            switch ($path) {
                '/health' {
                    $data = Build-HealthResponse
                    Send-JsonResponse -Response $response -Data $data
                }
                '/ping' {
                    Send-JsonResponse -Response $response -Data @{ status = 'ok'; timestamp = (Get-Date).ToString('o') }
                }
                default {
                    Send-JsonResponse -Response $response -Data @{ error = 'Not Found' } -StatusCode 404
                }
            }

            Write-PosLog -Level DEBUG -Message "$($request.HttpMethod) $path -> $($response.StatusCode)" -Component 'health'
        }
        catch {
            Write-PosLog -Level ERROR -Message "Health endpoint error: $_" -Component 'health'
        }
    }
}
finally {
    Write-PosLog -Level INFO -Message 'Stopping health endpoint listener' -Component 'health'
    $listener.Stop()
    $listener.Close()
}
