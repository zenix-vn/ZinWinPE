# ZinCommon.psm1 - shared helpers for ZinWinPE scripts (Loader, ZinSetup, ZinDriver, ZinPost, FixBoot, Installer)
# Target: Windows PowerShell 5.1 (WinPE) and PowerShell 7. Keep this file ASCII-only:
# PS 5.1 reads BOM-less .ps1/.psm1 as ANSI, so all user-facing (Vietnamese) text lives in Lang\*.json.

Set-StrictMode -Version 2.0

$script:ZinLogFile = $null
$script:ZinLang = @{}
$script:ZinLangFallback = @{}
$script:ZinLangCode = 'en-US'

#region Logging -------------------------------------------------------------

function Set-ZinLogFile {
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:ZinLogFile = $Path
}

function Get-ZinLogFile { $script:ZinLogFile }

function Write-ZinLog {
    # Logs are always English (design 8.6) so errors are easy to search.
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'DEBUG' { Write-Verbose $line }
        default { Write-Host $line }
    }
    if ($script:ZinLogFile) {
        try { Add-Content -Path $script:ZinLogFile -Value $line -Encoding UTF8 } catch { }
    }
}

#endregion

#region INI / JSON ----------------------------------------------------------

function Read-ZinIni {
    <#
      Parses an INI file into an ordered hashtable: @{ Section = @{ Key = Value } }.
      Full-line comments start with ';' or '#'. Inline comments must be preceded by
      whitespace (" ; comment") so values like "a.exe;b.exe" stay intact.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $result = [ordered]@{}
    $section = ''
    $result[$section] = [ordered]@{}
    foreach ($raw in [System.IO.File]::ReadAllLines((Resolve-Path $Path).ProviderPath, [System.Text.Encoding]::UTF8)) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith(';') -or $line.StartsWith('#')) { continue }
        if ($line -match '^\[(.+)\]$') {
            $section = $Matches[1].Trim()
            if (-not $result.Contains($section)) { $result[$section] = [ordered]@{} }
            continue
        }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq).Trim()
        $value = ($line.Substring($eq + 1) -replace '\s+;.*$', '').Trim()
        $result[$section][$key] = $value
    }
    $result
}

function Get-ZinIniValue {
    param($Ini, [string]$Section, [string]$Key, $Default = $null)
    if ($Ini.Contains($Section) -and $Ini[$Section].Contains($Key) -and $Ini[$Section][$Key] -ne '') {
        return $Ini[$Section][$Key]
    }
    $Default
}

function Read-ZinJson {
    param([Parameter(Mandatory)][string]$Path)
    $text = [System.IO.File]::ReadAllText((Resolve-Path $Path).ProviderPath, [System.Text.Encoding]::UTF8)
    $text | ConvertFrom-Json
}

function Write-ZinUtf8File {
    # UTF-8 without BOM (cmd.exe and most tools choke on a BOM in .cmd files).
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

#endregion

#region Locating ZINDATA ----------------------------------------------------

function Find-ZinData {
    # Finds the ZINDATA volume by its marker file \ZinPE\zinpe.tag (never by drive letter, design 3.1).
    param([string]$TagRelativePath = 'ZinPE\zinpe.tag')
    if ($env:ZINDATA -and (Test-Path (Join-Path $env:ZINDATA $TagRelativePath))) { return $env:ZINDATA.TrimEnd('\') }
    foreach ($letter in [char[]]([int][char]'C'..[int][char]'Z')) {
        $root = "$($letter):"
        if (Test-Path (Join-Path "$root\" $TagRelativePath)) { return $root }
    }
    $null
}

function Get-ZinConfig {
    # Reads ZINDATA\ZinPE\Config\zinpe.ini and returns it merged with defaults.
    param([string]$ZinData)
    $cfg = [ordered]@{
        Language        = 'vi-VN'
        Mode            = 'Normal'
        TimeZone        = 'SE Asia Standard Time'
        NtpServer       = 'time.windows.com'
        StartNetwork    = '1'
        LoadPeDrivers   = '1'
        DefaultPreset   = ''
        ShopName        = 'ZinWinPE'
    }
    if ($ZinData) {
        $path = Join-Path $ZinData 'ZinPE\Config\zinpe.ini'
        if (Test-Path $path) {
            $ini = Read-ZinIni $path
            foreach ($section in @('General', 'Loader', 'Setup')) {
                if ($ini.Contains($section)) { foreach ($k in $ini[$section].Keys) { $cfg[$k] = $ini[$section][$k] } }
            }
        }
    }
    $cfg
}

#endregion

#region i18n ----------------------------------------------------------------

function Import-ZinLang {
    <#
      Loads Lang\<code>.json (flat or nested JSON, keys addressed as "setup.select_disk").
      en-US is always loaded as fallback so a missing key never shows blank UI.
    #>
    param([Parameter(Mandatory)][string]$LangDir, [string]$Code = 'vi-VN')
    $script:ZinLangFallback = ConvertTo-ZinFlatMap (Read-ZinJson (Join-Path $LangDir 'en-US.json'))
    $file = Join-Path $LangDir "$Code.json"
    if (Test-Path $file) {
        $script:ZinLang = ConvertTo-ZinFlatMap (Read-ZinJson $file)
        $script:ZinLangCode = $Code
    } else {
        $script:ZinLang = $script:ZinLangFallback
        $script:ZinLangCode = 'en-US'
    }
}

function ConvertTo-ZinFlatMap {
    param($Object, [string]$Prefix = '')
    $map = @{}
    foreach ($p in $Object.PSObject.Properties) {
        $key = if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }
        if ($p.Value -is [System.Management.Automation.PSCustomObject]) {
            $sub = ConvertTo-ZinFlatMap $p.Value $key
            foreach ($k in $sub.Keys) { $map[$k] = $sub[$k] }
        } else {
            $map[$key] = [string]$p.Value
        }
    }
    $map
}

function Get-ZinText {
    param([Parameter(Mandatory, Position = 0)][string]$Key, [Parameter(Position = 1)][object[]]$FormatArgs)
    $text = $null
    if ($script:ZinLang.ContainsKey($Key)) { $text = $script:ZinLang[$Key] }
    elseif ($script:ZinLangFallback.ContainsKey($Key)) { $text = $script:ZinLangFallback[$Key] }
    else { $text = $Key }
    if ($FormatArgs) { $text = $text -f $FormatArgs }
    $text
}

function Get-ZinLangCode { $script:ZinLangCode }

function Get-ZinLangDir {
    # USB layout: ZinPE\Lang next to ZinPE\Scripts ; repo/RAM layout: Scripts\lang
    $scripts = Split-Path -Parent $PSScriptRoot
    foreach ($d in @((Join-Path (Split-Path -Parent $scripts) 'Lang'), (Join-Path $scripts 'lang'))) {
        if (Test-Path (Join-Path $d 'en-US.json')) { return $d }
    }
    $null
}

function Initialize-ZinLang {
    # Loads the language from -Code, else zinpe.ini Language=, else vi-VN.
    param([string]$Code, [string]$ZinData)
    if (-not $Code) { $Code = (Get-ZinConfig -ZinData $ZinData).Language }
    $dir = Get-ZinLangDir
    if ($dir) { Import-ZinLang -LangDir $dir -Code $Code }
}

#endregion

#region Processes -----------------------------------------------------------

function Invoke-ZinProcess {
    # Runs an external program, logs the command line and exit code, returns the exit code.
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$ArgumentList = '',
        [switch]$NoWait,
        [switch]$Hidden,
        [string]$WorkingDirectory
    )
    Write-ZinLog "RUN: `"$FilePath`" $ArgumentList"
    $params = @{ FilePath = $FilePath; PassThru = $true }
    if ($ArgumentList) { $params.ArgumentList = $ArgumentList }
    if (-not $NoWait) { $params.Wait = $true }
    if ($Hidden) { $params.WindowStyle = 'Hidden' }
    if ($WorkingDirectory) { $params.WorkingDirectory = $WorkingDirectory }
    try {
        $p = Start-Process @params
        if ($NoWait) { return 0 }
        Write-ZinLog "EXIT: $($p.ExitCode) ($([IO.Path]::GetFileName($FilePath)))" $(if ($p.ExitCode -eq 0) { 'INFO' } else { 'WARN' })
        return $p.ExitCode
    } catch {
        Write-ZinLog "Failed to start $FilePath : $($_.Exception.Message)" 'ERROR'
        return -1
    }
}

function Invoke-ZinCapture {
    # Runs a console program and returns its stdout lines (used for dism/diskpart/bcdedit parsing).
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @())
    Write-ZinLog "RUN: $FilePath $($ArgumentList -join ' ')" 'DEBUG'
    $out = & $FilePath @ArgumentList 2>&1
    $global:LASTEXITCODE | Out-Null
    , @($out | ForEach-Object { "$_" })
}

function Invoke-ZinDiskpart {
    # Writes a diskpart script to a temp file and runs it. Returns $true when diskpart exits 0.
    param([Parameter(Mandatory)][string[]]$Lines)
    $tmp = Join-Path $env:TEMP ("zin-diskpart-{0}.txt" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    Set-Content -Path $tmp -Value $Lines -Encoding ASCII
    Write-ZinLog ("diskpart script:`r`n    " + ($Lines -join "`r`n    "))
    $out = & diskpart.exe /s $tmp 2>&1
    $code = $LASTEXITCODE
    $out | ForEach-Object { Write-ZinLog "  diskpart> $_" 'DEBUG' }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    if ($code -ne 0) { Write-ZinLog "diskpart exit code $code" 'ERROR' ; $out | Select-Object -Last 5 | ForEach-Object { Write-ZinLog "  $_" 'ERROR' } }
    $code -eq 0
}

function Find-ZinTool {
    # Locates a helper executable: next to the scripts, in X:\Programs, in ZINDATA, or on PATH.
    param([Parameter(Mandatory)][string]$Name, [string[]]$ExtraDirs = @())
    $candidates = @()
    $candidates += $ExtraDirs
    $candidates += @(
        $PSScriptRoot,
        (Join-Path $PSScriptRoot '..\bin'),
        'X:\Programs\bin',
        'X:\Windows\System32'
    )
    $zd = Find-ZinData
    if ($zd) { $candidates += @("$zd\ZinPE\Scripts\bin", "$zd\ZinPE\bin") }
    foreach ($dir in $candidates) {
        if (-not $dir) { continue }
        $p = Join-Path $dir $Name
        if (Test-Path $p) { return (Resolve-Path $p).ProviderPath }
    }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $null
}

#endregion

#region Firmware / machine info --------------------------------------------

function Test-ZinIsWinPE {
    Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'
}

function Get-ZinFirmwareType {
    # Returns 'UEFI' or 'BIOS'. In WinPE: PEFirmwareType (1 = BIOS, 2 = UEFI).
    try {
        $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType -ErrorAction Stop).PEFirmwareType
        if ($v -eq 2) { return 'UEFI' } else { return 'BIOS' }
    } catch { }
    if ($env:firmware_type) { if ($env:firmware_type -eq 'UEFI') { return 'UEFI' } else { return 'BIOS' } }
    try { $null = Confirm-SecureBootUEFI -ErrorAction Stop; return 'UEFI' } catch [System.PlatformNotSupportedException] { return 'BIOS' } catch { return 'UEFI' }
}

function Get-ZinSecureBootState {
    try { if (Confirm-SecureBootUEFI -ErrorAction Stop) { 'On' } else { 'Off' } } catch { 'Unsupported' }
}

function Get-ZinMachineInfo {
    # Collects identity + hardware summary used by ZinDriver, quick-install suggestions and reports.
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bb = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
    $csp = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue

    $manufacturer = if ($cs) { "$($cs.Manufacturer)".Trim() } else { '' }
    $model = if ($cs) { "$($cs.Model)".Trim() } else { '' }
    # Lenovo puts the friendly name in Win32_ComputerSystemProduct.Version, MTM in Model.
    $friendly = $model
    if ($manufacturer -match 'LENOVO' -and $csp -and $csp.Version) { $friendly = "$($csp.Version)".Trim() }
    $sku = ''
    if ($cs -and ($cs.PSObject.Properties.Name -contains 'SystemSKUNumber')) { $sku = "$($cs.SystemSKUNumber)".Trim() }

    $oemKey = ''
    try { $oemKey = (Get-CimInstance SoftwareLicensingService -ErrorAction Stop).OA3xOriginalProductKey } catch { }

    $disks = @()
    try {
        $disks = @(Get-Disk -ErrorAction Stop | Where-Object { $_.BusType -ne 'USB' } | ForEach-Object {
            [pscustomobject]@{ Number = $_.Number; Model = "$($_.FriendlyName)".Trim(); SizeGB = [math]::Round($_.Size / 1GB); Bus = "$($_.BusType)"; Style = "$($_.PartitionStyle)" }
        })
    } catch { }

    $batteries = @()
    try {
        $full = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop)
        $design = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop)
        for ($i = 0; $i -lt $full.Count; $i++) {
            $d = if ($i -lt $design.Count) { $design[$i].DesignedCapacity } else { 0 }
            $f = $full[$i].FullChargedCapacity
            $wear = if ($d -gt 0) { [math]::Round(100 - ($f * 100.0 / $d), 1) } else { $null }
            $batteries += [pscustomobject]@{ DesignmWh = $d; FullmWh = $f; WearPercent = $wear }
        }
    } catch { }

    $tpm = Get-ZinTpmVersion

    [pscustomobject]@{
        Manufacturer = $manufacturer
        Model        = $model
        FriendlyName = $friendly
        SKU          = $sku
        BaseBoard    = if ($bb) { "$($bb.Product)".Trim() } else { '' }
        MTM4         = if ($manufacturer -match 'LENOVO' -and $model.Length -ge 4) { $model.Substring(0, 4).ToUpper() } else { '' }
        Serial       = if ($bios) { "$($bios.SerialNumber)".Trim() } else { '' }
        BiosVersion  = if ($bios) { "$($bios.SMBIOSBIOSVersion)".Trim() } else { '' }
        CPU          = if ($cpu) { ("$($cpu.Name)" -replace '\s+', ' ').Trim() } else { '' }
        RamGB        = if ($cs) { [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) } else { 0 }
        Firmware     = Get-ZinFirmwareType
        SecureBoot   = Get-ZinSecureBootState
        TPM          = $tpm
        OemKey       = $oemKey
        Disks        = $disks
        Batteries    = $batteries
        OSCaption    = if ($os) { $os.Caption } else { '' }
    }
}

function Get-ZinTpmVersion {
    # Returns '2.0', '1.2' or '' (none/disabled).
    try {
        $t = Get-CimInstance -Namespace root\cimv2\Security\MicrosoftTpm -ClassName Win32_Tpm -ErrorAction Stop
        if (-not $t) { return '' }
        $spec = "$($t.SpecVersion)".Split(',')[0].Trim()
        return $spec
    } catch { return '' }
}

function Test-ZinWin11Ready {
    <#
      Rough Windows 11 hardware check used to suggest a preset (design 8.5).
      CPU rule: Intel Core gen >= 8 / Core Ultra / recent Xeon, AMD Ryzen >= 2000.
      This is a heuristic; the result is a suggestion, never a hard block.
    #>
    param([Parameter(Mandatory)]$Info)
    $reasons = New-Object System.Collections.Generic.List[string]
    if ($Info.Firmware -ne 'UEFI') { $reasons.Add('firmware') }
    if ($Info.TPM -notlike '2*') { $reasons.Add('tpm') }
    if ($Info.RamGB -lt 3.8) { $reasons.Add('ram') }
    if (-not (Test-ZinWin11Cpu $Info.CPU)) { $reasons.Add('cpu') }
    $sys = @($Info.Disks | Where-Object { $_.SizeGB -ge 64 })
    if ($Info.Disks.Count -gt 0 -and $sys.Count -eq 0) { $reasons.Add('disk') }
    [pscustomobject]@{ Ready = ($reasons.Count -eq 0); Reasons = $reasons.ToArray() }
}

function Test-ZinWin11Cpu {
    param([string]$Name)
    if (-not $Name) { return $false }
    if ($Name -match 'Core\(TM\) Ultra|Core Ultra') { return $true }
    if ($Name -match 'Intel.*Core.*i[3579]-(\d{4,5})') {
        $n = $Matches[1]
        # 5 digits (10510) or 4 digits starting with 1 (1065G7, 1235U) = gen 10+; otherwise first digit (8350U).
        $gen = if ($n.Length -eq 5 -or $n.StartsWith('1')) { [int]$n.Substring(0, 2) } else { [int]$n.Substring(0, 1) }
        return ($gen -ge 8)
    }
    if ($Name -match 'Intel.*Core.*\b([3579]) (\d{3})') { return $true }   # Core 3/5/7 1xx/2xx (2023+)
    if ($Name -match 'Ryzen.*\b(\d)(\d{3})') { return ([int]$Matches[1] -ge 2) }
    if ($Name -match 'Ryzen AI') { return $true }
    if ($Name -match 'Pentium.*(Gold|Silver) [6-9]\d{3}|Celeron.*N[45]\d{3}|Intel\(R\) N\d{2,3}') { return $true }
    $false
}

#endregion

#region Paths ---------------------------------------------------------------

function Expand-ZinOfflinePath {
    # Expands %ProgramFiles%-style variables against an OFFLINE Windows root (e.g. W:\).
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$WindowsRoot)
    $r = $WindowsRoot.TrimEnd('\')
    $map = @{
        '%ProgramFiles%'      = "$r\Program Files"
        '%ProgramFiles(x86)%' = "$r\Program Files (x86)"
        '%ProgramData%'       = "$r\ProgramData"
        '%SystemRoot%'        = "$r\Windows"
        '%WinDir%'            = "$r\Windows"
        '%SystemDrive%'       = $r
        '%Public%'            = "$r\Users\Public"
    }
    foreach ($k in $map.Keys) { $Path = $Path -ireplace [regex]::Escape($k), $map[$k] }
    $Path
}

function New-ZinShortcut {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target,
        [string]$Arguments = '',
        [string]$Icon = '',
        [string]$WorkingDirectory = ''
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath = $Target
    if ($Arguments) { $lnk.Arguments = $Arguments }
    $lnk.WorkingDirectory = if ($WorkingDirectory) { $WorkingDirectory } else { Split-Path -Parent $Target }
    if ($Icon) { $lnk.IconLocation = $Icon }
    $lnk.Save()
}

function Sync-ZinTime {
    param([string]$Server = 'time.windows.com')
    # Minimal SNTP client: PE usually has no w32time service.
    for ($try = 0; $try -lt 10; $try++) {
        try {
            $data = New-Object byte[] 48; $data[0] = 0x1B
            $udp = New-Object System.Net.Sockets.UdpClient
            $udp.Client.ReceiveTimeout = 3000
            $udp.Connect($Server, 123); [void]$udp.Send($data, 48)
            $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $resp = $udp.Receive([ref]$ep); $udp.Close()
            [uint64]$int = [BitConverter]::ToUInt32(@($resp[43], $resp[42], $resp[41], $resp[40]), 0)
            [uint64]$frac = [BitConverter]::ToUInt32(@($resp[47], $resp[46], $resp[45], $resp[44]), 0)
            $ms = $int * 1000 + ($frac * 1000) / 0x100000000
            $utc = (New-Object DateTime(1900, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).AddMilliseconds($ms)
            Set-Date -Date $utc.ToLocalTime() | Out-Null
            Write-ZinLog "Time synced from $Server : $($utc.ToLocalTime())"
            return $true
        } catch { Start-Sleep -Seconds 3 }
    }
    Write-ZinLog "Time sync failed ($Server)" 'WARN'
    $false
}

function Get-ZinVersion {
    param([string]$ZinData)
    foreach ($p in @('X:\ZinPE\version.txt', "$ZinData\ZinPE\version.txt", (Join-Path $PSScriptRoot '..\..\VERSION'))) {
        if ($p -and (Test-Path $p)) { return (Get-Content $p -TotalCount 1).Trim() }
    }
    'dev'
}

#endregion

Export-ModuleMember -Function *-Zin*
