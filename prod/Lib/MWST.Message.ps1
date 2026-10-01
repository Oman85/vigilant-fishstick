<#
.SYNOPSIS
    Shows a message on a kiosk through its V7.0+ watchdog, and follows it.

.DESCRIPTION
    Dot-sourced by Show-FleetManager.ps1 and Send-KioskMessage.ps1, after
    Lib\MWST.Remote.ps1.

    The message goes into the kiosk's mwst_inbox as a small JSON file,
    written under a temporary name and then renamed, so the watchdog never
    reads half of one. The watchdog removes the file when it takes it and
    records MESSAGE_SHOWN, then MESSAGE_CLOSED (OK pressed, or timed out),
    or MESSAGE_EXPIRED / MESSAGE_REJECTED if it could not show it. Those rows
    are how the sender learns what happened.

    A message that nobody picks up within the wait is withdrawn, so it cannot
    appear hours later when a watchdog next starts. ExpiresUtc is the
    backstop for when withdrawing fails too.
#>

Set-StrictMode -Off

# Finds a sent message's rows in the kiosk's event ledger.
function Find-KioskMessageRows {
    # This message's rows in the kiosk's ledger, oldest first. Only the tail
    # is read: the rows are seconds old, and the ledger can be 8 MB.
    param([Parameter(Mandatory)][string]$Ledger, [Parameter(Mandatory)][string]$Id)

    if (-not (Test-Path -LiteralPath $Ledger)) { return @() }

    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $fs = New-Object System.IO.FileStream($Ledger, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
        $header = (New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)).ReadLine()
        [void]$fs.Seek([math]::Max([long]0, $fs.Length - 262144), [System.IO.SeekOrigin]::Begin)
        $text = (New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)).ReadToEnd()
    }
    finally { $fs.Dispose() }

    if (-not $header) { return @() }
    $lines = @($text -split "`r?`n" | Where-Object { $_ -like "*MessageId=$Id*" })
    if ($lines.Count -eq 0) { return @() }
    return @(ConvertFrom-Csv -InputObject ($lines -join "`n") -Header ($header -split ','))
}

# Sends a message to a kiosk screen and follows it until shown or timed out.
function Invoke-KioskMessage {
    <#
        Sends one message and follows it for up to -WaitSeconds. Never throws:
        every outcome comes back as a Status a person can act on.

          NOT_SENT       offline, share unreadable, or no inbox (the kiosk
                         has never run a V7.0+ watchdog)
          NOT_DELIVERED  nobody picked it up in time; it was withdrawn
          SHOWN          on screen now (without -WaitForClose)
          ACKNOWLEDGED   OK was pressed          } with -WaitForClose, or if
          TIMEOUT        its countdown ran out  } it closed within the wait
          KILLED, ERROR  the window misbehaved
          EXPIRED, REJECTED  the watchdog dropped it; Detail says why
          PICKED_UP      taken from the inbox, but no ledger row yet
    #>
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$Text,
        [string]$Title = 'Message from IT',
        [ValidateRange(5, 900)][int]$Seconds = 60,
        [ValidateRange(1, 1440)][int]$ExpireMinutes = 10,
        [ValidateRange(0, 600)][int]$WaitSeconds = 45,
        [switch]$WaitForClose,
        [string]$FolderTemplate = '\\{0}\C$\Users\Public\Documents',
        [System.Management.Automation.PSCredential]$Credential,
        [scriptblock]$Progress
    )

    $inv    = [System.Globalization.CultureInfo]::InvariantCulture
    $folder = $FolderTemplate -f $HostName
    $inbox  = Join-Path $folder 'mwst_inbox'
    $result = [pscustomobject]@{ Host = $HostName; Id = ''; Status = 'NOT_SENT'; Detail = '' }
    $say    = { param($s) if ($Progress) { & $Progress $s } }

    $reach = Test-HostReachable -HostName $HostName
    if (-not $reach.Ok) { $result.Detail = "offline: $($reach.Error)"; return $result }

    $drive = $null
    try {
        $drive = Connect-KioskShare -Folder $folder -Credential $Credential
        if (-not (Test-Path -LiteralPath $folder)) { $result.Detail = "cannot open $folder"; return $result }
        if (-not (Test-Path -LiteralPath $inbox)) {
            $result.Detail = 'no message inbox - this kiosk has never run a V7.0 or later watchdog'
            return $result
        }

        # --- send ---
        $now = (Get-Date).ToUniversalTime()
        $id  = [guid]::NewGuid().ToString()
        $json = [pscustomobject]@{
            Id         = $id
            Title      = $Title
            Text       = $Text
            Seconds    = $Seconds
            From       = "$env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME"
            SentUtc    = $now.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $inv)
            ExpiresUtc = $now.AddMinutes($ExpireMinutes).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $inv)
        } | ConvertTo-Json -Compress

        $name = 'msg_{0}_{1}.json' -f $now.ToString('yyyyMMddHHmmssfff', $inv), $id.Substring(0, 8)
        $file = Join-Path $inbox $name
        $tmp  = Join-Path $inbox "~$name.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::Move($tmp, $file)

        $result.Id = $id
        $result.Status = 'QUEUED'
        & $say 'queued - waiting for the watchdog to pick it up'

        # --- follow ---
        $ledger   = Join-Path $folder 'mwst_events.csv'
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        $extended = $false
        while ($true) {
            $rows  = @(Find-KioskMessageRows -Ledger $ledger -Id $id)
            $final = $rows | Where-Object { $_.EventType -in 'MESSAGE_CLOSED', 'MESSAGE_EXPIRED', 'MESSAGE_REJECTED' } | Select-Object -Last 1
            if ($final) {
                $result.Status = $final.Outcome
                $result.Detail = ($final.Detail -replace '^MessageId=[^;]*;\s*', '')
                return $result
            }

            if ($rows | Where-Object EventType -eq 'MESSAGE_SHOWN') {
                if ($result.Status -ne 'SHOWN') {
                    $result.Status = 'SHOWN'
                    $result.Detail = "on screen for up to $Seconds s"
                    & $say 'on screen'
                }
                if (-not $WaitForClose) { return $result }
                if (-not $extended) {
                    # Long enough for its countdown to run out, plus the
                    # watchdog's next check.
                    $deadline = (Get-Date).AddSeconds($Seconds + 30)
                    $extended = $true
                    & $say "waiting for it to be closed (up to $Seconds s)"
                }
            }
            elseif ($result.Status -eq 'QUEUED' -and -not (Test-Path -LiteralPath $file)) {
                $result.Status = 'PICKED_UP'
                & $say 'picked up'
            }

            if ((Get-Date) -ge $deadline) { break }
            Start-Sleep -Seconds 2
        }

        if ($result.Status -eq 'QUEUED') {
            try {
                Remove-Item -LiteralPath $file -Force -ErrorAction Stop
                $result.Status = 'NOT_DELIVERED'
                $result.Detail = "not picked up within $WaitSeconds s, so withdrawn - is the V7.0 watchdog running there?"
            }
            catch {
                if (Test-Path -LiteralPath $file) {
                    $result.Status = 'NOT_DELIVERED'
                    $result.Detail = "not picked up, and could not be withdrawn: it will be dropped if still unseen at $($now.AddMinutes($ExpireMinutes).ToLocalTime().ToString('HH:mm'))"
                }
                else {
                    $result.Status = 'PICKED_UP'
                    $result.Detail = 'picked up at the last moment; no ledger row seen yet'
                }
            }
        }
        elseif ($result.Status -eq 'PICKED_UP') {
            $result.Detail = 'taken from the inbox, but no MESSAGE_SHOWN row appeared - check mwst.log on the kiosk'
        }
        elseif ($result.Status -eq 'SHOWN') {
            $result.Detail = 'shown, but its closing was not recorded within the wait'
        }
        return $result
    }
    catch {
        $result.Detail = $_.Exception.Message
        return $result
    }
    finally {
        Disconnect-KioskShare -Drive $drive
    }
}
