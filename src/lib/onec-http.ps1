$script:OneCBaseUrl = $null
$script:OneCCredential = $null

function Initialize-OneCHttp {
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [string]$Username,
        [string]$Password
    )

    $script:OneCBaseUrl = $BaseUrl.TrimEnd('/')

    if ($Username) {
        $secPwd = ConvertTo-SecureString $Password -AsPlainText -Force
        $script:OneCCredential = New-Object System.Management.Automation.PSCredential($Username, $secPwd)
    }
}

function Invoke-OneCEndpoint {
    param(
        [Parameter(Mandatory)]
        [string]$Endpoint,

        [ValidateSet('GET', 'POST')]
        [string]$Method = 'POST',

        [object]$Body = $null,
        [int]$TimeoutSec = 180
    )

    $uri = "$($script:OneCBaseUrl)$Endpoint"

    $params = @{
        Uri        = $uri
        Method     = $Method
        TimeoutSec = $TimeoutSec
        ContentType = 'application/json; charset=utf-8'
    }

    if ($script:OneCCredential) {
        $params['Credential'] = $script:OneCCredential
    }

    if ($Body -and $Method -eq 'POST') {
        $params['Body'] = ($Body | ConvertTo-Json -Depth 10 -Compress)
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $response = Invoke-RestMethod @params
        $stopwatch.Stop()

        return @{
            Success  = $true
            Data     = $response
            Duration = $stopwatch.Elapsed
            Error    = $null
        }
    }
    catch {
        $stopwatch.Stop()

        return @{
            Success  = $false
            Data     = $null
            Duration = $stopwatch.Elapsed
            Error    = $_.Exception.Message
        }
    }
}

function Test-OneCAvailability {
    $result = Invoke-OneCEndpoint -Endpoint '/sched/fiscal-status' -Method GET -TimeoutSec 10

    return @{
        Available = $result.Success
        Duration  = $result.Duration
        Error     = $result.Error
    }
}

function Get-FiscalQueueStatus {
    $result = Invoke-OneCEndpoint -Endpoint '/sched/fiscal-status' -Method GET -TimeoutSec 15

    if (-not $result.Success) {
        return @{
            Available       = $false
            PendingReceipts = -1
            OldestAgeSec    = -1
            Error           = $result.Error
        }
    }

    return @{
        Available       = $true
        PendingReceipts = [int]($result.Data.pendingReceipts)
        OldestAgeSec    = [int]($result.Data.oldestAgeSec)
        Error           = $null
    }
}
