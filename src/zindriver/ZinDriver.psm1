# ZinDriver.psm1 - hardware detection and driver matching (design 9.4 / 9.6)
#   PE  : load missing drivers into the running WinPE (drvload) from ZinPE\Drivers\PE
#   OS  : inject drivers into an applied, offline Windows (dism /Image:W:\ /Add-Driver)
#         1) vendor pack matched through Drivers\index.json
#         2) otherwise only the SDIO drivers whose hardware IDs match this machine
# ASCII-only on purpose (see ZinCommon.psm1).

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot '..\common\ZinCommon.psm1') -DisableNameChecking -ErrorAction Stop

#region Devices -------------------------------------------------------------

function Get-ZinDevice {
    <#
      Returns PnP devices with their hardware/compatible IDs (upper-case).
      -ProblemOnly: only devices with a ConfigManager error (28 = no driver installed).
    #>
    param([switch]$ProblemOnly)
    $all = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue)
    foreach ($d in $all) {
        if ($ProblemOnly -and ($d.ConfigManagerErrorCode -eq 0 -or $null -eq $d.ConfigManagerErrorCode)) { continue }
        $hw = @()
        if ($d.PSObject.Properties.Name -contains 'HardwareID' -and $d.HardwareID) { $hw = @($d.HardwareID | ForEach-Object { "$_".ToUpperInvariant() }) }
        $cid = @()
        if ($d.PSObject.Properties.Name -contains 'CompatibleID' -and $d.CompatibleID) { $cid = @($d.CompatibleID | ForEach-Object { "$_".ToUpperInvariant() }) }
        if ($hw.Count -eq 0) { continue }
        [pscustomobject]@{
            Name         = "$($d.Name)"
            DeviceID     = "$($d.DeviceID)"
            ErrorCode    = [int]$d.ConfigManagerErrorCode
            HardwareIDs  = $hw
            CompatibleIDs = $cid
        }
    }
}

#endregion

#region INF parsing ---------------------------------------------------------

function Get-ZinInfInfo {
    <#
      Parses an .inf and returns { Ids = [...] ; DriverVer ; Date ; Class ; Amd64 }.
      Follows [Manufacturer] -> model sections (with NTamd64 decorations) and collects the
      hardware IDs listed after the install-section name.
    #>
    param([Parameter(Mandatory)][string]$Path, [string[]]$Lines)
    if (-not $Lines) {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $enc = [System.Text.Encoding]::Default
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $enc = [System.Text.Encoding]::Unicode }
        elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) { $enc = [System.Text.Encoding]::UTF8 }
        $Lines = $enc.GetString($bytes) -split "`r?`n"
    }
    ConvertFrom-ZinInfText -Lines $Lines
}

function ConvertFrom-ZinInfText {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)
    $sections = @{}
    $current = $null
    foreach ($raw in $Lines) {
        $line = ($raw -replace ';.*$', '').Trim()
        if ($line -eq '') { continue }
        if ($line -match '^\[(.+)\]$') {
            $current = $Matches[1].Trim().ToLowerInvariant()
            if (-not $sections.ContainsKey($current)) { $sections[$current] = New-Object System.Collections.Generic.List[string] }
            continue
        }
        if ($null -ne $current) { $sections[$current].Add($line) }
    }

    $driverVer = ''; $class = ''
    if ($sections.ContainsKey('version')) {
        foreach ($l in $sections['version']) {
            if ($l -match '^DriverVer\s*=\s*(.+)$') { $driverVer = $Matches[1].Trim() }
            elseif ($l -match '^Class\s*=\s*(.+)$') { $class = $Matches[1].Trim().Trim('"') }
        }
    }

    $modelSections = New-Object System.Collections.Generic.List[string]
    $hasAmd64 = $false; $hasDecorations = $false
    if ($sections.ContainsKey('manufacturer')) {
        foreach ($l in $sections['manufacturer']) {
            $eq = $l.IndexOf('=')
            if ($eq -lt 0) { continue }
            $parts = @($l.Substring($eq + 1).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($parts.Count -eq 0) { continue }
            $base = $parts[0].ToLowerInvariant()
            if ($parts.Count -eq 1) {
                $modelSections.Add($base)
            } else {
                $hasDecorations = $true
                foreach ($dec in $parts[1..($parts.Count - 1)]) {
                    $d = $dec.ToLowerInvariant()
                    if ($d -like 'ntamd64*' -or $d -eq 'nt' -or $d -like 'nt.*') {
                        if ($d -like 'ntamd64*') { $hasAmd64 = $true }
                        $modelSections.Add("$base.$d")
                    }
                }
            }
        }
    }

    $ids = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($ms in $modelSections) {
        if (-not $sections.ContainsKey($ms)) { continue }
        foreach ($l in $sections[$ms]) {
            $eq = $l.IndexOf('=')
            if ($eq -lt 0) { continue }
            $parts = $l.Substring($eq + 1).Split(',')
            for ($i = 1; $i -lt $parts.Count; $i++) {
                $id = $parts[$i].Trim().Trim('"').ToUpperInvariant()
                if ($id -and $id -notmatch '^%') { [void]$ids.Add($id) }
            }
        }
    }

    $date = [datetime]::MinValue
    if ($driverVer -match '^(\d{1,2})/(\d{1,2})/(\d{4})') {
        try { $date = New-Object datetime ([int]$Matches[3]), ([int]$Matches[1]), ([int]$Matches[2]) } catch { }
    }
    [pscustomobject]@{
        Ids       = @($ids)
        DriverVer = $driverVer
        Date      = $date
        Class     = $class
        Amd64     = ($hasAmd64 -or -not $hasDecorations)
    }
}

#endregion

#region Driver index (hwid -> inf) -----------------------------------------

function New-ZinDriverIndex {
    <#
      Scans a folder of extracted drivers and writes an index:
        [{ "inf": "<relative path>", "ver": "...", "date": "yyyy-MM-dd", "class": "Net", "ids": [...] }]
      Used for Drivers\PE (pe-index.json) and any loose OS driver folder.
    #>
    param([Parameter(Mandatory)][string]$Root, [string]$OutFile)
    $rootFull = (Resolve-Path $Root).ProviderPath.TrimEnd('\')
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($inf in Get-ChildItem -Path $rootFull -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue) {
        try { $info = Get-ZinInfInfo -Path $inf.FullName } catch { Write-ZinLog "Skip unreadable inf $($inf.FullName)" 'WARN'; continue }
        if (-not $info.Amd64 -or $info.Ids.Count -eq 0) { continue }
        $entries.Add([pscustomobject]@{
            inf   = $inf.FullName.Substring($rootFull.Length + 1)
            ver   = $info.DriverVer
            date  = $info.Date.ToString('yyyy-MM-dd')
            class = $info.Class
            ids   = $info.Ids
        })
    }
    if ($OutFile) {
        Write-ZinUtf8File -Path $OutFile -Content (ConvertTo-Json -InputObject $entries.ToArray() -Depth 4 -Compress)
        Write-ZinLog "Driver index: $($entries.Count) inf -> $OutFile"
    }
    , $entries.ToArray()
}

function Get-ZinDriverIndex {
    # Loads an index file, or builds one on the fly when the file does not exist.
    param([Parameter(Mandatory)][string]$Root, [string]$IndexFile)
    if ($IndexFile -and (Test-Path $IndexFile)) { return , @(Read-ZinJson $IndexFile) }
    if (Test-Path $Root) { return , (New-ZinDriverIndex -Root $Root) }
    , @()
}

function Read-ZinDriverIndexTsv {
    <#
      Streams a large TSV index (SDIO: one line per hardware ID) and keeps only the IDs in $Ids.
      Line format: HWID <TAB> pack <TAB> inf <TAB> yyyy-MM-dd
      Returns entries shaped like the JSON index ({ pack, inf, date, ids }).
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Ids)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($i in $Ids) { [void]$set.Add($i) }
    $byInf = @{}
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        $tab = $line.IndexOf("`t")
        if ($tab -lt 1 -or -not $set.Contains($line.Substring(0, $tab))) { continue }
        $f = $line.Split("`t")
        $key = "$($f[1])|$($f[2])"
        if (-not $byInf.ContainsKey($key)) {
            $byInf[$key] = [pscustomobject]@{ pack = $f[1]; inf = $f[2]; date = $(if ($f.Count -gt 3) { $f[3] } else { '' }); ids = New-Object System.Collections.Generic.List[string] }
        }
        $byInf[$key].ids.Add($f[0].ToUpperInvariant())
    }
    , @($byInf.Values)
}

function Find-ZinDriverMatch {
    <#
      For each device, picks the best driver from an index:
        1. the most specific hardware ID that any inf supports (HardwareIDs are ordered
           most-specific first), never CompatibleIDs (too generic for offline inject)
        2. among infs for that ID, the newest DriverVer date
      Returns one object per matched device: { Device ; HardwareID ; Entry }.
    #>
    param([Parameter(Mandatory)][object[]]$Devices, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Index)
    $byId = @{}
    foreach ($e in $Index) {
        foreach ($id in $e.ids) {
            $k = "$id".ToUpperInvariant()
            if (-not $byId.ContainsKey($k)) { $byId[$k] = New-Object System.Collections.Generic.List[object] }
            $byId[$k].Add($e)
        }
    }
    foreach ($dev in $Devices) {
        foreach ($hw in $dev.HardwareIDs) {
            if (-not $byId.ContainsKey($hw)) { continue }
            $best = $byId[$hw] | Sort-Object { [string]$_.date } -Descending | Select-Object -First 1
            [pscustomobject]@{ Device = $dev; HardwareID = $hw; Entry = $best }
            break
        }
    }
}

#endregion

#region PE mode -------------------------------------------------------------

function Invoke-ZinDriverPE {
    <#
      Loads drivers for devices that have no driver in the running PE (tier T2),
      then rescans disks so newly visible VMD/RAID volumes appear.
    #>
    param([Parameter(Mandatory)][string]$ZinData)
    $peRoot = Join-Path $ZinData 'ZinPE\Drivers\PE'
    if (-not (Test-Path $peRoot)) { Write-ZinLog "No PE driver store at $peRoot"; return 0 }
    $missing = @(Get-ZinDevice -ProblemOnly)
    Write-ZinLog "Devices without driver: $($missing.Count)"
    if ($missing.Count -eq 0) { return 0 }
    foreach ($m in $missing) { Write-ZinLog "  missing: $($m.Name) [$($m.HardwareIDs[0])]" }

    $index = Get-ZinDriverIndex -Root $peRoot -IndexFile (Join-Path $peRoot 'pe-index.json')
    $hits = @(Find-ZinDriverMatch -Devices $missing -Index $index)
    $loaded = 0
    $done = @{}
    foreach ($m in $hits) {
        $inf = Join-Path $peRoot $m.Entry.inf
        if ($done.ContainsKey($inf)) { continue }
        $done[$inf] = $true
        Write-ZinLog "drvload $($m.Entry.inf) for $($m.Device.Name)"
        $out = & drvload.exe $inf 2>&1
        if ($LASTEXITCODE -eq 0) { $loaded++ } else { Write-ZinLog "drvload failed ($LASTEXITCODE): $out" 'WARN' }
    }
    if ($loaded -gt 0) {
        Invoke-ZinDiskpart -Lines @('rescan') | Out-Null
        & mountvol.exe /E 2>&1 | Out-Null
    }
    Write-ZinLog "PE drivers loaded: $loaded"
    $loaded
}

#endregion

#region OS mode -------------------------------------------------------------

function Find-ZinVendorPack {
    <#
      Matches the machine against Drivers\index.json (design 9.3):
        { "rules": [ { "manufacturer", "match": model|sku|baseboard|mtm4, "value", "os": [...], "path" } ],
          "fallback": "OS\\Generic\\SDIO" }
      "value" may use wildcards (*). Returns the rule or $null.
    #>
    param([Parameter(Mandatory)]$Info, [Parameter(Mandatory)]$Index, [ValidateSet('win10', 'win11')][string]$Os = 'win11')
    foreach ($r in $Index.rules) {
        $mf = "$($r.manufacturer)"
        if ($mf -and -not ($Info.Manufacturer -like "$mf*" -or $mf -like "$($Info.Manufacturer)*")) { continue }
        if ($r.PSObject.Properties.Name -contains 'os' -and $r.os -and (@($r.os) -notcontains $Os)) { continue }
        $actual = switch ("$($r.match)") {
            'model'     { $Info.Model; break }
            'friendly'  { $Info.FriendlyName; break }
            'sku'       { $Info.SKU; break }
            'baseboard' { $Info.BaseBoard; break }
            'mtm4'      { $Info.MTM4; break }
            default     { $null }
        }
        if ($null -eq $actual -or $actual -eq '') { continue }
        $vals = @("$($r.value)".Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        foreach ($v in $vals) {
            if ($actual -like $v) { return $r }
        }
    }
    $null
}

function Add-ZinOfflineDriver {
    # dism /Add-Driver into an offline Windows. Never uses /ForceUnsigned (design 9.6).
    param([Parameter(Mandatory)][string]$WindowsRoot, [Parameter(Mandatory)][string]$Path, [switch]$Recurse)
    $dismArgs = @("/Image:$($WindowsRoot.TrimEnd('\'))\", '/Add-Driver', "/Driver:$Path", '/English', '/LogLevel:2')
    if ($Recurse) { $dismArgs += '/Recurse' }
    Write-ZinLog "dism $($dismArgs -join ' ')"
    $out = & dism.exe @dismArgs 2>&1
    $code = $LASTEXITCODE
    $out | Where-Object { "$_" -match 'Installing|successfully|Error|error' } | ForEach-Object { Write-ZinLog "  dism> $_" 'DEBUG' }
    if ($code -ne 0) { Write-ZinLog "dism /Add-Driver exit $code for $Path" 'WARN' }
    $code
}

function Expand-ZinSdioDriver {
    <#
      SDIO index entry: { "pack": "DP_LAN_Realtek-NT_25xxx.7z", "inf": "path/in/pack/x.inf", ids, date }
      Extracts only the inf's folder from the pack to $Dest. Returns the extracted folder or $null.
    #>
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$PackDir, [Parameter(Mandatory)][string]$Dest, [Parameter(Mandatory)][string]$SevenZip)
    $pack = Join-Path $PackDir $Entry.pack
    if (-not (Test-Path $pack)) { Write-ZinLog "SDIO pack missing: $pack" 'WARN'; return $null }
    $folder = (Split-Path -Parent ($Entry.inf -replace '/', '\'))
    $target = Join-Path $Dest ([IO.Path]::GetFileNameWithoutExtension($Entry.pack) + '\' + $folder)
    if (Test-Path $target) { return $target }
    $filter = if ($folder) { "$folder\*" } else { '*' }
    $out = & $SevenZip x -y "-o$(Join-Path $Dest ([IO.Path]::GetFileNameWithoutExtension($Entry.pack)))" $pack $filter -r 2>&1
    if ($LASTEXITCODE -ne 0) { Write-ZinLog "7z failed on $($Entry.pack): $($out | Select-Object -Last 2)" 'WARN'; return $null }
    if (Test-Path $target) { $target } else { $null }
}

function Invoke-ZinDriverOS {
    <#
      Phase 1 of design 9.6: inject drivers into the applied Windows at $WindowsRoot.
      Returns a summary object for the report.
    #>
    param(
        [Parameter(Mandatory)][string]$WindowsRoot,
        [Parameter(Mandatory)][string]$ZinData,
        [ValidateSet('win10', 'win11')][string]$Os = 'win11',
        [switch]$SkipVendorPack
    )
    $drvRoot = Join-Path $ZinData 'ZinPE\Drivers'
    $info = Get-ZinMachineInfo
    Write-ZinLog "Machine: '$($info.Manufacturer)' / '$($info.Model)' / SKU '$($info.SKU)' / BaseBoard '$($info.BaseBoard)' / MTM '$($info.MTM4)'"
    $summary = [ordered]@{ Source = 'none'; Path = ''; Added = 0; Missing = @() }

    # 1. Vendor pack
    $indexFile = Join-Path $drvRoot 'index.json'
    $index = $null
    if (Test-Path $indexFile) { $index = Read-ZinJson $indexFile }
    if ($index -and -not $SkipVendorPack) {
        $rule = Find-ZinVendorPack -Info $info -Index $index -Os $Os
        if ($rule) {
            $packPath = Join-Path $drvRoot $rule.path
            if (Test-Path $packPath) {
                Write-ZinLog "Vendor pack matched: $($rule.path)"
                $code = Add-ZinOfflineDriver -WindowsRoot $WindowsRoot -Path $packPath -Recurse
                $summary.Source = 'vendor'; $summary.Path = $rule.path
                if ($code -eq 0) { $summary.Added = -1 }   # dism adds the whole pack; count not tracked
            } else {
                Write-ZinLog "Vendor pack listed in index.json but not on USB: $packPath" 'WARN'
            }
        }
    }

    # 2. Generic (SDIO) filtered by hardware ID for everything the vendor pack did not cover.
    #    We cannot ask the offline image which devices are covered, so for vendor-pack machines
    #    only devices that the vendor pack has no inf for are taken from SDIO.
    $devices = @(Get-ZinDevice)
    $sdioRoot = Join-Path $drvRoot 'OS\Generic\SDIO'
    $sdioIndexFile = Join-Path $sdioRoot 'sdio-index.tsv'
    $covered = @{}
    if ($summary.Source -eq 'vendor') {
        $vIndex = Get-ZinDriverIndex -Root (Join-Path $drvRoot $summary.Path) -IndexFile (Join-Path (Join-Path $drvRoot $summary.Path) 'pack-index.json')
        foreach ($m in @(Find-ZinDriverMatch -Devices $devices -Index $vIndex)) { $covered[$m.Device.DeviceID] = $true }
    }
    $needed = @($devices | Where-Object { -not $covered.ContainsKey($_.DeviceID) -and $_.DeviceID -notmatch '^(ROOT|SWD|STORAGE\\VOLUME|USBSTOR|HTREE)' })

    if ((Test-Path $sdioIndexFile) -and $needed.Count -gt 0) {
        $sevenZip = Find-ZinTool '7z.exe'
        if (-not $sevenZip) { Write-ZinLog '7z.exe not found - SDIO fallback skipped' 'ERROR' }
        else {
            $sdioIndex = Read-ZinDriverIndexTsv -Path $sdioIndexFile -Ids @($needed | ForEach-Object { $_.HardwareIDs })
            $found = @(Find-ZinDriverMatch -Devices $needed -Index $sdioIndex)
            Write-ZinLog "SDIO: $($found.Count) of $($needed.Count) devices have a matching driver"
            $tmp = Join-Path $env:TEMP 'ZinDriverSDIO'
            $folders = @{}
            foreach ($m in $found) {
                $dir = Expand-ZinSdioDriver -Entry $m.Entry -PackDir (Join-Path $sdioRoot 'drivers') -Dest $tmp -SevenZip $sevenZip
                if ($dir) { $folders[$dir] = $m.Device.Name }
            }
            foreach ($dir in $folders.Keys) {
                Write-ZinLog "SDIO inject: $dir ($($folders[$dir]))"
                if ((Add-ZinOfflineDriver -WindowsRoot $WindowsRoot -Path $dir -Recurse) -eq 0 -and $summary.Added -ge 0) { $summary.Added++ }
            }
            if ($summary.Source -eq 'none' -and $folders.Count -gt 0) { $summary.Source = 'sdio' }
            $matchedIds = @{}; foreach ($m in $found) { $matchedIds[$m.Device.DeviceID] = $true }
            $summary.Missing = @($needed | Where-Object { -not $matchedIds.ContainsKey($_.DeviceID) -and $_.ErrorCode -ne 0 } | ForEach-Object { "$($_.Name) [$($_.HardwareIDs[0])]" })
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    } elseif (-not (Test-Path $sdioIndexFile)) {
        Write-ZinLog "No SDIO index at $sdioIndexFile - generic fallback skipped" 'WARN'
    }

    foreach ($x in $summary.Missing) { Write-ZinLog "  still missing: $x" 'WARN' }
    [pscustomobject]$summary
}

#endregion

Export-ModuleMember -Function Read-ZinDriverIndexTsv, Get-ZinDevice, Get-ZinInfInfo, ConvertFrom-ZinInfText, New-ZinDriverIndex, Get-ZinDriverIndex, Find-ZinDriverMatch, Invoke-ZinDriverPE, Find-ZinVendorPack, Add-ZinOfflineDriver, Expand-ZinSdioDriver, Invoke-ZinDriverOS
