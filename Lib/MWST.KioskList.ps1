<#
.SYNOPSIS
    Resolves and reads the kiosk list.

.DESCRIPTION
    Dot-sourced by the collector and the deploy script so both pick the same
    list the same way.

    The master list lives on SharePoint:
      .../sites/TEAM-CZDivisionITcka/Shared Documents/General/KIOSKS/MASTER_KIOSK LIST.xlsx

    Nothing here talks to SharePoint. Whoever runs a scan is expected to have
    that library synced by OneDrive, which turns it into an ordinary local
    path. Sync roots are read from OneDrive's own registry key rather than
    guessed from folder names, so both "Sync" and "Add shortcut to OneDrive"
    are found wherever they land.

    The .xlsx reader is a plain OOXML zip + XML walk. No Excel, no COM, no
    modules - the collector has to run unattended under a service account
    where none of those can be relied on.

    A .csv or .txt list is accepted too, so the collector can be pointed at a
    flat file when the workbook is unavailable.
#>

Set-StrictMode -Off

# ---------------------------------------------------------------------------
# Locating the workbook
# ---------------------------------------------------------------------------
function Get-OneDriveSyncRoot {
    # Local folders OneDrive is currently syncing. Each synced library records
    # its local path as a value NAME under Accounts\<acct>\Tenants\<tenant>.
    $roots = @()

    $accountsKey = "HKCU:\SOFTWARE\Microsoft\OneDrive\Accounts"
    if (-not (Test-Path $accountsKey)) { return $roots }

    foreach ($account in Get-ChildItem $accountsKey -ErrorAction SilentlyContinue) {
        $tenantsKey = Join-Path $account.PSPath "Tenants"
        if (-not (Test-Path $tenantsKey)) { continue }

        foreach ($tenant in Get-ChildItem $tenantsKey -ErrorAction SilentlyContinue) {
            $props = Get-ItemProperty $tenant.PSPath -ErrorAction SilentlyContinue
            if (-not $props) { continue }
            foreach ($prop in $props.PSObject.Properties) {
                if ($prop.Name -like 'PS*') { continue }
                if ($prop.Name -match '^[A-Za-z]:\\' -and (Test-Path -LiteralPath $prop.Name)) {
                    $roots += $prop.Name
                }
            }
        }
    }

    return @($roots | Select-Object -Unique)
}

function Resolve-KioskListPath {
    <#
        Returns the list file to scan from, with enough context for the caller
        to say where it came from. .Path is $null if nothing was found.

        A local fallback is reported as such rather than used silently -
        scanning a stale kiosk list is worse than not scanning.
    #>
    param(
        [string]$ScriptDir,
        [string]$MasterName = "MASTER_KIOSK LIST.xlsx",
        [string[]]$LocalFallbackNames = @("MASTER_KIOSK LIST.xlsx", "NEW_KIOSK LIST.xlsx", "kiosks.csv", "kiosks.txt")
    )

    # The workbook gets filed into subfolders on the SharePoint side (it lives
    # in KIOSKS\ today), so match on the filename rather than a fixed path -
    # that way it keeps resolving when someone reorganises the library. Depth
    # is capped so this stays quick on a large OneDrive.
    #
    # The same pass notices a "<name>.xlsx.url" internet shortcut. That means
    # someone saved a link instead of syncing the library; the two look
    # identical in File Explorer but only one of them can be read.
    $shortcutOnly = $null

    foreach ($root in Get-OneDriveSyncRoot) {
        $found = @(Get-ChildItem -LiteralPath $root -Filter "$MasterName*" -Recurse -Depth 4 -File -ErrorAction SilentlyContinue)

        $hit = $found | Where-Object { $_.Name -eq $MasterName } |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) {
            return [pscustomobject]@{
                Path         = $hit.FullName
                Source       = "SharePoint master (OneDrive sync)"
                IsMaster     = $true
                Modified     = $hit.LastWriteTime
                ShortcutOnly = $null
            }
        }

        if (-not $shortcutOnly) {
            $shortcutOnly = $found | Where-Object { $_.Extension -eq '.url' } | Select-Object -First 1
        }
    }

    foreach ($name in $LocalFallbackNames) {
        $candidate = Join-Path $ScriptDir $name
        if (Test-Path -LiteralPath $candidate) {
            $item = Get-Item -LiteralPath $candidate
            return [pscustomobject]@{
                Path         = $item.FullName
                Source       = "local copy next to the scripts"
                IsMaster     = $false
                Modified     = $item.LastWriteTime
                ShortcutOnly = $(if ($shortcutOnly) { $shortcutOnly.FullName } else { $null })
            }
        }
    }

    return [pscustomobject]@{
        Path         = $null
        Source       = "not found"
        IsMaster     = $false
        Modified     = $null
        ShortcutOnly = $(if ($shortcutOnly) { $shortcutOnly.FullName } else { $null })
    }
}


# ---------------------------------------------------------------------------
# Minimal .xlsx reader
# ---------------------------------------------------------------------------
function ConvertFrom-ExcelColumnRef {
    # "BC12" -> 54 (1-based column index)
    param([string]$CellRef)

    $letters = ($CellRef -replace '\d', '')
    $index = 0
    foreach ($ch in $letters.ToUpperInvariant().ToCharArray()) {
        $index = ($index * 26) + ([int][char]$ch - 64)
    }
    return $index
}

function Get-SharedStringText {
    # A shared string is either a plain <t>, or a run of <r><t> fragments when
    # part of the cell is formatted differently. Both have to be concatenated
    # or hostnames with mixed formatting come back truncated.
    param($SiNode)

    $text = ""
    foreach ($child in $SiNode.ChildNodes) {
        if ($child.LocalName -eq 't') {
            $text += $child.InnerText
        }
        elseif ($child.LocalName -eq 'r') {
            foreach ($runChild in $child.ChildNodes) {
                if ($runChild.LocalName -eq 't') { $text += $runChild.InnerText }
            }
        }
    }
    return $text
}

function Import-KioskListFromXlsx {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$SheetName
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    # Copy to a temp file first. The workbook usually sits in a OneDrive folder
    # where it can be open in Excel or mid-sync; opening the original directly
    # fails with a sharing violation often enough to matter for an unattended
    # scan.
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("mwst_list_{0}.xlsx" -f [guid]::NewGuid().ToString("N"))
    Copy-Item -LiteralPath $Path -Destination $temp -Force -ErrorAction Stop

    $zip = $null
    $rows = @()

    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($temp)

        function Read-ZipEntryXml {
            param([string]$EntryName)
            $entry = $zip.Entries | Where-Object { $_.FullName -eq $EntryName }
            if (-not $entry) { return $null }
            $stream = $entry.Open()
            try {
                $reader = New-Object System.IO.StreamReader($stream)
                try {
                    [xml]$doc = $reader.ReadToEnd()
                    return $doc
                }
                finally { $reader.Dispose() }
            }
            finally { $stream.Dispose() }
        }

        $sharedStrings = @()
        $ssXml = Read-ZipEntryXml -EntryName "xl/sharedStrings.xml"
        if ($ssXml) {
            foreach ($si in $ssXml.sst.si) {
                $sharedStrings += (Get-SharedStringText -SiNode $si)
            }
        }

        $wbXml   = Read-ZipEntryXml -EntryName "xl/workbook.xml"
        $relsXml = Read-ZipEntryXml -EntryName "xl/_rels/workbook.xml.rels"
        if (-not $wbXml -or -not $relsXml) { throw "Not a readable .xlsx workbook: $Path" }

        $sheetNodes = @($wbXml.workbook.sheets.sheet)
        if ($SheetName) {
            $sheetNodes = @($sheetNodes | Where-Object { $_.name -eq $SheetName })
            if ($sheetNodes.Count -eq 0) { throw "Sheet '$SheetName' not found in $Path" }
        }

        foreach ($sheet in $sheetNodes) {
            $relId = $sheet.id
            if (-not $relId) { $relId = $sheet.GetAttribute("id", "http://schemas.openxmlformats.org/officeDocument/2006/relationships") }
            $rel = $relsXml.Relationships.Relationship | Where-Object { $_.Id -eq $relId }
            if (-not $rel) { continue }

            $target = $rel.Target -replace '^/xl/', '' -replace '^/', ''
            $entryName = if ($target -like "xl/*") { $target } else { "xl/$target" }

            $sheetXml = Read-ZipEntryXml -EntryName $entryName
            if (-not $sheetXml) { continue }

            $rows += Import-KioskRowsFromSheet -SheetXml $sheetXml -SharedStrings $sharedStrings -SheetName $sheet.name
        }
    }
    finally {
        if ($zip) { $zip.Dispose() }
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }

    return $rows
}

function Import-KioskRowsFromSheet {
    param($SheetXml, [string[]]$SharedStrings, [string]$SheetName)

    $out = @()
    $sheetRows = @($SheetXml.worksheet.sheetData.row)
    if ($sheetRows.Count -eq 0) { return $out }

    # Read every cell into [rowIndex][colIndex] first. Excel omits empty cells
    # entirely, so positional reading without a map silently shifts columns.
    $grid = @{}
    $rowNumbers = @()

    foreach ($row in $sheetRows) {
        $rowNum = [int]$row.r
        $rowNumbers += $rowNum
        $cells = @{}

        foreach ($c in @($row.c)) {
            if (-not $c.r) { continue }
            $colIndex = ConvertFrom-ExcelColumnRef $c.r

            $value = $null
            switch ($c.t) {
                's' {
                    if ($null -ne $c.v -and $c.v -match '^\d+$') {
                        $idx = [int]$c.v
                        if ($idx -lt $SharedStrings.Count) { $value = $SharedStrings[$idx] }
                    }
                }
                'inlineStr' {
                    if ($c.is) { $value = (Get-SharedStringText -SiNode $c.is) }
                }
                default {
                    $value = $c.v
                }
            }

            if ($null -ne $value) { $cells[$colIndex] = ([string]$value).Trim() }
        }

        $grid[$rowNum] = $cells
    }

    $rowNumbers = $rowNumbers | Sort-Object

    # Find the header row: the first row within the first ten that has a cell
    # naming the host column. Sheets in this workbook start at row 1 today,
    # but a title row above the table is a normal thing for someone to add.
    $headerRow = $null
    $headerMap = @{}

    foreach ($rowNum in ($rowNumbers | Select-Object -First 10)) {
        $cells = $grid[$rowNum]
        $map = @{}
        foreach ($colIndex in $cells.Keys) {
            $key = ($cells[$colIndex] -replace '\s+', ' ').Trim().ToUpperInvariant()
            if ($key) { $map[$key] = $colIndex }
        }
        if ($map.ContainsKey('NAME') -or $map.ContainsKey('HOST') -or $map.ContainsKey('HOSTNAME')) {
            $headerRow = $rowNum
            $headerMap = $map
            break
        }
    }

    if ($null -eq $headerRow) { return $out }

    function Get-Col {
        param([hashtable]$Map, [string[]]$Names)
        foreach ($n in $Names) {
            if ($Map.ContainsKey($n)) { return $Map[$n] }
        }
        return $null
    }

    $colHost    = Get-Col -Map $headerMap -Names @('NAME', 'HOST', 'HOSTNAME')
    $colType    = Get-Col -Map $headerMap -Names @('TYPE')
    $colFlag    = Get-Col -Map $headerMap -Names @('HAS MWST', 'HASMWST', 'MWST')
    $colActive  = Get-Col -Map $headerMap -Names @('ACTIVE', 'IS ACTIVE')
    $colLoc     = Get-Col -Map $headerMap -Names @('LOCATION')
    $colGroup   = Get-Col -Map $headerMap -Names @('RESTART GROUP', 'GROUP')
    $colInfo    = Get-Col -Map $headerMap -Names @('INFO')
    $colVersion = Get-Col -Map $headerMap -Names @('VER', 'VERSION')

    if ($null -eq $colHost) { return $out }

    foreach ($rowNum in $rowNumbers) {
        if ($rowNum -le $headerRow) { continue }
        $cells = $grid[$rowNum]
        if (-not $cells) { continue }

        $hostVal = $null
        if ($cells.ContainsKey($colHost)) { $hostVal = $cells[$colHost] }
        if ([string]::IsNullOrWhiteSpace($hostVal)) { continue }

        $out += [pscustomobject]@{
            Host          = $hostVal.Trim()
            Location      = $(if ($colLoc     -and $cells.ContainsKey($colLoc))     { $cells[$colLoc] }     else { "" })
            Type          = $(if ($colType    -and $cells.ContainsKey($colType))    { $cells[$colType] }    else { "" })
            HasMwstFlag   = $(if ($colFlag    -and $cells.ContainsKey($colFlag))    { $cells[$colFlag] }    else { "" })
            ActiveFlag    = $(if ($colActive  -and $cells.ContainsKey($colActive))  { $cells[$colActive] }  else { "" })
            RestartGroup  = $(if ($colGroup   -and $cells.ContainsKey($colGroup))   { $cells[$colGroup] }   else { "" })
            Info          = $(if ($colInfo    -and $cells.ContainsKey($colInfo))    { $cells[$colInfo] }    else { "" })
            ListedVersion = $(if ($colVersion -and $cells.ContainsKey($colVersion)) { $cells[$colVersion] } else { "" })
            Sheet         = $SheetName
        }
    }

    return $out
}


# ---------------------------------------------------------------------------
# Flat-file lists
# ---------------------------------------------------------------------------
function Import-KioskListFromFlatFile {
    param([Parameter(Mandatory)][string]$Path)

    $out = @()
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()

    if ($ext -eq '.csv') {
        foreach ($row in (Import-Csv -LiteralPath $Path)) {
            $hostVal = $row.Host; if (-not $hostVal) { $hostVal = $row.Name }
            if ([string]::IsNullOrWhiteSpace($hostVal)) { continue }
            $out += [pscustomobject]@{
                Host          = $hostVal.Trim()
                Location      = [string]$row.Location
                Type          = [string]$row.Type
                HasMwstFlag   = $(if ($row.PSObject.Properties.Name -contains 'HasMwst') { [string]$row.HasMwst } else { "Y" })
                ActiveFlag    = $(if ($row.PSObject.Properties.Name -contains 'Active')  { [string]$row.Active }  else { "" })
                RestartGroup  = [string]$row.RestartGroup
                Info          = [string]$row.Info
                ListedVersion = ""
                Sheet         = "csv"
            }
        }
        return $out
    }

    # Plain text: one hostname per line. Blank lines and # comments ignored.
    # Everything in such a file is assumed to run the watchdog - there is no
    # column to say otherwise.
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        $out += [pscustomobject]@{
            Host          = $trimmed
            Location      = ""
            Type          = "Mach2"
            HasMwstFlag   = "Y"
            ActiveFlag    = ""
            RestartGroup  = ""
            Info          = ""
            ListedVersion = ""
            Sheet         = "txt"
        }
    }

    return $out
}


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------
function Test-IsPowerBiKiosk {
    # Power BI kiosks only display a dashboard and never run the watchdog, so
    # they are never flagged HAS MWST = Y. They are still worth scanning: an
    # offline PBI screen is just as visible on the shop floor as a white one.
    param([string]$Type)

    if ([string]::IsNullOrWhiteSpace($Type)) { return $false }
    return ($Type.Trim() -match '^(PBI|POWER\s*BI)\b')
}

function Test-IsWebKiosk {
    # Kiosks that only show a web page (Web Launcher). Like Power BI ones:
    # no watchdog, but scanned, since a dark screen is as visible either way.
    param([string]$Type)

    if ([string]::IsNullOrWhiteSpace($Type)) { return $false }
    return ($Type.Trim() -match '^WEB\b')
}

function Import-KioskList {
    <#
        Returns one object per kiosk with Host, Location, Type, RestartGroup,
        and two derived flags:

          RunsWatchdog - the host is expected to have mwstv4.ps1 running, so a
                         missing ledger or a silent log is a fault.
          PingOnly     - the host is only checked for reachability.

        Which rows come back:

          ACTIVE       - a deliberate yes/no about whether to scan this kiosk
                         at all, and an explicit value beats everything else.
                         Left blank it says nothing and the rules below apply,
                         so half-filling the column cannot quietly empty the
                         fleet.
          HAS MWST = Y - the kiosk runs the watchdog.
          Power BI     - scanned for reachability even without HAS MWST, since
          and Web        a dark PBI screen is as visible on the floor as a
                         white one.

        -IncludeAll returns every row in the workbook regardless.

        A summary of what was kept and skipped is left in $script:KioskListStats
        for callers that want to report it.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$SheetName,
        [switch]$IncludeAll
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "Kiosk list not found: $Path" }

    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $raw = if ($ext -eq '.xlsx') {
        Import-KioskListFromXlsx -Path $Path -SheetName $SheetName
    } else {
        Import-KioskListFromFlatFile -Path $Path
    }

    $seen = @{}
    $out = @()
    # InactiveRows carries the skipped kiosks back to the caller, so the
    # collector can record that they are deliberately not being scanned
    # rather than leaving them to look like kiosks it forgot about.
    $stats = [pscustomobject]@{
        Rows = 0; Included = 0; Inactive = 0; NotFlagged = 0
        InactiveRows = (New-Object System.Collections.Generic.List[object])
    }

    foreach ($row in $raw) {
        $stats.Rows++

        $isPbi   = Test-IsPowerBiKiosk -Type $row.Type
        $isWeb   = Test-IsWebKiosk -Type $row.Type
        $hasMwst = ($row.HasMwstFlag -and $row.HasMwstFlag.Trim().ToUpperInvariant().StartsWith("Y"))

        $activeSet = -not [string]::IsNullOrWhiteSpace($row.ActiveFlag)
        $isActive  = $activeSet -and $row.ActiveFlag.Trim().ToUpperInvariant().StartsWith("Y")

        if (-not $IncludeAll) {
            # An explicit ACTIVE decides on its own.
            if ($activeSet -and -not $isActive) {
                $stats.Inactive++
                $stats.InactiveRows.Add([pscustomobject]@{
                    Host = $row.Host; Location = $row.Location; Type = $row.Type
                    RestartGroup = $row.RestartGroup; Active = $row.ActiveFlag
                })
                continue
            }
            if (-not $activeSet -and -not $hasMwst -and -not $isPbi -and -not $isWeb) { $stats.NotFlagged++; continue }
        }

        $key = $row.Host.ToUpperInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $stats.Included++

        $out += [pscustomobject]@{
            Host          = $row.Host
            Location      = $row.Location
            Type          = $row.Type
            RestartGroup  = $row.RestartGroup
            Info          = $row.Info
            ListedVersion = $row.ListedVersion
            Sheet         = $row.Sheet
            Active        = $row.ActiveFlag
            RunsWatchdog  = ($hasMwst -and -not $isPbi -and -not $isWeb)
            PingOnly      = $isPbi -or $isWeb -or (-not $hasMwst)
        }
    }

    $script:KioskListStats = $stats
    return $out
}

function Write-KioskListSource {
    param([Parameter(Mandatory)]$ListInfo)

    if (-not $ListInfo.Path) {
        Write-Host "Kiosk list: none found." -ForegroundColor Red
        if ($ListInfo.ShortcutOnly) {
            Write-Host ("            Found a shortcut, not the file: {0}" -f $ListInfo.ShortcutOnly) -ForegroundColor Yellow
            Write-Host "            That .url is only a link to SharePoint - there is no workbook in it to read." -ForegroundColor DarkGray
        }
        Write-Host "            Fix: sync the TEAM-CZDivisionITcka > Documents > General folder in OneDrive," -ForegroundColor DarkGray
        Write-Host "            or drop a kiosks.csv / kiosks.txt next to the collector." -ForegroundColor DarkGray
        return
    }

    $age = if ($ListInfo.Modified) {
        $days = [math]::Round(((Get-Date) - $ListInfo.Modified).TotalDays, 1)
        ", edited $days day(s) ago"
    } else { "" }

    if ($ListInfo.IsMaster -or $ListInfo.Source -like 'explicit*') {
        Write-Host ("Kiosk list: {0}" -f $ListInfo.Path) -ForegroundColor DarkGray
        Write-Host ("            {0}{1}" -f $ListInfo.Source, $age) -ForegroundColor DarkGray
    }
    else {
        Write-Host ("Kiosk list: {0}" -f $ListInfo.Path) -ForegroundColor Yellow
        Write-Host ("            {0}{1} - the SharePoint master is not synced here, so this list may be out of date." -f $ListInfo.Source, $age) -ForegroundColor Yellow
    }
}
