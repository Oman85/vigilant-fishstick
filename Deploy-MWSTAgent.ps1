#Requires -Version 5.1
<#
.SYNOPSIS
    Pushes the watchdog (Agent\mwstv4.ps1) to kiosks over the admin share, and
    optionally registers the scheduled task that starts the v6 launcher.

.DESCRIPTION
    For each target kiosk:

      1. checks it is reachable
      2. compares the SHA-256 of the installed script with the new one;
         identical means there is nothing to do
      3. keeps the installed script as mwstv4.ps1.bak-<timestamp>
      4. copies the new script under a temporary name, verifies its hash,
         then renames it into place - the launcher can never start a
         half-copied file
      5. reads the installed file back and confirms the hash

    Nothing else on the kiosk is touched. MWSTv5_Launcher.bat keeps pointing
    at the same path, and existing logs stay where they are.

    The running watchdog keeps executing the old code until it is next
    started (the next logon or reboot). Until then the collector reports the
    kiosk as AGENT_OUTDATED - its reboots are still caught, through Windows
    event 1074, which the collector recognises from the old agent's comment.

    Every run writes a report to Logs\deploy_<timestamp>.csv.

    Supports -WhatIf.

  The launcher task (-RegisterLauncherTask)

    With this switch each kiosk gets two more things: Agent\MWSTv6_Launcher.bat
    installed beside the watchdog - same hash-verified, backed-up, atomic-swap
    treatment as the script itself - and a scheduled task that starts it at
    logon.

    The task runs conhost.exe, which runs cmd.exe, which runs the launcher.
    Started any other way - the batch file directly, or cmd.exe on its own -
    Windows 11 gives the console to Windows Terminal instead, where the
    launcher's MODE CON and COLOR do not behave as written.

    The task runs as <TaskDomain>\<hostname>. Every kiosk has a domain account
    named after the machine, so the account is derived per target and never
    has to be listed anywhere.

    No password is stored, typed, or sent. The task uses logon type
    InteractiveToken, which needs none; in exchange it only runs inside that
    account's interactive session - which is when a kiosk launcher is wanted,
    and never while the machine sits at the logon screen.

    The definition is written at compatibility level 1.2 - "Windows Vista /
    Windows Server 2008" in the Task Scheduler UI. That is fixed rather than a
    parameter because a newer level is rejected when the task is created
    remotely on these kiosks.

    Registration goes over a CIM session on DCOM first, then schtasks /s;
    -TaskTransport pins one.

    CIM first because it is the one these kiosks accept. On the pilot host
    the Task Scheduler's own RPC interface answered "The request is not
    supported" (Win32 50) to every call, a read-only /query included - while
    SMB, DCOM and the Task Scheduler WMI namespace were all open. (psexec,
    once the third way, got as far as installing PSEXESVC before the kiosk
    refused the logon (1385); it is no longer used.) The kiosks listen on neither 5985 nor 5986,
    so the CIM session is built on DCOM explicitly rather than letting it
    default to WinRM.

  Reboot and verify (-RebootAndVerify)

    After a kiosk's deploy steps succeed, it is restarted and watched until
    the watchdog is demonstrably running. One kiosk at a time: the first one
    that fails stops the whole run, so a script or launcher that does not
    start is found on one kiosk rather than all of them. Kiosks after the
    failure are neither deployed to nor rebooted, and are reported as HALTED.
    Offline, unreachable and failed kiosks are never rebooted.

    The restart goes over CIM/DCOM (Win32ShutdownTracker). Whoever is at the
    kiosk gets a
    -RebootWarningSeconds countdown with -RebootMessage, and the message
    carries an "MWST-DEPLOY verify" tag into event 1074. The collector files
    these reboots as REBOOT_EXTERNAL, like the dashboard's; the tag in the
    Detail column tells the two apart.

    "Running" means all of:

      - the kiosk went down and came back with a new boot time
      - AGENT_START appears in its ledger after that boot, with the version
        that was just deployed
      - -VerifyGraceSeconds later, exactly one mwstv4.ps1 process is still
        running, the ledger shows no AGENT_STOP, AGENT_ERROR,
        RESTART_TRIGGERED or LOOP_GUARD_ENGAGED since the start, and the
        screen is not in an open white or low-white episode
      - the launcher's cmd.exe was started by conhost.exe, and the watchdog
        (V7.0 and later) reports that its console is the classic console
        host rather than Windows Terminal

    The logon account, the task's last run and the process owner are checked
    along the way. They are not pass/fail on their own, but when a kiosk
    never gets as far as AGENT_START they say where it stopped: no autologon,
    the wrong account, a task that did not run, a launcher that did not
    start the script, or a script that hung before writing its first row.

    A kiosk takes about 6-8 minutes: countdown, restart, autologon, the
    launcher's own 60-second splash, then the grace period.

.PARAMETER KioskList
    Kiosk list to take targets from. Default: the SharePoint master via
    OneDrive, falling back to a local copy. Only HAS MWST = Y kiosks are
    targeted.

.PARAMETER Hosts
    Explicit host names. Overrides the list - use this to pilot on one or two
    kiosks first.

.PARAMETER AgentSource
    Script to deploy. Default: Agent\mwstv4.ps1 next to this script.

.PARAMETER TargetPathTemplate
    Folder on each kiosk. {0} is the host name.

.PARAMETER Credential
    Alternate credential for the admin share.

.PARAMETER CredentialFile
    A credential saved with Save-KioskCredential.ps1.

.PARAMETER Force
    Copy even when the installed script already has the same hash.

.PARAMETER RegisterLauncherTask
    Also install the launcher and register the logon task that starts it.

.PARAMETER LauncherSource
    Launcher to deploy. Default: Agent\MWSTv6_Launcher.bat next to this
    script.

.PARAMETER LauncherFileName
    Name the launcher is given on the kiosk.

.PARAMETER TaskName
    Task name. Default: MWST v6.1 - the name the kiosks already use, so a run
    updates the existing task instead of leaving a second one beside it.

.PARAMETER TaskPath
    Task Scheduler folder. Default: \ (the root), again to match what is
    already on the kiosks.

.PARAMETER TaskDomain
    NetBIOS domain of the per-kiosk account. Default: the domain of whoever
    runs the deploy. The account is always <TaskDomain>\<hostname>.

.PARAMETER TaskTransport
    Auto (CIM/DCOM, then schtasks /s), Cim, or Schtasks. Cim is the one that
    works on the locked-down kiosks.

.PARAMETER RebootAndVerify
    Restart each kiosk after its deploy and confirm the watchdog starts. One
    kiosk at a time; the first failure halts the run.

.PARAMETER RebootWarningSeconds
    Countdown shown on the kiosk before it restarts. 0 restarts at once, with
    no dialog. Default 60, the same as the dashboard.

.PARAMETER RebootMessage
    Shown on the kiosk during the countdown. Default: the dashboard's message.

.PARAMETER VerifyTimeoutMinutes
    How long after the countdown ends a kiosk has to come back and start the
    watchdog. Default 20.

.PARAMETER VerifyGraceSeconds
    How long the watchdog must keep running cleanly after it starts. Default
    90 - long enough for the watchdog to record AGENT_ERROR itself if it
    cannot see the screen, which it does after six failed checks, one minute
    in.

.EXAMPLE
    .\Deploy-MWSTAgent.ps1 -Hosts SHCZ5KPI11857 -WhatIf

.EXAMPLE
    .\Deploy-MWSTAgent.ps1 -Hosts SHCZ5KPI11857 -Credential (Get-Credential)

.EXAMPLE
    .\Deploy-MWSTAgent.ps1 -CredentialFile .\Config\kiosk-admin.cred.xml

.EXAMPLE
    .\Deploy-MWSTAgent.ps1 -Hosts SHCZ5KPI11857 -CredentialFile .\Config\kiosk-admin.cred.xml -RegisterLauncherTask -TaskDomain CORP -WhatIf

.EXAMPLE
    .\Deploy-MWSTAgent.ps1 -Hosts SHCZ5KPI11857 -CredentialFile .\Config\kiosk-admin.cred.xml -RegisterLauncherTask -TaskDomain SHAPE -RebootAndVerify
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$KioskList,
    [string]$SheetName,
    [string[]]$Hosts,
    [string]$AgentSource,
    [string]$TargetPathTemplate = '\\{0}\C$\Users\Public\Documents',
    [string]$TargetFileName = 'mwstv4.ps1',
    [System.Management.Automation.PSCredential]$Credential,
    [string]$CredentialFile,
    [switch]$Force,
    [switch]$RegisterLauncherTask,
    [string]$LauncherSource,
    [string]$LauncherFileName = 'MWSTv6_Launcher.bat',
    [string]$TaskName = 'MWST v6.1',
    [string]$TaskPath = '\',
    [string]$TaskDomain = $env:USERDOMAIN,
    [ValidateSet('Auto', 'Cim', 'Schtasks')][string]$TaskTransport = 'Auto',
    [switch]$RebootAndVerify,
    [ValidateRange(0, 600)][int]$RebootWarningSeconds = 60,
    [string]$RebootMessage = 'IT is restarting this kiosk remotely. Please do not switch it off - it will come back on its own.',
    [ValidateRange(5, 120)][int]$VerifyTimeoutMinutes = 20,
    [ValidateRange(0, 1800)][int]$VerifyGraceSeconds = 90
)

Set-StrictMode -Off

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDir 'Lib\MWST.KioskList.ps1')
. (Join-Path $ScriptDir 'Lib\MWST.Remote.ps1')

$LogDir = Join-Path $ScriptDir 'Logs'

function Invoke-Retry {
    # Re-runs a file operation that failed because something else had the
    # file open for a moment - usually antivirus scanning a script that has
    # just been written, which it opens exclusively. Anything other than an
    # I/O error is a real failure and is thrown straight away.
    param([Parameter(Mandatory)][scriptblock]$Action, [int]$Attempts = 6)

    for ($attempt = 1; ; $attempt++) {
        try { return (& $Action) }
        catch {
            $io = $_.Exception
            while ($io -and $io -isnot [System.IO.IOException]) { $io = $io.InnerException }
            if (-not $io -or $attempt -ge $Attempts) { throw }
            Start-Sleep -Milliseconds (500 * $attempt)
        }
    }
}

function Get-Sha256 {
    # .NET rather than Get-FileHash: under -WhatIf, Windows PowerShell 5.1's
    # Get-FileHash silently skips resolving the path and returns nothing, so
    # every kiosk would look UP_TO_DATE in a dry run.
    param([Parameter(Mandatory)][string]$Path)

    Invoke-Retry {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        try {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { ([System.BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '') }
            finally { $sha.Dispose() }
        }
        finally { $fs.Dispose() }
    }
}

function Move-FileIntoPlace {
    <#
        Swaps the verified temp copy into place. File.Replace (ReplaceFile)
        exchanges the two in one step, so if it fails the old file is still
        there. Move-Item -Force does not work that way: it deletes the
        destination first, and if the move then fails - antivirus still
        scanning the fresh copy is the usual reason - the kiosk is left with
        nothing at all. Retried with a growing pause for the same reason.
    #>
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)

    $lastError = $null
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            if (Test-Path -LiteralPath $Destination) {
                [System.IO.File]::Replace($Source, $Destination, [NullString]::Value)
            }
            else {
                [System.IO.File]::Move($Source, $Destination)
            }
            return
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds (500 * $attempt)
        }
    }
    throw "Could not put the new file in place: $lastError"
}

function Install-KioskFile {
    <#
        Puts one file on a kiosk and proves it arrived intact: compare hashes,
        keep a timestamped backup, copy under a temporary name, verify that
        copy, swap it into place, verify again.

        The watchdog script and the launcher both go through here, so the
        launcher gets the guarantee the script has always had: a kiosk is
        never left with a half-written file, and never with no file at all.

        Failures come back as a result rather than an exception - one kiosk
        refusing a copy should not cost the rest of the fleet its deployment.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$SourceHash,
        [Parameter(Mandatory)][string]$Stamp,
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [string]$Activity = 'Install file',
        [string]$Noun = 'script',
        [string]$SuccessDetail = '',
        [switch]$Force
    )

    $out = [pscustomobject]@{ Result = ''; OldHash = ''; Backup = ''; Detail = '' }
    $folder = Split-Path -Path $Destination -Parent
    $name   = Split-Path -Path $Destination -Leaf

    try {
        if (Test-Path -LiteralPath $Destination) {
            $out.OldHash = Get-Sha256 -Path $Destination
            if ($out.OldHash -eq $SourceHash -and -not $Force) {
                $out.Result = 'UP_TO_DATE'
                return $out
            }
        }

        if (-not $Cmdlet.ShouldProcess($Destination, $Activity)) {
            $out.Result = 'WHATIF'
            return $out
        }

        $backup = $null
        if ($out.OldHash) {
            $backup = "$Destination.bak-$Stamp"
            Invoke-Retry { Copy-Item -LiteralPath $Destination -Destination $backup -Force -ErrorAction Stop }
            $out.Backup = Split-Path $backup -Leaf
        }

        $tmp = Join-Path $folder ("~$name.$Stamp.tmp")
        try {
            Invoke-Retry { Copy-Item -LiteralPath $Source -Destination $tmp -Force -ErrorAction Stop }

            $tmpHash = Get-Sha256 -Path $tmp
            if ($tmpHash -ne $SourceHash) { throw "Copied file hash mismatch ($tmpHash)" }

            Move-FileIntoPlace -Source $tmp -Destination $Destination
        }
        finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }

            # Whatever happened above, never leave a kiosk without its
            # watchdog script: the launcher would fail at the next logon and
            # the kiosk would run unwatched with nothing to say so.
            if ($backup -and -not (Test-Path -LiteralPath $Destination)) {
                try { Invoke-Retry { Copy-Item -LiteralPath $backup -Destination $Destination -Force -ErrorAction Stop } } catch {}
            }
        }

        $finalHash = Get-Sha256 -Path $Destination
        if ($finalHash -ne $SourceHash) { throw "Installed file hash mismatch ($finalHash)" }

        $out.Result = 'UPDATED'
        $out.Detail = $SuccessDetail
    }
    catch {
        $out.Result = 'FAILED'
        $out.Detail = $_.Exception.Message
        try {
            if (Test-Path -LiteralPath $Destination) {
                $out.Detail += " The previous $Noun is still in place."
            }
            elseif ($out.OldHash) {
                $out.Detail += " WARNING: there is no $Noun on this kiosk now - restore it before the next logon."
            }
        }
        catch {}
    }

    return $out
}

# --- Launcher task ----------------------------------------------------------

function ConvertTo-KioskLocalPath {
    # \\HOST\C$\Users\Public\Documents -> C:\Users\Public\Documents. The task
    # runs on the kiosk, so the command it stores has to be the path the kiosk
    # itself sees, not the UNC path the deploy copies over.
    param([Parameter(Mandatory)][string]$UncPath)

    if ($UncPath -match '^\\\\[^\\]+\\([A-Za-z])\$\\?(.*)$') {
        return ('{0}:\{1}' -f $Matches[1].ToUpperInvariant(), $Matches[2].TrimEnd('\'))
    }
    throw ('Cannot work out the kiosk-local path for "{0}". -RegisterLauncherTask needs an admin-share -TargetPathTemplate, such as {1}.' -f $UncPath, '\\{0}\C$\Users\Public\Documents')
}

function Get-PlainTextPassword {
    param([System.Management.Automation.PSCredential]$Credential)

    if (-not $Credential) { return $null }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Invoke-NativeCommand {
    <#
        Runs a console tool and hands back its exit code and output instead of
        letting it derail the run.

        stdin is closed immediately. schtasks prompts on the console when it
        decides it wants a password, and a prompt nobody can answer would
        otherwise hang a fleet-wide deploy on the first awkward kiosk.
    #>
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @())

    $out = $null
    $code = 0
    try {
        $global:LASTEXITCODE = 0
        $out  = '' | & $FilePath @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    catch {
        return [pscustomobject]@{ ExitCode = -1; Output = $_.Exception.Message }
    }

    # Take the message off an ErrorRecord rather than casting the record.
    # A native command's stderr arrives as ErrorRecords, and some tools narrate
    # their progress with bare carriage returns, which become records with an
    # empty message; casting one of those yields the literal string
    # "System.Management.Automation.RemoteException" - non-empty, so it
    # survives the filter below and buries the real error in noise.
    $lines = @($out) |
        ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { [string]$_.Exception.Message }
            else { [string]$_ }
        } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }

    $text = $lines -join '; '

    # Keep the end, not the beginning. These tools announce each step and say
    # why they failed last, so the tail is the half worth keeping.
    if ($text.Length -gt 600) { $text = '...' + $text.Substring($text.Length - 600) }

    return [pscustomobject]@{ ExitCode = $code; Output = $text }
}

function New-LauncherTaskXml {
    <#
        Task XML at version 1.2 - "Configure for: Windows Vista / Windows
        Server 2008". Fixed rather than a parameter: a newer compatibility
        level is rejected when the task is created over the wire on these
        kiosks.

        LogonType InteractiveToken means no password is stored here, sent over
        the wire, or kept by the kiosk. The task then only runs inside that
        account's interactive session - the only time a kiosk launcher should
        be running anyway.
    #>
    param(
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$Command,
        [string]$Arguments = '',
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string]$Author = '',
        [string]$Description = ''
    )

    $e = { param($value) [System.Security.SecurityElement]::Escape([string]$value) }

    $template = @'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>{0}</Date>
    <Author>{1}</Author>
    <Description>{2}</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>{3}</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>{3}</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>{4}</Command>
      <Arguments>{5}</Arguments>
      <WorkingDirectory>{6}</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
'@

    return ($template -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'),
                         (& $e $Author),
                         (& $e $Description),
                         (& $e $UserId),
                         (& $e $Command),
                         (& $e $Arguments),
                         (& $e $WorkingDirectory))
}

function Register-KioskLauncherTask {
    <#
        Registers the launcher task on one kiosk. Two ways in, tried in this
        order unless -TaskTransport pins one:

          CIM/DCOM     - a CIM session over DCOM to the kiosk's Task Scheduler
                         WMI namespace. First because it is the one proven to
                         work on this fleet, and the credential stays a
                         PSCredential the whole way - it never reaches a
                         command line.

          schtasks /s  - the definition travels over the Task Scheduler's own
                         RPC interface.

                         On these kiosks that interface answers
                         "The request is not supported" (Win32 50) to every
                         call, a read-only /query included, so this is kept
                         only for hosts where it does work. It gets the admin
                         credential on a command line for the length of one
                         call; schtasks takes a credential no other way.
    #>
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$TaskFullName,
        [Parameter(Mandatory)][string]$TaskLeafName,
        [Parameter(Mandatory)][string]$TaskFolder,
        [Parameter(Mandatory)][string]$XmlPath,
        [Parameter(Mandatory)][string]$XmlText,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$Transport = 'Auto'
    )

    $schtasks = Join-Path $env:SystemRoot 'System32\schtasks.exe'
    $password = Get-PlainTextPassword -Credential $Credential
    $problems = New-Object System.Collections.Generic.List[string]

    try {
        if ($Transport -eq 'Auto' -or $Transport -eq 'Cim') {
            $session = $null
            try {
                $session = New-KioskCimSession -HostName $HostName -Credential $Credential -TimeoutSec 60

                Register-ScheduledTask -CimSession $session -TaskName $TaskLeafName -TaskPath $TaskFolder `
                                       -Xml $XmlText -Force -ErrorAction Stop | Out-Null

                return [pscustomobject]@{ Result = 'REGISTERED'; Detail = 'CIM/DCOM' }
            }
            catch {
                $problems.Add(('CIM/DCOM failed: {0}' -f $_.Exception.Message))
            }
            finally {
                if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
            }

            if ($Transport -eq 'Cim') {
                return [pscustomobject]@{ Result = 'FAILED'; Detail = ($problems -join ' | ') }
            }
        }

        if ($Transport -eq 'Auto' -or $Transport -eq 'Schtasks') {
            $a = @('/create', '/s', $HostName)
            if ($Credential) { $a += @('/u', $Credential.UserName, '/p', $password) }
            $a += @('/tn', $TaskFullName, '/xml', $XmlPath, '/f')

            $run = Invoke-NativeCommand -FilePath $schtasks -Arguments $a
            if ($run.ExitCode -eq 0) {
                return [pscustomobject]@{ Result = 'REGISTERED'; Detail = 'schtasks /s' }
            }
            $problems.Add(('schtasks /s failed ({0}): {1}' -f $run.ExitCode, $run.Output))
        }

        return [pscustomobject]@{ Result = 'FAILED'; Detail = ($problems -join ' | ') }
    }
    finally { $password = $null }
}

# --- Reboot and verify ------------------------------------------------------
#
# What happened after a restart is told apart from what happened before it by
# the kiosk's own files - the lines after the last one there was before - and
# by the task's last-run value changing. Never by comparing timestamps with
# the boot time: kiosk clocks are corrected just after boot, and move by tens
# of seconds when they are. On the pilot kiosk the launcher task shows as
# having run ten seconds before the boot it ran in.

function Format-Span {
    param([timespan]$Span)
    if ($Span.TotalSeconds -lt 0) { $Span = [timespan]::Zero }
    return ('{0}m{1:00}s' -f [int][math]::Floor($Span.TotalMinutes), $Span.Seconds)
}

function ConvertFrom-UtcText {
    # The ledger's "2026-09-16T09:52:45Z" as a UTC DateTime, or $null.
    param([string]$Value)

    $parsed = [DateTimeOffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([DateTimeOffset]::TryParse($Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed.UtcDateTime
    }
    return $null
}

function Read-SharedTail {
    <#
        The last lines of a text file the watchdog may be appending to at this
        very moment - the same share mode as Read-SharedText, but only the
        last $Bytes, because the ledger can grow to 8 MB and is read every few
        seconds while a kiosk boots. Whole lines only: the first line of the
        window is usually cut short, so it is dropped.

        The lines come back one by one, not as a single array object - every
        caller filters them in a pipeline.
    #>
    param([Parameter(Mandatory)][string]$Path, [int]$Bytes = 131072)

    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
        $start = [math]::Max([long]0, $fs.Length - $Bytes)
        [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
        $text = (New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)).ReadToEnd()
    }
    finally { $fs.Dispose() }

    $lines = @($text -split "`r?`n")
    if ($start -gt 0) { $lines = @($lines | Select-Object -Skip 1) }
    return @($lines | Where-Object { $_ -ne '' })
}

function Get-KioskFileMark {
    # The file's last line right now, so that what is written after it can be
    # picked out later. '' when the file does not exist yet: then everything
    # that appears in it is new.
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $lines = @(Read-SharedTail -Path $Path)
    if ($lines.Count -eq 0) { return '' }
    return $lines[-1]
}

function Select-LinesAfterMark {
    # The lines after the last occurrence of $Mark. A mark that is no longer
    # in the window means the file rolled over, or more has been written
    # since than the window holds - either way, all of it is new.
    param([string[]]$Lines, [string]$Mark)

    if (-not $Lines) { return @() }
    if (-not $Mark) { return $Lines }
    $at = [array]::LastIndexOf($Lines, $Mark)
    if ($at -lt 0) { return $Lines }
    return @($Lines | Select-Object -Skip ($at + 1))
}

function Get-KioskLedgerRows {
    <#
        Ledger rows written after $Mark, in the order they were written. Each
        gets TimeUtc, parsed from EventTimeUtc - for display, not for deciding
        what is new.

        The header comes from the file itself rather than a copy of the
        agent's, so a column added to the agent later cannot quietly shift
        every field read here by one.
    #>
    param([Parameter(Mandatory)][string]$Path, [string]$Mark)

    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try { $header = (New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)).ReadLine() }
    finally { $fs.Dispose() }
    if (-not $header) { return @() }

    $lines = @(Select-LinesAfterMark -Lines @(Read-SharedTail -Path $Path) -Mark $Mark | Where-Object { $_ -ne $header })
    if ($lines.Count -eq 0) { return @() }

    $rows = @(ConvertFrom-Csv -InputObject ($lines -join "`n") -Header ($header -split ','))
    foreach ($row in $rows) {
        $row | Add-Member -NotePropertyName TimeUtc -NotePropertyValue (ConvertFrom-UtcText $row.EventTimeUtc)
    }
    return $rows
}

function Get-KioskLogLines {
    # mwst.log lines written after $Mark, parsed, in the order written.
    param([Parameter(Mandatory)][string]$Path, [string]$Mark)

    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    return @(Select-LinesAfterMark -Lines @(Read-SharedTail -Path $Path) -Mark $Mark | ForEach-Object {
        if ($_ -match '^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] \[(\w+)\] (.*)$') {
            [pscustomobject]@{
                Time  = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $inv)
                Level = $Matches[2]
                Text  = $Matches[3]
            }
        }
    })
}

function Get-KioskBootTime {
    # $null while the kiosk is down or its services are still starting. Port
    # 135 is tried first because a DCOM call to a machine that is off can
    # hang for far longer than any timeout it is given.
    param([Parameter(Mandatory)][string]$HostName, [System.Management.Automation.PSCredential]$Credential)

    if (-not (Test-TcpPort -HostName $HostName -Port 135 -TimeoutMs 3000)) { return $null }

    $session = $null
    try {
        $session = New-KioskCimSession -HostName $HostName -Credential $Credential -TimeoutSec 20
        return (Get-CimInstance -CimSession $session -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    }
    catch { return $null }
    finally {
        if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
    }
}

function Get-KioskStartupState {
    <#
        One look at how far a kiosk has got towards a running watchdog. Each
        stage is kept separately so that a kiosk that never gets there can be
        reported by where it stopped, not just "timed out".

        The CIM calls and the ledger read (SMB) are independent: either can
        answer while the other cannot yet.

        Processes are not filtered by start time. Once the kiosk is known to
        have restarted, every process on it belongs to the new boot.
    #>
    param(
        [Parameter(Mandatory)][string]$HostName,
        [System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$AgentFileName,
        [string]$LauncherFileName,
        [string]$TaskLeafName,
        [string]$TaskFolder,
        [string]$LedgerMark
    )

    $state = [pscustomobject]@{
        Reachable       = $false
        ConsoleUser     = ''
        TaskLastRun     = $null
        TaskResult      = $null
        TaskError       = ''
        Processes       = @()
        Launchers       = @()
        TerminalRunning = $false
        LedgerRead      = $false
        NewRows     = @()
        AgentStart  = $null
        Error       = ''
    }

    $session = $null
    try {
        if (Test-TcpPort -HostName $HostName -Port 135 -TimeoutMs 3000) {
            $session = New-KioskCimSession -HostName $HostName -Credential $Credential -TimeoutSec 20
            $state.ConsoleUser = [string](Get-CimInstance -CimSession $session -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
            $state.Reachable = $true

            if ($TaskLeafName) {
                try {
                    $info = Get-ScheduledTaskInfo -CimSession $session -TaskPath $TaskFolder -TaskName $TaskLeafName -ErrorAction Stop
                    $state.TaskLastRun = $info.LastRunTime
                    $state.TaskResult  = $info.LastTaskResult
                }
                catch { $state.TaskError = $_.Exception.Message }
            }

            $filter = "Name = 'powershell.exe' AND CommandLine LIKE '%{0}%'" -f $AgentFileName.Replace("'", "''")
            $state.Processes = @(Get-CimInstance -CimSession $session -ClassName Win32_Process -Filter $filter -ErrorAction Stop |
                ForEach-Object {
                    $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue
                    [pscustomobject]@{
                        ProcessId = $_.ProcessId
                        Started   = $_.CreationDate
                        Owner     = $(if ($owner -and $owner.User) { "$($owner.Domain)\$($owner.User)" } else { '?' })
                    }
                })

            # Who started the launcher's cmd.exe. The task starts it from
            # conhost.exe, which keeps it in the classic console; any other
            # parent means it was started some other way, and Windows may
            # have handed its console to Windows Terminal.
            if ($LauncherFileName) {
                $filter = "Name = 'cmd.exe' AND CommandLine LIKE '%{0}%'" -f $LauncherFileName.Replace("'", "''")
                $state.Launchers = @(Get-CimInstance -CimSession $session -ClassName Win32_Process -Filter $filter -ErrorAction Stop |
                    ForEach-Object {
                        $parent = Get-CimInstance -CimSession $session -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $_.ParentProcessId) -ErrorAction SilentlyContinue
                        [pscustomobject]@{
                            ProcessId = $_.ProcessId
                            Parent    = $(if ($parent) { [string]$parent.Name } else { '(exited)' })
                        }
                    })
                $state.TerminalRunning = @(Get-CimInstance -CimSession $session -ClassName Win32_Process -Filter "Name = 'WindowsTerminal.exe'" -ErrorAction SilentlyContinue).Count -gt 0
            }
        }
        else {
            $state.Error = 'not answering on port 135'
        }
    }
    catch { $state.Error = $_.Exception.Message }
    finally {
        if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
    }

    # A folder we cannot open must not look like an empty ledger: that would
    # read as "nothing new yet" and hide the real problem.
    try {
        if (Test-Path -LiteralPath $Folder) {
            $state.NewRows    = @(Get-KioskLedgerRows -Path (Join-Path $Folder 'mwst_events.csv') -Mark $LedgerMark)
            $state.LedgerRead = $true
            $state.AgentStart = $state.NewRows | Where-Object { $_.EventType -eq 'AGENT_START' } | Select-Object -Last 1
        }
        elseif (-not $state.Error) {
            $state.Error = "cannot open $Folder"
        }
    }
    catch {
        if (-not $state.Error) { $state.Error = "ledger: $($_.Exception.Message)" }
    }

    return $state
}

function Get-StartupStallReason {
    # Why a kiosk that came back never reached AGENT_START, from the last
    # state seen. The earliest missing stage is the one worth reporting.
    param(
        $State,
        $TaskBaseline,
        [string]$ExpectedAccount,
        [string]$TaskLabel,
        [string]$AgentFileName,
        [string]$Folder,
        [string]$LogMark
    )

    if (-not $State -or -not $State.Reachable) {
        return "Came back up, then stopped answering CIM/DCOM ($($State.Error))."
    }
    if (-not $State.ConsoleUser) {
        return 'Nobody logged on - autologon did not happen, so the logon task never had a chance to run.'
    }
    if ($ExpectedAccount -and $State.ConsoleUser -ne $ExpectedAccount) {
        return "$($State.ConsoleUser) is logged on, not $ExpectedAccount - the launcher task only fires for $ExpectedAccount."
    }
    if ($TaskLabel -and $State.TaskError) {
        return "$($State.ConsoleUser) is logged on, but task $TaskLabel could not be read: $($State.TaskError)"
    }
    if ($TaskLabel -and (-not $State.TaskLastRun -or $State.TaskLastRun -eq $TaskBaseline)) {
        return ("{0} is logged on, but task {1} has not run since the restart (last run {2}, result 0x{3:X})." -f
                $State.ConsoleUser, $TaskLabel, $State.TaskLastRun, $State.TaskResult)
    }

    if ($State.Processes.Count -eq 0) {
        $text = "The logon task ran but no $AgentFileName process is running"
        if ($null -ne $State.TaskResult) { $text += (' (task result 0x{0:X})' -f $State.TaskResult) }
        $text += ' - the launcher did not start it, or it started and exited.'
        try {
            $errors = @(Get-KioskLogLines -Path (Join-Path $Folder 'mwst.log') -Mark $LogMark |
                        Where-Object { $_.Level -eq 'ERROR' } | Select-Object -Last 2)
            if ($errors) {
                $text += ' mwst.log: ' + (($errors | ForEach-Object { "[$($_.Time.ToString('HH:mm:ss'))] $($_.Text)" }) -join ' / ')
            }
        }
        catch {}
        return $text
    }

    $pids = ($State.Processes | ForEach-Object { $_.ProcessId }) -join ', '
    if (-not $State.LedgerRead) {
        return "$AgentFileName is running (PID $pids), but its ledger could not be read: $($State.Error)"
    }
    return "$AgentFileName is running (PID $pids) but has not written AGENT_START to its ledger - stuck during startup, or unable to write to $Folder."
}

function Send-KioskReboot {
    <#
        Asks the kiosk to restart, over CIM/DCOM (Send-KioskRestart in
        Lib\MWST.Remote.ps1).

        Win32ShutdownTracker rather than Reboot or Win32Shutdown because it
        takes the same countdown and comment as shutdown.exe. The comment is
        what whoever stands at the kiosk sees, and Windows writes it into
        event 1074, where the collector keeps it in the Detail of the
        REBOOT_EXTERNAL row.

        A call that broke off - which is also what a kiosk going down
        mid-reply looks like - is reported as sent, and the boot-time check
        that follows settles it.
    #>
    param(
        [Parameter(Mandatory)][string]$HostName,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$WarningSeconds,
        [string]$Message,
        [Parameter(Mandatory)][string]$Tag
    )

    # Shutdown comments are capped at 512 characters. Shorten the message,
    # never the tag - the tag is the part anyone searches for afterwards.
    $room = 500 - $Tag.Length - 3
    if ($Message.Length -gt $room) { $Message = $Message.Substring(0, $room) }
    $comment = if ($Message) { "$Message [$Tag]" } else { "[$Tag]" }

    # Planned | major: application | minor: installation - what
    # shutdown /d p:4:2 records. 0x80040002, written in decimal because
    # PowerShell reads that hex literal as a negative Int32.
    return Send-KioskRestart -HostName $HostName -Credential $Credential -WarningSeconds $WarningSeconds `
                             -Comment $comment -ReasonCode ([uint32]2147745794)
}

function Invoke-KioskRebootVerification {
    <#
        Restarts one kiosk and follows it until the watchdog is running, or
        until it is clear that it will not be. Result is one of:

          VERIFIED  restarted; the watchdog started with the deployed version
                    and stayed healthy through the grace period
          FAILED    restarted (or asked to), but a check did not pass - the
                    Detail says which
          NOT_SENT  not restarted at all: the restart was refused, or the
                    before-restart reading could not be taken, without which
                    a fresh start cannot be told from the old one
    #>
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$Folder,
        [System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory)][string]$AgentFileName,
        [string]$LauncherFileName,
        [string]$ExpectedVersion,
        [string]$ExpectedAccount,
        [string]$TaskLeafName,
        [string]$TaskFolder,
        [int]$WarningSeconds,
        [string]$Message,
        [Parameter(Mandatory)][string]$Tag,
        [int]$TimeoutMinutes,
        [int]$GraceSeconds
    )

    $pollSeconds = 15
    $ledgerPath  = Join-Path $Folder 'mwst_events.csv'
    $logPath     = Join-Path $Folder 'mwst.log'
    $taskLabel   = if ($TaskLeafName) { "$TaskFolder$TaskLeafName" } else { '' }
    $stateArgs   = @{
        HostName         = $HostName
        Credential       = $Credential
        Folder           = $Folder
        AgentFileName    = $AgentFileName
        LauncherFileName = $LauncherFileName
        TaskLeafName     = $TaskLeafName
        TaskFolder       = $TaskFolder
    }

    $say = {
        param([string]$Text)
        Write-Host ("  {0,-16} {1,-11} {2}  {3}" -f '', '', (Get-Date).ToString('HH:mm:ss'), $Text) -ForegroundColor DarkCyan
    }
    $done = {
        param([string]$Result, [string]$Text)
        [pscustomobject]@{ Result = $Result; Detail = $Text }
    }

    # --- before ---
    # Retried: one missed probe of a kiosk that is up would otherwise stop the
    # whole run (SHCZ5KPI12472, 16 Sep, seconds after its task registered
    # over the same connection).
    $bootBefore = $null
    for ($attempt = 1; $attempt -le 3 -and -not $bootBefore; $attempt++) {
        $bootBefore = Get-KioskBootTime -HostName $HostName -Credential $Credential
        if (-not $bootBefore -and $attempt -lt 3) { Start-Sleep -Seconds 10 }
    }
    if (-not $bootBefore) {
        return (& $done 'NOT_SENT' 'Could not read the current boot time over CIM/DCOM (3 attempts) - not restarted.')
    }

    $drive = $null
    try {
        $drive = Connect-KioskShare -Folder $Folder -Credential $Credential
        if (-not (Test-Path -LiteralPath $Folder)) { throw "Cannot open $Folder." }
        $ledgerMark = Get-KioskFileMark -Path $ledgerPath
        $logMark    = Get-KioskFileMark -Path $logPath
        $before     = Get-KioskStartupState @stateArgs -LedgerMark $ledgerMark
    }
    catch {
        return (& $done 'NOT_SENT' "Could not take the before-restart reading, so a fresh start could not be recognised - not restarted. $($_.Exception.Message)")
    }
    finally { Disconnect-KioskShare -Drive $drive }

    # --- restart ---
    $send = Send-KioskReboot -HostName $HostName -Credential $Credential -WarningSeconds $WarningSeconds `
                             -Message $Message -Tag $Tag
    if (-not $send.Sent) {
        return (& $done 'NOT_SENT' "Restart refused - not restarted. $($send.Detail)")
    }
    $requested = Get-Date
    & $say ("restart sent via {0}, {1}s countdown; up since {2:yyyy-MM-dd HH:mm}" -f $send.Via, $WarningSeconds, $bootBefore)

    $deadline = $requested.AddSeconds($WarningSeconds).AddMinutes($TimeoutMinutes)

    # --- down and back ---
    $wentDown  = $null
    $bootAfter = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $pollSeconds
        $boot = Get-KioskBootTime -HostName $HostName -Credential $Credential
        if (-not $boot) {
            if (-not $wentDown) { $wentDown = Get-Date; & $say 'down' }
            continue
        }
        # Both readings come from the same kiosk, but LastBootUpTime is
        # derived from its clock, so the same boot can read a little
        # differently each time. A real restart moves it by minutes.
        if ($boot -gt $bootBefore.AddSeconds(30)) { $bootAfter = $boot; break }
    }

    if (-not $bootAfter) {
        if ($wentDown) {
            return (& $done 'FAILED' ("Went down at {0:HH:mm:ss} and was not back within {1} min." -f $wentDown, $TimeoutMinutes))
        }
        return (& $done 'FAILED' ("Never went down - still on the boot from {0:yyyy-MM-dd HH:mm}. The restart was accepted via {1} but did not happen." -f $bootBefore, $send.Via))
    }
    & $say ("back up, boot time {0:HH:mm:ss}" -f $bootAfter)

    # --- watchdog start ---
    $drive = $null
    $state = $null
    $seen  = @{}
    try {
        while ((Get-Date) -lt $deadline) {
            # SMB can come up after DCOM does, so keep trying to connect.
            if (-not $drive) {
                try { $drive = Connect-KioskShare -Folder $Folder -Credential $Credential } catch { $drive = $null }
            }

            $state = Get-KioskStartupState @stateArgs -LedgerMark $ledgerMark

            if ($state.ConsoleUser -and -not $seen.Logon) {
                $seen.Logon = $true
                & $say "logged on: $($state.ConsoleUser)"
            }
            if ($state.TaskLastRun -and $state.TaskLastRun -ne $before.TaskLastRun -and -not $seen.Task) {
                $seen.Task = $true
                & $say ("task {0} ran, {1:HH:mm:ss} kiosk time" -f $taskLabel, $state.TaskLastRun)
            }
            if ($state.Processes.Count -gt 0 -and -not $seen.Process) {
                $seen.Process = $true
                $p = $state.Processes[0]
                & $say ("{0} running: PID {1} as {2}" -f $AgentFileName, $p.ProcessId, $p.Owner)
            }
            if ($state.AgentStart) { break }

            Start-Sleep -Seconds $pollSeconds
        }

        if (-not ($state -and $state.AgentStart)) {
            $why = Get-StartupStallReason -State $state -TaskBaseline $before.TaskLastRun -ExpectedAccount $ExpectedAccount `
                                          -TaskLabel $taskLabel -AgentFileName $AgentFileName -Folder $Folder -LogMark $logMark
            return (& $done 'FAILED' ("Back up, but the watchdog did not start within {0} min. {1}" -f $TimeoutMinutes, $why))
        }

        $start    = $state.AgentStart
        $startAt  = "$($start.EventTimeLocal)".Replace('T', ' ')
        $firstPid = if ($state.Processes.Count -gt 0) { $state.Processes[0].ProcessId } else { $null }
        & $say ("AGENT_START v{0}, {1} kiosk time" -f $start.AgentVersion, $startAt)

        if ($ExpectedVersion -and $start.AgentVersion -ne $ExpectedVersion) {
            return (& $done 'FAILED' ("The watchdog that started is v{0}, not the v{1} just deployed." -f $start.AgentVersion, $ExpectedVersion))
        }

        # From V7.0 the watchdog reports its own console host - the only
        # reliable witness, because Windows can hand a console to Windows
        # Terminal after the process tree outside it has been decided.
        $consoleKind = if ("$($start.Detail)" -match 'Console=([^,;\s]+)') { $Matches[1] } else { '' }
        if ($consoleKind -and $consoleKind -ne 'conhost') {
            $what = if ($consoleKind -eq 'pseudoconsole') { 'Windows Terminal (or another terminal app)' } else { $consoleKind }
            return (& $done 'FAILED' ("The watchdog is running in {0}, not the classic console. Check the kiosk account's default terminal setting." -f $what))
        }

        # --- grace period ---
        if ($GraceSeconds -gt 0) {
            & $say "watching it for ${GraceSeconds}s"
            Start-Sleep -Seconds $GraceSeconds
        }

        # A kiosk that has just started can miss a probe or two - SHCZ5KPI11863
        # did, ninety seconds after a clean start, and failed a run it had
        # passed. So a reading that is incomplete is taken again, unless the
        # ledger already says the kiosk is restarting on purpose.
        $after = $null
        for ($attempt = 1; $attempt -le 4; $attempt++) {
            $after = Get-KioskStartupState @stateArgs -LedgerMark $ledgerMark
            $complete = $after.Reachable -and $after.LedgerRead -and
                        @($after.NewRows | Where-Object { $_.EventId -eq $start.EventId }).Count -gt 0
            $goingDown = @($after.NewRows | Where-Object { $_.EventType -eq 'RESTART_TRIGGERED' }).Count -gt 0
            if ($complete -or $goingDown -or $attempt -eq 4) { break }
            & $say "incomplete reading ($(if ($after.Error) { $after.Error } else { 'ledger not read' })), trying again in 15s"
            Start-Sleep -Seconds 15
        }

        # The checks below read "nothing bad in the ledger" as good news, so
        # first prove the ledger was actually read: the AGENT_START row just
        # seen has to be in it.
        $rows = @($after.NewRows)
        $at = -1
        for ($i = 0; $i -lt $rows.Count; $i++) {
            if ($rows[$i].EventId -eq $start.EventId) { $at = $i }
        }
        if (-not $after.LedgerRead -or $at -lt 0) {
            return (& $done 'FAILED' "Could not re-read the ledger after the grace period, so the watchdog's health is unknown. $($after.Error)")
        }
        $sinceStart = @($rows | Select-Object -Skip ($at + 1))

        # RESTART_TRIGGERED is written durably before the watchdog calls
        # shutdown.exe, so it is readable even when the kiosk is already going
        # down again - which is why this comes before the reachability check.
        $bad = $sinceStart | Where-Object { $_.EventType -in @('AGENT_STOP', 'AGENT_ERROR', 'RESTART_TRIGGERED', 'LOOP_GUARD_ENGAGED') } | Select-Object -First 1
        if ($bad) {
            return (& $done 'FAILED' ("{0} after the watchdog started: {1}" -f $bad.EventType, $bad.Detail))
        }

        if (-not $after.Reachable) {
            return (& $done 'FAILED' "Stopped answering CIM/DCOM during the grace period ($($after.Error)).")
        }

        $procs = @($after.Processes)
        if ($procs.Count -eq 0) {
            return (& $done 'FAILED' "The watchdog started, then exited within ${GraceSeconds}s without recording why.")
        }
        if ($procs.Count -gt 1) {
            $pids = ($procs | ForEach-Object { "$($_.ProcessId) ($($_.Owner))" }) -join ', '
            $starter = if ($taskLabel) { $taskLabel } else { 'the logon task' }
            return (& $done 'FAILED' ("{0} watchdogs are running: PID {1}. Something besides {2} also starts the launcher; both will act on a white screen and both write the ledger." -f $procs.Count, $pids, $starter))
        }
        if ($firstPid -and $procs[0].ProcessId -ne $firstPid) {
            return (& $done 'FAILED' ("The watchdog was replaced during the grace period (PID {0} -> {1})." -f $firstPid, $procs[0].ProcessId))
        }

        $launchers = @($after.Launchers)
        $unpinned  = @($launchers | Where-Object { $_.Parent -ne 'conhost.exe' })
        if ($unpinned.Count -gt 0) {
            $which = ($unpinned | ForEach-Object { "cmd.exe PID $($_.ProcessId) started by $($_.Parent)" }) -join ', '
            $wt = if ($after.TerminalRunning) { '; Windows Terminal is running on the kiosk' } else { '' }
            return (& $done 'FAILED' ("The launcher is not in the classic console: {0}{1}. The task should start it through conhost.exe - re-register it with -RegisterLauncherTask." -f $which, $wt))
        }
        $console = if ($consoleKind) { 'classic console (reported by the watchdog)' }
                   elseif ($launchers.Count -gt 0) { 'started by conhost (the watchdog does not report its console before V7.0)' }
                   else { "console not checked - no $LauncherFileName process" }

        # An episode still open means the screen reads white or blank right
        # now: the KPI display did not come back after the restart, and the
        # watchdog will restart the kiosk again if it stays that way. One that
        # opened and closed is normal - the pilot kiosk read 91% white for ten
        # seconds as its display came up.
        $open = @{}
        foreach ($row in $sinceStart) {
            if ($row.EventType -match '^(WHITE|LOWWHITE)_EPISODE_(START|END)$') {
                if ($Matches[2] -eq 'START') { $open[$Matches[1]] = $row } else { $open.Remove($Matches[1]) }
            }
        }
        foreach ($kind in @('WHITE', 'LOWWHITE')) {
            if ($open[$kind]) {
                $what = if ($kind -eq 'WHITE') { 'white' } else { 'blank' }
                return (& $done 'FAILED' ("The screen has read as {0} since {1} kiosk time - the KPI display is not up, and the watchdog will restart the kiosk again if it stays that way." -f $what, "$($open[$kind].EventTimeLocal)".Replace('T', ' ')))
            }
        }

        # Screen-check errors since this start: below the watchdog's own
        # AGENT_ERROR threshold, so worth a note rather than a failure.
        $log = @(Get-KioskLogLines -Path $logPath -Mark $logMark)
        $from = 0
        for ($i = 0; $i -lt $log.Count; $i++) {
            if ($log[$i].Text -like 'Watchdog v* started.*') { $from = $i + 1 }
        }
        $screenErrors = @($log | Select-Object -Skip $from | Where-Object { $_.Text -like 'Screen check failed*' }).Count

        $notes = New-Object System.Collections.Generic.List[string]
        $notes.Add(("restarted via {0}, back after {1}" -f $send.Via, (Format-Span ($bootAfter - $requested))))
        $notes.Add(("v{0} PID {1} as {2}, started {3}" -f $start.AgentVersion, $procs[0].ProcessId, $procs[0].Owner, $startAt))
        $notes.Add(("healthy for {0}s, {1} screen-check error(s)" -f $GraceSeconds, $screenErrors))
        $notes.Add($console)
        # V7.0 records whether its console window was still on screen when it
        # started. Only the launcher hides it early enough to stay off the
        # kiosk app during the splash, so a watchdog that had to do it itself
        # is running under an older launcher.
        $window = if ("$($start.Detail)" -match 'Window=([^,;\s]+)') { $Matches[1] } else { '' }
        if ($window -eq 'hidden-by-watchdog') {
            $notes.Add("NOTE: the launcher left its window on screen and the watchdog hid it - redeploy with -RegisterLauncherTask")
        }
        elseif ($window) {
            $notes.Add("console window $window")
        }
        if ($ExpectedAccount -and $procs[0].Owner -ne $ExpectedAccount) {
            $notes.Add("NOTE: running as $($procs[0].Owner), not $ExpectedAccount")
        }

        return [pscustomobject]@{ Result = 'VERIFIED'; Detail = ($notes -join '; ') }
    }
    finally {
        Disconnect-KioskShare -Drive $drive
    }
}

# --- Sources ----------------------------------------------------------------
if (-not $AgentSource) { $AgentSource = Join-Path $ScriptDir 'Agent\mwstv4.ps1' }
if (-not (Test-Path -LiteralPath $AgentSource)) { throw "Agent script not found: $AgentSource" }

if (-not $Credential -and $CredentialFile) { $Credential = Import-StoredCredential -Path $CredentialFile }

# Refuse to ship a script that does not even parse. A syntax error deployed
# to every kiosk is a fleet with no watchdog.
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $AgentSource).Path, [ref]$null, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    $first = $parseErrors[0]
    throw ("Agent script has {0} parse error(s); first at line {1}: {2}" -f $parseErrors.Count, $first.Extent.StartLineNumber, $first.Message)
}

$newHash = Get-Sha256 -Path $AgentSource
$agentVersion = ''
$versionLine = Select-String -LiteralPath $AgentSource -Pattern '^\$AgentVersion\s*=\s*"([^"]+)"' | Select-Object -First 1
if ($versionLine) { $agentVersion = $versionLine.Matches[0].Groups[1].Value }

Write-Host ("Deploying {0} (v{1}, sha256 {2}...)" -f $AgentSource, $agentVersion, $newHash.Substring(0, 12))

# Normalised whether or not the task is being registered: the reboot check
# uses the account and task name too, to explain a kiosk that stalls.
$TaskDomain = "$TaskDomain".Trim().Trim('\')
if ($TaskPath -notmatch '^\\') { $TaskPath = '\' + $TaskPath }
if ($TaskPath -notmatch '\\$') { $TaskPath = $TaskPath + '\' }
$taskFullName = $TaskPath + $TaskName

$launcherHash      = ''
$targetFolderLocal = ''
if ($RegisterLauncherTask) {
    if (-not $LauncherSource) { $LauncherSource = Join-Path $ScriptDir 'Agent\MWSTv6_Launcher.bat' }
    if (-not (Test-Path -LiteralPath $LauncherSource)) { throw "Launcher not found: $LauncherSource" }
    if (-not $TaskDomain) { throw 'No domain for the task account. Pass -TaskDomain.' }

    # The same folder on every kiosk, so resolve it once and fail here rather
    # than on the first host if the target template is not an admin share.
    $targetFolderLocal = ConvertTo-KioskLocalPath ($TargetPathTemplate -f 'SAMPLEHOST')

    $launcherHash = Get-Sha256 -Path $LauncherSource

    # conhost.exe, then cmd.exe, then the batch file - never the batch file or
    # cmd.exe on their own. Windows 11 hands every new console to the default
    # terminal application, which is Windows Terminal unless someone changed
    # it, and cmd.exe started directly is no exception. conhost.exe given a
    # command line hosts it itself, in the classic console the launcher is
    # written for (MODE CON and COLOR do not work the same in Windows
    # Terminal). %windir% is expanded by Task Scheduler on the kiosk.
    $launcherLocal = Join-Path $targetFolderLocal $LauncherFileName
    $taskCommand   = '%windir%\System32\conhost.exe'
    $taskArguments = '%windir%\System32\cmd.exe /c "{0}"' -f $launcherLocal

    Write-Host ("Launcher  {0} (sha256 {1}...) -> {2}" -f $LauncherSource, $launcherHash.Substring(0, 12), $launcherLocal)
    Write-Host ("Task      {0}, at logon, as {1}\<hostname>, no stored password" -f $taskFullName, $TaskDomain)
    Write-Host ("          runs {0} {1}" -f $taskCommand, $taskArguments)
}

if ($RebootAndVerify) {
    Write-Host ("Reboot    each kiosk after its deploy, {0}s countdown; watchdog must start within {1} min and run cleanly for {2}s" -f $RebootWarningSeconds, $VerifyTimeoutMinutes, $VerifyGraceSeconds)
    Write-Host  '          one kiosk at a time - the first failure stops the run' -ForegroundColor Yellow
}

# --- Targets ----------------------------------------------------------------
if ($Hosts) {
    $targets = @($Hosts | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
}
else {
    if ($KioskList) {
        $listPath = (Get-Item -LiteralPath $KioskList -ErrorAction Stop).FullName
    }
    else {
        $listInfo = Resolve-KioskListPath -ScriptDir $ScriptDir
        Write-KioskListSource -ListInfo $listInfo
        if (-not $listInfo.Path) { throw 'No kiosk list found. Use -Hosts or -KioskList.' }
        $listPath = $listInfo.Path
    }
    $targets = @(Import-KioskList -Path $listPath -SheetName $SheetName | Where-Object { $_.RunsWatchdog } | ForEach-Object { $_.Host })
}

if ($targets.Count -eq 0) { throw 'No target hosts.' }
Write-Host "$($targets.Count) target host(s)."

# --- Deploy -----------------------------------------------------------------
$stamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
$results  = New-Object System.Collections.Generic.List[object]
$haltedBy = $null

foreach ($target in $targets) {
    $h = $target.ToUpperInvariant()
    $folder = $TargetPathTemplate -f $h
    $dest = Join-Path $folder $TargetFileName

    $result = [pscustomobject]@{
        Host         = $h
        Result       = ''
        OldHash      = ''
        NewHash      = $newHash
        Backup       = ''
        Detail       = ''
        Launcher     = ''
        Task         = ''
        TaskDetail   = ''
        Reboot       = ''
        RebootDetail = ''
    }

    # After a failed reboot check nothing more is deployed: whatever stopped
    # that kiosk's watchdog would reach the next one at its next restart.
    if ($haltedBy) {
        $result.Result       = 'HALTED'
        $result.Detail       = "Not deployed: the run stopped after $haltedBy failed its reboot check."
        $result.Reboot       = 'NOT_REBOOTED'
        Write-Host ("  {0,-16} {1,-11} {2}" -f $h, $result.Result, $result.Detail) -ForegroundColor DarkYellow
        $results.Add($result)
        continue
    }

    # The deploy steps. do/while ($false) runs them once; it is there so that
    # the early exits inside (continue) leave this block and still reach the
    # reboot step below, instead of skipping straight to the next kiosk.
    do {
        $drive = $null
        try {
            $reach = Test-HostReachable -HostName $h
            if (-not $reach.Ok) {
                $result.Result = 'OFFLINE'
                $result.Detail = $reach.Error
                if ($RegisterLauncherTask) { $result.Launcher = 'SKIPPED'; $result.Task = 'SKIPPED' }
                continue
            }

            $drive = Connect-KioskShare -Folder $folder -Credential $Credential
            if (-not (Test-Path -LiteralPath $folder)) {
                $result.Result = 'NO_ACCESS'
                $result.Detail = "Cannot open $folder"
                if ($RegisterLauncherTask) { $result.Launcher = 'SKIPPED'; $result.Task = 'SKIPPED' }
                continue
            }

            # --- watchdog script ---
            $agent = Install-KioskFile -Source $AgentSource -Destination $dest -SourceHash $newHash `
                                       -Stamp $stamp -Cmdlet $PSCmdlet -Force:$Force `
                                       -Activity "Install watchdog v$agentVersion" -Noun 'script' `
                                       -SuccessDetail 'Takes effect at the next watchdog start (logon/reboot).'
            $result.Result  = $agent.Result
            $result.OldHash = $agent.OldHash
            $result.Backup  = $agent.Backup
            $result.Detail  = $agent.Detail

            # An up-to-date script is not a reason to skip the task: the two are
            # installed independently and a kiosk can easily have one without the
            # other.
            if (-not $RegisterLauncherTask) { continue }

            # --- launcher ---
            $launcherDest = Join-Path $folder $LauncherFileName
            $launcher = Install-KioskFile -Source $LauncherSource -Destination $launcherDest -SourceHash $launcherHash `
                                          -Stamp $stamp -Cmdlet $PSCmdlet -Force:$Force `
                                          -Activity 'Install v6 launcher' -Noun 'launcher'
            $result.Launcher = $launcher.Result

            if ($launcher.Result -eq 'FAILED') {
                # A task pointing at a launcher that is not there is worse than no
                # task at all: it fails at every logon while looking configured.
                $result.Task = 'SKIPPED'
                $result.TaskDetail = "Launcher not installed: $($launcher.Detail)"
                continue
            }

            # --- scheduled task ---
            $account = "$TaskDomain\$h"

            if (-not $PSCmdlet.ShouldProcess("$h $taskFullName", "Register launcher task as $account")) {
                $result.Task = 'WHATIF'
                $result.TaskDetail = "$account -> conhost > cmd /c $launcherLocal"
                continue
            }

            $xmlPath = Join-Path ([System.IO.Path]::GetTempPath()) ("mwsttask_{0}_{1}.xml" -f $h, $stamp)
            try {
                $xml = New-LauncherTaskXml -UserId $account -Command $taskCommand -Arguments $taskArguments -WorkingDirectory $targetFolderLocal `
                                           -Author "$env:USERDOMAIN\$env:USERNAME" `
                                           -Description "Starts the MWST kiosk launcher at logon. Registered from $ScriptDir."
                [System.IO.File]::WriteAllText($xmlPath, $xml, [System.Text.Encoding]::Unicode)

                $task = Register-KioskLauncherTask -HostName $h -TaskFullName $taskFullName `
                                                   -TaskLeafName $TaskName -TaskFolder $TaskPath `
                                                   -XmlPath $xmlPath -XmlText $xml `
                                                   -Credential $Credential -Transport $TaskTransport
                $result.Task = $task.Result
                $result.TaskDetail = if ($task.Result -eq 'REGISTERED') { "$account via $($task.Detail)" } else { $task.Detail }
            }
            finally {
                if (Test-Path -LiteralPath $xmlPath) { Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue }
            }
        }
        catch {
            $result.Result = 'FAILED'
            $result.Detail = $_.Exception.Message
            if ($RegisterLauncherTask) {
                if (-not $result.Launcher) { $result.Launcher = 'SKIPPED' }
                if (-not $result.Task)     { $result.Task     = 'SKIPPED' }
            }
        }
        finally {
            Disconnect-KioskShare -Drive $drive

            $color = switch ($result.Result) {
                'UPDATED'    { 'Green' }
                'UP_TO_DATE' { 'DarkGray' }
                'WHATIF'     { 'Cyan' }
                default      { 'Yellow' }
            }
            Write-Host ("  {0,-16} {1,-11} {2}" -f $h, $result.Result, $result.Detail) -ForegroundColor $color

            if ($RegisterLauncherTask) {
                $taskColor = switch ($result.Task) {
                    'REGISTERED' { 'Green' }
                    'WHATIF'     { 'Cyan' }
                    default      { 'Yellow' }
                }
                Write-Host ("  {0,-16} {1,-11} {2}" -f '', 'launcher', $result.Launcher) -ForegroundColor DarkGray
                Write-Host ("  {0,-16} {1,-11} {2}" -f '', 'task', ("{0}  {1}" -f $result.Task, $result.TaskDetail)) -ForegroundColor $taskColor
            }
        }
    } while ($false)

    # --- reboot and verify ---
    if ($RebootAndVerify) {
        $deployOk = $result.Result -in @('UPDATED', 'UP_TO_DATE', 'WHATIF')
        if ($RegisterLauncherTask) {
            $deployOk = $deployOk -and
                        $result.Launcher -in @('UPDATED', 'UP_TO_DATE', 'WHATIF') -and
                        $result.Task -in @('REGISTERED', 'WHATIF')
        }

        try {
            if (-not $deployOk) {
                $result.Reboot       = 'SKIPPED'
                $result.RebootDetail = 'The deploy did not succeed here, so the kiosk was left running.'
            }
            elseif (-not $PSCmdlet.ShouldProcess($h, "Restart ($RebootWarningSeconds s countdown) and verify the watchdog starts")) {
                $result.Reboot = 'WHATIF'
            }
            else {
                $check = Invoke-KioskRebootVerification -HostName $h -Folder $folder -Credential $Credential `
                                                        -AgentFileName $TargetFileName -LauncherFileName $LauncherFileName `
                                                        -ExpectedVersion $agentVersion `
                                                        -ExpectedAccount $(if ($TaskDomain) { "$TaskDomain\$h" } else { '' }) `
                                                        -TaskLeafName $TaskName -TaskFolder $TaskPath `
                                                        -WarningSeconds $RebootWarningSeconds -Message $RebootMessage `
                                                        -Tag "MWST-DEPLOY verify run=$stamp" `
                                                        -TimeoutMinutes $VerifyTimeoutMinutes -GraceSeconds $VerifyGraceSeconds
                $result.Reboot       = $check.Result
                $result.RebootDetail = $check.Detail
            }
        }
        catch {
            $result.Reboot       = 'FAILED'
            $result.RebootDetail = "The reboot check broke off: $($_.Exception.Message)"
        }

        if ($result.Reboot -in @('FAILED', 'NOT_SENT')) { $haltedBy = $h }

        $rebootColor = switch ($result.Reboot) {
            'VERIFIED' { 'Green' }
            'WHATIF'   { 'Cyan' }
            'SKIPPED'  { 'DarkGray' }
            default    { 'Red' }
        }
        Write-Host ("  {0,-16} {1,-11} {2}" -f '', 'reboot', ("{0}  {1}" -f $result.Reboot, $result.RebootDetail)) -ForegroundColor $rebootColor
    }

    $results.Add($result)
}

Write-Host ''
$results | Group-Object Result | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-11} {1}" -f $_.Name, $_.Count) }

if ($RegisterLauncherTask) {
    Write-Host ''
    Write-Host '  launcher task'
    $results | Group-Object Task | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-11} {1}" -f $_.Name, $_.Count) }
}

if ($RebootAndVerify) {
    Write-Host ''
    Write-Host '  reboot check'
    $results | Group-Object Reboot | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-13} {1}" -f $_.Name, $_.Count) }
    if ($haltedBy) {
        Write-Host ''
        Write-Host ("  Stopped at {0}. A new run restarts every kiosk again, verified ones included -" -f $haltedBy) -ForegroundColor Red
        Write-Host  '  use -Hosts to carry on from where this one stopped.' -ForegroundColor Red
    }
}

if ($WhatIfPreference) {
    Write-Host 'No report written (-WhatIf).'
}
else {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $reportPath = Join-Path $LogDir "deploy_$stamp.csv"
    $results | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
    Write-Host "Report: $reportPath"
}
