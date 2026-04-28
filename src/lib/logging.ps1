$script:LogPath = $null
$script:LogMaxSizeMB = 10
$script:LogRetentionDays = 30
$script:CurrentLogFile = $null

function Initialize-PosLogging {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$MaxFileSizeMB = 10,
        [int]$RetentionDays = 30,

        [Parameter(Mandatory)]
        [string]$Component
    )

    $script:LogPath = $Path
    $script:LogMaxSizeMB = $MaxFileSizeMB
    $script:LogRetentionDays = $RetentionDays

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    $script:CurrentLogFile = Join-Path $Path "$Component-$(Get-Date -Format 'yyyy-MM-dd').log"

    Remove-OldLogs
}

function Write-PosLog {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$Component = ''
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $prefix = if ($Component) { "[$Component]" } else { '' }
    $line = "$timestamp [$Level] $prefix $Message"

    Rotate-LogIfNeeded

    Add-Content -Path $script:CurrentLogFile -Value $line -Encoding UTF8

    switch ($Level) {
        'DEBUG'    { Write-Verbose $line }
        'INFO'     { Write-Host $line }
        'WARNING'  { Write-Warning $line }
        'ERROR'    { Write-Host $line -ForegroundColor Red }
        'CRITICAL' { Write-Host $line -ForegroundColor Red -BackgroundColor Yellow }
    }
}

function Rotate-LogIfNeeded {
    if (-not (Test-Path $script:CurrentLogFile)) { return }

    $file = Get-Item $script:CurrentLogFile
    if ($file.Length -gt ($script:LogMaxSizeMB * 1MB)) {
        $rotated = $script:CurrentLogFile -replace '\.log$', "-$(Get-Date -Format 'HHmmss').log"
        Move-Item -Path $script:CurrentLogFile -Destination $rotated -Force
    }

    $today = Get-Date -Format 'yyyy-MM-dd'
    $baseName = [System.IO.Path]::GetFileName($script:CurrentLogFile) -replace '-\d{4}-\d{2}-\d{2}.*', ''
    $script:CurrentLogFile = Join-Path $script:LogPath "$baseName-$today.log"
}

function Remove-OldLogs {
    if (-not $script:LogPath -or -not (Test-Path $script:LogPath)) { return }

    $cutoff = (Get-Date).AddDays(-$script:LogRetentionDays)
    Get-ChildItem -Path $script:LogPath -Filter '*.log' |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force
}
