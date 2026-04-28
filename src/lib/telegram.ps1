$script:TelegramBotToken = $null
$script:TelegramChatId = $null
$script:AlertCooldown = @{}
$script:CooldownMinutes = 15

function Initialize-PosTelegram {
    param(
        [Parameter(Mandatory)]
        [string]$BotToken,

        [Parameter(Mandatory)]
        [string]$ChatId,

        [int]$CooldownMinutes = 15
    )

    $script:TelegramBotToken = $BotToken
    $script:TelegramChatId = $ChatId
    $script:CooldownMinutes = $CooldownMinutes
}

function Send-TelegramAlert {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'CRITICAL')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$StoreId = '',
        [switch]$BypassCooldown
    )

    if (-not $script:TelegramBotToken -or -not $script:TelegramChatId) {
        Write-PosLog -Level WARNING -Message "Telegram not configured, alert skipped: $Message" -Component 'Telegram'
        return $false
    }

    $cooldownKey = "$Level|$Message"
    if (-not $BypassCooldown -and $script:AlertCooldown.ContainsKey($cooldownKey)) {
        $lastSent = $script:AlertCooldown[$cooldownKey]
        if ((Get-Date) - $lastSent -lt [TimeSpan]::FromMinutes($script:CooldownMinutes)) {
            Write-PosLog -Level DEBUG -Message "Alert cooldown active, skipped: $Message" -Component 'Telegram'
            return $false
        }
    }

    $icon = switch ($Level) {
        'INFO'     { [char]0x2139 }
        'WARNING'  { [char]0x26A0 }
        'ERROR'    { [char]0x274C }
        'CRITICAL' { [char]0x1F6A8 }
    }

    $storePrefix = if ($StoreId) { "[$StoreId] " } else { '' }
    $text = "$icon $Level`n${storePrefix}$Message`n$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

    $uri = "https://api.telegram.org/bot$($script:TelegramBotToken)/sendMessage"
    $body = @{
        chat_id    = $script:TelegramChatId
        text       = $text
        parse_mode = 'HTML'
    }

    try {
        $null = Invoke-RestMethod -Uri $uri -Method POST -Body $body -TimeoutSec 10
        $script:AlertCooldown[$cooldownKey] = Get-Date
        Write-PosLog -Level INFO -Message "Telegram alert sent: $Level - $Message" -Component 'Telegram'
        return $true
    }
    catch {
        Write-PosLog -Level ERROR -Message "Telegram send failed: $_" -Component 'Telegram'
        return $false
    }
}

function Clear-AlertCooldown {
    $script:AlertCooldown.Clear()
}
