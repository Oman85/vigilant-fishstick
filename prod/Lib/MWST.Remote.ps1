<#
.SYNOPSIS
    Shared helpers for reaching kiosks: reachability, admin-share sessions,
    share-tolerant file reads, stored credentials, CIM/DCOM sessions and
    restarts.

.DESCRIPTION
    Dot-sourced by Collect-MWSTFleet.ps1, the deploy scripts and the front ends.
#>

Set-StrictMode -Off

# Tests whether a TCP port on a host answers.
function Test-TcpPort {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 1000)

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    }
    catch { return $false }
    finally { $client.Close() }
}

# Tests whether a kiosk is reachable (ping, then SMB port 445).
function Test-HostReachable {
    <#
        ICMP first, two attempts - one dropped packet should not mark a kiosk
        offline. Then SMB on 445 as a fallback, because a kiosk whose firewall
        drops ping but serves the admin share is reachable for every purpose
        that matters here.

        Uses the .NET Ping class rather than Test-Connection, which in Windows
        PowerShell 5.1 has no timeout parameter and can stall for seconds on
        every offline host.
    #>
    param([Parameter(Mandatory)][string]$HostName, [int]$TimeoutMs = 1500)

    $lastError = $null
    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        for ($i = 0; $i -lt 2; $i++) {
            try {
                $reply = $ping.Send($HostName, $TimeoutMs)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    return [pscustomobject]@{ Ok = $true; Method = 'ping'; Error = $null }
                }
                $lastError = "No ping reply ($($reply.Status))"
            }
            catch {
                # Almost always a DNS failure. The name does not resolve, so
                # neither a second ping nor a port probe will help.
                $inner = $_.Exception.InnerException
                $msg = if ($inner) { $inner.Message } else { $_.Exception.Message }
                return [pscustomobject]@{ Ok = $false; Method = $null; Error = "Name/ping failure: $msg" }
            }
        }
    }
    finally { $ping.Dispose() }

    if (Test-TcpPort -HostName $HostName -Port 445 -TimeoutMs $TimeoutMs) {
        return [pscustomobject]@{ Ok = $true; Method = 'smb'; Error = $null }
    }

    return [pscustomobject]@{ Ok = $false; Method = $null; Error = $lastError }
}

# Authenticates to a kiosk's admin share with a credential.
function Connect-KioskShare {
    <#
        With an alternate credential, authenticate an SMB session to the share
        root. Plain UNC access - PowerShell cmdlets and .NET file APIs alike -
        then rides on that session for as long as the drive exists. Without a
        credential there is nothing to do: the current identity is used.

        Scope is Global so the drive (and with it the SMB session) survives
        the function returning; Disconnect-KioskShare removes it.

        -WhatIf:$false on both: connecting only reads, and a dry run needs the
        session as much as a real one. Without it New-PSDrive skips itself
        under a deploy script's -WhatIf, and every kiosk the current
        account has no rights on shows as NO_ACCESS.
    #>
    param(
        [Parameter(Mandatory)][string]$Folder,
        [System.Management.Automation.PSCredential]$Credential
    )

    if (-not $Credential) { return $null }
    if ($Folder -notmatch '^(\\\\[^\\]+\\[^\\]+)') { return $null }

    $root = $Matches[1]
    $name = 'MWST' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    return New-PSDrive -Name $name -PSProvider FileSystem -Root $root -Credential $Credential -Scope Global -ErrorAction Stop -WhatIf:$false
}

# Closes a kiosk share connection.
function Disconnect-KioskShare {
    param($Drive)
    if ($Drive) { Remove-PSDrive -Name $Drive.Name -Scope Global -Force -ErrorAction SilentlyContinue -WhatIf:$false }
}

# Reads a text file without locking it for the program writing it.
function Read-SharedText {
    <#
        Reads a whole text file without getting in anyone's way.

        FileShare.ReadWrite|Delete means the kiosk's watchdog can keep
        appending to - or rolling over - the file while we read it. A plain
        Get-Content / Import-Csv opens with a stricter share mode, and on a
        kiosk that would make the watchdog's own write fail at exactly the
        wrong moment.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
        $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $fs.Dispose() }
}

# Reads all of a kiosk's event ledger files, oldest first.
function Read-AgentLedger {
    <#
        Every ledger file a kiosk has, oldest first. It lives here rather than
        in the collector because the collector reads kiosks in parallel, and a
        fetch runspace has only these libraries to work from.
    #>
    param([Parameter(Mandatory)][string]$Folder)

    $result = [pscustomobject]@{
        Files  = 0
        Rows   = New-Object System.Collections.Generic.List[object]
        Errors = New-Object System.Collections.Generic.List[string]
    }

    # Oldest first: rolled-over files (named by their timestamp) before the
    # live one, so file order is event order and the last row read is the
    # newest - which matters when several rows share the same second.
    $files = @(Get-ChildItem -LiteralPath $Folder -Filter 'mwst_events*.csv' -File -ErrorAction Stop |
               Sort-Object @{ Expression = { if ($_.Name -ieq 'mwst_events.csv') { 1 } else { 0 } } }, Name)
    $result.Files = $files.Count

    foreach ($f in $files) {
        try {
            $text = Read-SharedText -Path $f.FullName

            # Only complete lines. If the watchdog is mid-append we would
            # otherwise ingest a truncated row, and because the EventId is
            # already present it would never be replaced by the full one.
            $cut = $text.LastIndexOf("`n")
            if ($cut -lt 0) { continue }
            $text = $text.Substring(0, $cut + 1)

            foreach ($r in @($text | ConvertFrom-Csv)) { $result.Rows.Add($r) }
        }
        catch {
            $result.Errors.Add(("Ledger {0}: {1}" -f $f.Name, $_.Exception.Message))
        }
    }

    return $result
}

# Loads the credential saved by Save-KioskCredential.ps1 (DPAPI).
function Import-StoredCredential {
    <#
        Loads a credential saved with Save-KioskCredential.ps1. The file is
        DPAPI-encrypted by Export-Clixml, so it only decrypts for the same
        Windows account on the same machine that saved it.
    #>
    param([string]$Path)

    if (-not $Path) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Credential file not found: $Path" }

    $cred = Import-Clixml -LiteralPath $Path
    if ($cred -isnot [System.Management.Automation.PSCredential]) {
        throw "File does not contain a saved credential: $Path"
    }
    return $cred
}

# Opens a CIM session to a kiosk over DCOM.
function New-KioskCimSession {
    # DCOM, not WSMan: the kiosks do not listen on 5985/5986 at all, and
    # New-CimSession would default to WinRM and fail on every one of them.
    param(
        [Parameter(Mandatory)][string]$HostName,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$TimeoutSec = 30
    )

    $option = New-CimSessionOption -Protocol Dcom
    $a = @{ ComputerName = $HostName; SessionOption = $option; OperationTimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }
    if ($Credential) { $a.Credential = $Credential }
    return New-CimSession @a
}

# Restarts a kiosk over CIM/DCOM, with an optional warning and message.
function Send-KioskRestart {
    <#
        Restarts a kiosk over CIM/DCOM with Win32ShutdownTracker - what
        psshutdown and shutdown.exe did, with the credential kept a
        PSCredential the whole way instead of put on a command line.

        -WarningSeconds 0 restarts at once. Otherwise whoever stands at the
        kiosk sees -Comment and a countdown; either way Windows writes the
        comment into event 1074, where the collector keeps it.

        Returns Sent / Via / Detail. A call that broke off after it was sent
        is also what a kiosk going down mid-reply looks like, so that counts
        as sent: asking again could restart it a second time once it is back.
    #>
    param(
        [Parameter(Mandatory)][string]$HostName,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$WarningSeconds = 0,
        [string]$Comment = '',
        # Planned | other. Deploys pass 0x80040002 (planned, application:
        # installation), in decimal because PowerShell reads that hex
        # literal as a negative Int32.
        [uint32]$ReasonCode = [uint32]2147483648
    )

    # Shutdown comments are capped at 512 characters.
    if ($Comment.Length -gt 500) { $Comment = $Comment.Substring(0, 500) }

    $session = $null
    try {
        try {
            $session = New-KioskCimSession -HostName $HostName -Credential $Credential -TimeoutSec 30
            $os = Get-CimInstance -CimSession $session -ClassName Win32_OperatingSystem -ErrorAction Stop
        }
        catch { return [pscustomobject]@{ Sent = $false; Via = ''; Detail = "CIM/DCOM: $($_.Exception.Message)" } }

        try {
            # Flags 6 = reboot (2) + force (4): a kiosk has nobody to answer
            # "this app is preventing restart".
            $r = Invoke-CimMethod -InputObject $os -MethodName Win32ShutdownTracker -ErrorAction Stop -Arguments @{
                Timeout    = [uint32][math]::Max(0, $WarningSeconds)
                Comment    = $Comment
                ReasonCode = $ReasonCode
                Flags      = [int]6
            }
        }
        catch { return [pscustomobject]@{ Sent = $true; Via = 'CIM/DCOM (reply lost)'; Detail = $_.Exception.Message } }

        if ($r.ReturnValue -eq 0) { return [pscustomobject]@{ Sent = $true; Via = 'CIM/DCOM'; Detail = '' } }
        $why = (New-Object System.ComponentModel.Win32Exception([int]$r.ReturnValue)).Message
        return [pscustomobject]@{ Sent = $false; Via = ''; Detail = ('CIM/DCOM: Win32ShutdownTracker returned {0} ({1})' -f $r.ReturnValue, $why) }
    }
    finally {
        # -WhatIf:$false: a caller's dry run must still close the session.
        if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue -WhatIf:$false }
    }
}
