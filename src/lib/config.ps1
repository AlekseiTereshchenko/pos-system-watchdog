$script:PosConfig = $null
$script:ConfigPath = $null

function Initialize-PosConfig {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Config file not found: $Path"
    }

    $script:ConfigPath = $Path
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    $script:PosConfig = $raw | ConvertFrom-Json

    $required = @('storeId', 'oneC', 'watchdog', 'scheduler', 'health', 'telegram', 'logging')
    foreach ($key in $required) {
        if (-not $script:PosConfig.PSObject.Properties[$key]) {
            throw "Missing required config section: $key"
        }
    }

    $oneCRequired = @('exePath', 'basePath', 'clientUser', 'httpBaseUrl')
    foreach ($key in $oneCRequired) {
        if (-not $script:PosConfig.oneC.PSObject.Properties[$key]) {
            throw "Missing required oneC config: $key"
        }
    }

    if (-not (Test-Path $script:PosConfig.oneC.exePath)) {
        Write-Warning "1C executable not found at: $($script:PosConfig.oneC.exePath)"
    }

    return $script:PosConfig
}

function Get-PosConfig {
    if (-not $script:PosConfig) {
        throw "Config not initialized. Call Initialize-PosConfig first."
    }
    return $script:PosConfig
}

function Get-SchedulerTasks {
    $config = Get-PosConfig
    return $config.scheduler.tasks
}

function Get-OneCHttpBaseUrl {
    $config = Get-PosConfig
    return $config.oneC.httpBaseUrl.TrimEnd('/')
}
