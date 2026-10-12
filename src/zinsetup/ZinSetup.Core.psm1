# ZinSetup.Core.psm1 - Windows installation engine used by the ZinSetup GUI and CLI (design 8.3 / 8.5 / 8.7).
# No UI code here: every step reports through a -Progress scriptblock { param($Percent, $Message) }.
# ASCII-only on purpose (see ZinCommon.psm1).

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot '..\common\ZinCommon.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\zindriver\ZinDriver.psm1') -DisableNameChecking -ErrorAction Stop

$script:RecoveryGuid = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'

#region Sources --------------------------------------------------------------

function Get-ZinImageSource {
    # Lists ISO/WIM/ESD/SWM files in ZINDATA\ISO\Windows and ZINDATA\WIM.
    param([Parameter(Mandatory)][string]$ZinData)
    foreach ($dir in @('ISO\Windows', 'WIM')) {
        $p = Join-Path $ZinData $dir
        if (-not (Test-Path $p)) { continue }
        Get-ChildItem $p -File -Recurse -Include *.iso, *.wim, *.esd, *.swm |
            Where-Object { $_.Extension -ne '.swm' -or $_.BaseName -notmatch '\d$' } |
            ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; Path = $_.FullName; SizeGB = [math]::Round($_.Length / 1GB, 2); Kind = $_.Extension.TrimStart('.').ToLower() }
            }
    }
}

function Mount-ZinIso {
    # Mounts an ISO and returns @{ Root = 'E:\'; ImageFile = 'E:\sources\install.wim'; Sxs = 'E:\sources\sxs' }.
    param([Parameter(Mandatory)][string]$Path)
    $img = Get-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue
    if (-not $img -or -not $img.Attached) { $img = Mount-DiskImage -ImagePath $Path -PassThru -ErrorAction Stop }
    $vol = $null
    for ($i = 0; $i -lt 20 -and -not $vol; $i++) {
        $vol = $img | Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter | Select-Object -First 1
        if (-not $vol) { Start-Sleep -Milliseconds 500 }
    }
    if (-not $vol) { throw "ISO mounted but no drive letter: $Path" }
    $root = "$($vol.DriveLetter):\"
    $file = @('install.wim', 'install.esd', 'install.swm') | ForEach-Object { Join-Path $root "sources\$_" } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $file) { throw "No sources\install.wim|esd|swm in $Path" }
    Write-ZinLog "ISO mounted: $Path -> $root ($file)"
    @{ Root = $root; ImageFile = $file; Sxs = (Join-Path $root 'sources\sxs') }
}

function Dismount-ZinIso {
    param([Parameter(Mandatory)][string]$Path)
    try { Dismount-DiskImage -ImagePath $Path -ErrorAction Stop | Out-Null; Write-ZinLog "ISO dismounted: $Path" } catch { }
}

function Resolve-ZinImageFile {
    # Returns @{ ImageFile; Sxs; Iso } for an ISO or a WIM/ESD/SWM path.
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -like '*.iso') {
        $m = Mount-ZinIso $Path
        return @{ ImageFile = $m.ImageFile; Sxs = $m.Sxs; Iso = $Path }
    }
    $sxs = Join-Path (Split-Path -Parent $Path) 'sxs'
    @{ ImageFile = $Path; Sxs = $(if (Test-Path $sxs) { $sxs } else { '' }); Iso = '' }
}

function Get-ZinImageEdition {
    # Parses "dism /Get-WimInfo" into objects { Index; Name; Description; SizeGB; Os }.
    param([Parameter(Mandatory)][string]$ImageFile)
    $out = & dism.exe /English /Get-WimInfo "/WimFile:$ImageFile" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "dism /Get-WimInfo failed ($LASTEXITCODE): $($out | Select-Object -Last 3)" }
    $list = New-Object System.Collections.Generic.List[object]
    $cur = $null
    foreach ($l in $out) {
        $s = "$l"
        if ($s -match '^Index\s*:\s*(\d+)') {
            if ($cur) { $list.Add([pscustomobject]$cur) }
            $cur = [ordered]@{ Index = [int]$Matches[1]; Name = ''; Description = ''; SizeGB = 0; Os = 'win10' }
        } elseif ($cur -and $s -match '^Name\s*:\s*(.+)$') {
            $cur.Name = $Matches[1].Trim()
            if ($cur.Name -match 'Windows 11') { $cur.Os = 'win11' }
        } elseif ($cur -and $s -match '^Description\s*:\s*(.+)$') {
            $cur.Description = $Matches[1].Trim()
        } elseif ($cur -and $s -match '^Size\s*:\s*([\d,\.]+)\s*bytes') {
            $cur.SizeGB = [math]::Round(([double]($Matches[1] -replace '[,\.]', '')) / 1GB, 1)
        }
    }
    if ($cur) { $list.Add([pscustomobject]$cur) }
    , $list.ToArray()
}

#endregion

#region Disks ----------------------------------------------------------------

function Get-ZinBootUsbDiskNumber {
    $zd = Find-ZinData
    if (-not $zd) { return -1 }
    try { return (Get-Partition -DriveLetter $zd.TrimEnd(':') -ErrorAction Stop).DiskNumber } catch { return -1 }
}

function Get-ZinTargetDisk {
    # Internal disks that can receive Windows. The ZinWinPE USB is always excluded.
    param([switch]$IncludeUsb)
    $usb = Get-ZinBootUsbDiskNumber
    foreach ($d in Get-Disk | Sort-Object Number) {
        if ($d.Number -eq $usb) { continue }
        if (-not $IncludeUsb -and "$($d.BusType)" -eq 'USB') { continue }
        if ($d.Size -lt 20GB) { continue }
        $parts = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | ForEach-Object {
            $v = $null
            try { $v = $_ | Get-Volume -ErrorAction Stop } catch { }
            [pscustomobject]@{
                PartitionNumber = $_.PartitionNumber
                Letter          = "$($_.DriveLetter)".Trim()
                SizeGB          = [math]::Round($_.Size / 1GB, 1)
                Type            = "$($_.Type)"
                Label           = if ($v) { $v.FileSystemLabel } else { '' }
                FileSystem      = if ($v) { $v.FileSystem } else { '' }
                HasWindows      = ($_.DriveLetter -and (Test-Path "$($_.DriveLetter):\Windows\System32\config\SYSTEM"))
            }
        })
        [pscustomobject]@{
            Number     = $d.Number
            Model      = "$($d.FriendlyName)".Trim()
            SizeGB     = [math]::Round($d.Size / 1GB)
            Bus        = "$($d.BusType)"
            Style      = "$($d.PartitionStyle)"
            Partitions = $parts
        }
    }
}

function Get-ZinFreeLetter {
    param([string[]]$Preferred = @('W', 'S', 'R'), [string[]]$Exclude = @())
    $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpper() }) + $Exclude
    foreach ($p in $Preferred) { if ($used -notcontains $p) { return $p } }
    foreach ($c in [char[]]([int][char]'Z'..[int][char]'D')) { if ($used -notcontains "$c") { return "$c" } }
    throw 'No free drive letter'
}

function New-ZinPartitionScript {
    <#
      Builds the diskpart script for "wipe & auto-partition" (design 8.3 step 3):
        GPT: EFI 260 MB FAT32 | MSR 16 MB | Windows | Recovery 1 GB
        MBR: System Reserved 500 MB NTFS active | Windows
      Pure function (no side effects) so it can be unit-tested.
    #>
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][ValidateSet('GPT', 'MBR')][string]$Style,
        [Parameter(Mandatory)][string]$WinLetter,
        [Parameter(Mandatory)][string]$SysLetter,
        [string]$RecLetter = 'R',
        [int]$EfiMB = 260,
        [int]$RecoveryMB = 1024
    )
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add("select disk $DiskNumber")
    $l.Add('clean')
    if ($Style -eq 'GPT') {
        $l.Add('convert gpt')
        $l.Add("create partition efi size=$EfiMB")
        $l.Add('format quick fs=fat32 label="System"')
        $l.Add("assign letter=$SysLetter")
        $l.Add('create partition msr size=16')
        $l.Add('create partition primary')
        if ($RecoveryMB -gt 0) { $l.Add("shrink minimum=$RecoveryMB") }
        $l.Add('format quick fs=ntfs label="Windows"')
        $l.Add("assign letter=$WinLetter")
        if ($RecoveryMB -gt 0) {
            $l.Add('create partition primary')
            $l.Add('format quick fs=ntfs label="Recovery"')
            $l.Add("assign letter=$RecLetter")
            $l.Add("set id=$($script:RecoveryGuid)")
            $l.Add('gpt attributes=0x8000000000000001')
        }
    } else {
        $l.Add('convert mbr')
        $l.Add('create partition primary size=500')
        $l.Add('format quick fs=ntfs label="System Reserved"')
        $l.Add("assign letter=$SysLetter")
        $l.Add('active')
        $l.Add('create partition primary')
        $l.Add('format quick fs=ntfs label="Windows"')
        $l.Add("assign letter=$WinLetter")
    }
    $l.Add('exit')
    , $l.ToArray()
}

function Initialize-ZinTargetDisk {
    <#
      Prepares the target and returns @{ Win = 'W:'; Sys = 'S:'; Rec = 'R:' or ''; Style; Temp = @(letters to remove) }.
      -Mode Wipe     : clean disk + auto layout (style from -Style, default by firmware)
      -Mode Existing : format only partition -PartitionNumber, reuse the disk's EFI/active partition
    #>
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [ValidateSet('Wipe', 'Existing')][string]$Mode = 'Wipe',
        [int]$PartitionNumber = 0,
        [ValidateSet('Auto', 'GPT', 'MBR')][string]$Style = 'Auto',
        [switch]$NoFormat
    )
    if ($DiskNumber -eq (Get-ZinBootUsbDiskNumber)) { throw "Refusing to touch the ZinWinPE USB (disk $DiskNumber)" }
    $w = Get-ZinFreeLetter -Preferred @('W')
    $s = Get-ZinFreeLetter -Preferred @('S') -Exclude @($w)
    $r = Get-ZinFreeLetter -Preferred @('R') -Exclude @($w, $s)

    if ($Mode -eq 'Wipe') {
        if ($Style -eq 'Auto') { $Style = if ((Get-ZinFirmwareType) -eq 'UEFI') { 'GPT' } else { 'MBR' } }
        $script = New-ZinPartitionScript -DiskNumber $DiskNumber -Style $Style -WinLetter $w -SysLetter $s -RecLetter $r
        if (-not (Invoke-ZinDiskpart -Lines $script)) { throw "diskpart failed on disk $DiskNumber" }
        $rec = if ($Style -eq 'GPT') { "$($r):" } else { '' }
        return @{ Win = "$($w):"; Sys = "$($s):"; Rec = $rec; Style = $Style; Temp = @($s, $r) }
    }

    # Existing partition
    $disk = Get-Disk -Number $DiskNumber
    $styleNow = "$($disk.PartitionStyle)"
    $parts = @(Get-Partition -DiskNumber $DiskNumber)
    $target = $parts | Where-Object { $_.PartitionNumber -eq $PartitionNumber } | Select-Object -First 1
    if (-not $target) { throw "Partition $PartitionNumber not found on disk $DiskNumber" }
    $lines = @("select disk $DiskNumber", "select partition $PartitionNumber")
    if (-not $NoFormat) { $lines += 'format quick fs=ntfs label="Windows"' }
    if ($target.DriveLetter -and "$($target.DriveLetter)".Trim()) { $lines += 'remove noerr' }
    $lines += "assign letter=$w"

    $sysPart = $null
    if ($styleNow -eq 'GPT') {
        $sysPart = $parts | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } | Select-Object -First 1
        if (-not $sysPart) { throw "GPT disk $DiskNumber has no EFI partition - use Wipe mode" }
    } else {
        $sysPart = $parts | Where-Object { $_.IsActive } | Select-Object -First 1
    }
    $temp = @()
    if ($sysPart -and $sysPart.PartitionNumber -ne $PartitionNumber) {
        if ($sysPart.DriveLetter -and "$($sysPart.DriveLetter)".Trim()) { $s = "$($sysPart.DriveLetter)" }
        else { $lines += @("select partition $($sysPart.PartitionNumber)", "assign letter=$s"); $temp += $s }
    } else {
        # MBR without active partition: Windows partition becomes the system partition.
        $lines += @("select partition $PartitionNumber", 'active')
        $s = $w
    }
    $lines += 'exit'
    if (-not (Invoke-ZinDiskpart -Lines $lines)) { throw "diskpart failed on disk $DiskNumber partition $PartitionNumber" }
    @{ Win = "$($w):"; Sys = "$($s):"; Rec = ''; Style = $styleNow; Temp = $temp }
}

function Remove-ZinTempLetters {
    param([string[]]$Letters)
    foreach ($l in $Letters) {
        if (-not $l -or -not (Test-Path "$($l):\")) { continue }
        Invoke-ZinDiskpart -Lines @("select volume $l", 'remove noerr', 'exit') | Out-Null
    }
}

#endregion

#region Apply ----------------------------------------------------------------

function Invoke-ZinProgressProcess {
    # Runs a console tool, parses "NN%" / "NN.N%" from stdout (\r-separated) and reports it.
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string]$Arguments, [scriptblock]$OnPercent)
    Write-ZinLog "RUN: `"$FilePath`" $Arguments"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath; $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $sb = New-Object System.Text.StringBuilder
    $last = -1
    $tail = New-Object System.Collections.Generic.Queue[string]
    while (($c = $p.StandardOutput.Read()) -ge 0) {
        $ch = [char]$c
        if ($ch -eq "`r" -or $ch -eq "`n") {
            $line = $sb.ToString(); [void]$sb.Clear()
            if (-not $line) { continue }
            if ($line -match '(\d{1,3})(?:\.\d+)?\s*%') {
                $pct = [int]$Matches[1]
                if ($pct -ne $last -and $OnPercent) { $last = $pct; & $OnPercent $pct }
            } else {
                $tail.Enqueue($line); if ($tail.Count -gt 20) { [void]$tail.Dequeue() }
            }
        } else { [void]$sb.Append($ch) }
    }
    $p.WaitForExit()
    $err = $errTask.Result
    if ($p.ExitCode -ne 0) {
        foreach ($t in $tail) { Write-ZinLog "  > $t" 'WARN' }
        if ($err) { Write-ZinLog "  stderr: $err" 'WARN' }
    }
    Write-ZinLog "EXIT: $($p.ExitCode)"
    $p.ExitCode
}

function Expand-ZinWindowsImage {
    # Applies index $Index to $ApplyDir. wimlib-imagex (multi-threaded, design 8.5) first, dism as fallback.
    param([Parameter(Mandatory)][string]$ImageFile, [Parameter(Mandatory)][int]$Index, [Parameter(Mandatory)][string]$ApplyDir, [scriptblock]$OnPercent)
    $dir = $ApplyDir.TrimEnd('\') + '\'
    $wimlib = Find-ZinTool 'wimlib-imagex.exe'
    if ($wimlib) {
        $ref = ''
        if ($ImageFile -like '*.swm') { $ref = " --ref=`"$([IO.Path]::Combine((Split-Path $ImageFile), [IO.Path]::GetFileNameWithoutExtension($ImageFile) + '*.swm'))`"" }
        $code = Invoke-ZinProgressProcess -FilePath $wimlib -Arguments "apply `"$ImageFile`" $Index `"$dir`"$ref" -OnPercent $OnPercent
        if ($code -eq 0) { return }
        Write-ZinLog "wimlib-imagex failed ($code), falling back to dism" 'WARN'
    }
    $swm = ''
    if ($ImageFile -like '*.swm') { $swm = " /SWMFile:`"$([IO.Path]::Combine((Split-Path $ImageFile), [IO.Path]::GetFileNameWithoutExtension($ImageFile) + '*.swm'))`"" }
    $code = Invoke-ZinProgressProcess -FilePath 'dism.exe' -Arguments "/English /Apply-Image /ImageFile:`"$ImageFile`" /Index:$Index /ApplyDir:$dir$swm" -OnPercent $OnPercent
    if ($code -ne 0) { throw "Apply image failed (dism exit $code)" }
}

function Set-ZinBootFiles {
    param([Parameter(Mandatory)][string]$WinRoot, [Parameter(Mandatory)][string]$SysRoot, [Parameter(Mandatory)][string]$Style, [string]$Locale = 'en-US')
    $fw = Get-ZinFirmwareType
    $flag = if ($Style -eq 'GPT') { 'UEFI' } elseif ($fw -eq 'UEFI') { 'ALL' } else { 'BIOS' }
    $code = Invoke-ZinProcess -FilePath 'bcdboot.exe' -ArgumentList "$($WinRoot.TrimEnd('\'))\Windows /s $($SysRoot.TrimEnd('\')) /f $flag /l $Locale" -Hidden
    if ($code -ne 0) { throw "bcdboot failed ($code)" }
    if ($flag -ne 'UEFI') { Invoke-ZinProcess -FilePath 'bootsect.exe' -ArgumentList "/nt60 $($SysRoot.TrimEnd('\')) /mbr /force" -Hidden | Out-Null }
}

function Set-ZinRecovery {
    # Moves WinRE to the Recovery partition (GPT layout) and registers it offline.
    param([Parameter(Mandatory)][string]$WinRoot, [string]$RecRoot)
    if (-not $RecRoot) { return }
    $winre = Join-Path $WinRoot 'Windows\System32\Recovery\Winre.wim'
    if (-not (Test-Path $winre)) { Write-ZinLog 'Winre.wim not in image - recovery partition left empty' 'WARN'; return }
    $dest = Join-Path $RecRoot 'Recovery\WindowsRE'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    & attrib.exe -h -s $winre 2>&1 | Out-Null
    Copy-Item $winre $dest -Force
    $reagent = Join-Path $WinRoot 'Windows\System32\reagentc.exe'
    Invoke-ZinProcess -FilePath $reagent -ArgumentList "/setreimage /path $dest /target $($WinRoot.TrimEnd('\'))\Windows" -Hidden | Out-Null
}

function Enable-ZinNetFx3 {
    param([Parameter(Mandatory)][string]$WinRoot, [string]$Sxs)
    if (-not $Sxs -or -not (Test-Path $Sxs)) { Write-ZinLog 'NetFx3: no sources\sxs available - deferred to ZinPost (online)' 'WARN'; return $false }
    $code = Invoke-ZinProcess -FilePath 'dism.exe' -ArgumentList "/English /Image:$($WinRoot.TrimEnd('\'))\ /Enable-Feature /FeatureName:NetFx3 /All /Source:`"$Sxs`" /LimitAccess" -Hidden
    $code -eq 0
}

#endregion

#region Offline registry / unattend -----------------------------------------

function Invoke-ZinOfflineHive {
    # Loads an offline hive (SOFTWARE/SYSTEM/DEFAULT), runs $Action with the mount key name, unloads.
    param([Parameter(Mandatory)][string]$WinRoot, [Parameter(Mandatory)][ValidateSet('SOFTWARE', 'SYSTEM', 'DEFAULT')][string]$Hive, [Parameter(Mandatory)][scriptblock]$Action)
    $key = "ZIN_$Hive"
    $file = Join-Path $WinRoot "Windows\System32\config\$Hive"
    & reg.exe load "HKLM\$key" $file 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg load failed for $file" }
    try { & $Action "HKLM\$key" }
    finally {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        for ($i = 0; $i -lt 5; $i++) { & reg.exe unload "HKLM\$key" 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep -Milliseconds 500 }
    }
}

function Set-ZinOfflineTweaks {
    param([Parameter(Mandatory)][string]$WinRoot, [Parameter(Mandatory)]$Options)
    Invoke-ZinOfflineHive -WinRoot $WinRoot -Hive SOFTWARE -Action {
        param($k)
        if ($Options.bypassNRO) { & reg.exe add "$k\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f | Out-Null }
    }
    Invoke-ZinOfflineHive -WinRoot $WinRoot -Hive SYSTEM -Action {
        param($k)
        if ($Options.preventDeviceEncryption) {
            & reg.exe add "$k\ControlSet001\Control\BitLocker" /v PreventDeviceEncryption /t REG_DWORD /d 1 /f | Out-Null
        }
        if ($Options.win11Bypass) {
            # Lets feature updates install on unsupported hardware (Microsoft documented key) + LabConfig for setup.exe.
            & reg.exe add "$k\Setup\MoSetup" /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f | Out-Null
            foreach ($n in @('BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck', 'BypassCPUCheck')) {
                & reg.exe add "$k\Setup\LabConfig" /v $n /t REG_DWORD /d 1 /f | Out-Null
            }
        }
    }
}

function ConvertTo-ZinXmlText([string]$s) { [System.Security.SecurityElement]::Escape($s) }

function New-ZinUnattendXml {
    <#
      Fills the unattend template (ZinPE\Unattend\zin-unattend.xml) with preset options.
      Tokens: {{COMPUTERNAME}} {{TIMEZONE}} {{INPUT_LOCALE}} {{SYSTEM_LOCALE}} {{UI_LANGUAGE}} {{USER_LOCALE}}
              {{USERNAME}} {{PASSWORD}} {{AUTOLOGON}} {{FIRSTLOGON}} {{HIDE_ONLINE}} {{PREVENT_ENCRYPTION}}
    #>
    param([Parameter(Mandatory)][string]$Template, [Parameter(Mandatory)]$Options, [string[]]$FirstLogonCommands = @())
    $u = $Options
    $user = if ($u.localUser) { $u.localUser } else { 'User' }
    $pass = if ($u.PSObject.Properties.Name -contains 'password' -and $u.password) { $u.password } else { '' }
    $cmds = New-Object System.Text.StringBuilder
    $order = 1
    foreach ($c in $FirstLogonCommands) {
        [void]$cmds.AppendLine("        <SynchronousCommand wcm:action=`"add`"><Order>$order</Order><CommandLine>$(ConvertTo-ZinXmlText $c)</CommandLine><RequiresUserInput>false</RequiresUserInput></SynchronousCommand>")
        $order++
    }
    $autoLogon = ''
    if ($u.autoLogon) {
        $autoLogon = "<AutoLogon><Enabled>true</Enabled><LogonCount>1</LogonCount><Username>$(ConvertTo-ZinXmlText $user)</Username><Password><Value>$(ConvertTo-ZinXmlText $pass)</Value><PlainText>true</PlainText></Password></AutoLogon>"
    }
    $map = @{
        '{{COMPUTERNAME}}'       = $(if ($u.computerName) { ConvertTo-ZinXmlText $u.computerName } else { '*' })
        '{{TIMEZONE}}'           = ConvertTo-ZinXmlText $u.timeZone
        '{{INPUT_LOCALE}}'       = ConvertTo-ZinXmlText $u.inputLocale
        '{{SYSTEM_LOCALE}}'      = ConvertTo-ZinXmlText $u.systemLocale
        '{{UI_LANGUAGE}}'        = ConvertTo-ZinXmlText $u.uiLanguage
        '{{USER_LOCALE}}'        = ConvertTo-ZinXmlText $u.userLocale
        '{{USERNAME}}'           = ConvertTo-ZinXmlText $user
        '{{PASSWORD}}'           = ConvertTo-ZinXmlText $pass
        '{{AUTOLOGON}}'          = $autoLogon
        '{{FIRSTLOGON}}'         = $(if ($cmds.Length -gt 0) { "<FirstLogonCommands>`r`n" + $cmds.ToString().TrimEnd() + "`r`n      </FirstLogonCommands>" } else { '' })
        '{{HIDE_ONLINE}}'        = $(if ($u.bypassNRO) { 'true' } else { 'false' })
        '{{PREVENT_ENCRYPTION}}' = $(if ($u.preventDeviceEncryption) { 'true' } else { 'false' })
    }
    $xml = $Template
    foreach ($k in $map.Keys) { $xml = $xml.Replace($k, [string]$map[$k]) }
    [xml]$xml | Out-Null   # throws if the result is not well-formed
    $xml
}

#endregion

#region Apps (ZinPost staging, design 8.7.2) ---------------------------------

function Get-ZinAppCatalog {
    # Reads every ZinPE\Apps\<App>\app.ini. Returns objects with the manifest fields + Folder.
    param([Parameter(Mandatory)][string]$AppsRoot)
    if (-not (Test-Path $AppsRoot)) { return @() }
    foreach ($ini in Get-ChildItem $AppsRoot -Filter app.ini -Recurse -File) {
        $m = Read-ZinIni $ini.FullName
        if (-not $m.Contains('App')) { continue }
        $a = [ordered]@{ Id = $ini.Directory.Name; Folder = $ini.DirectoryName }
        foreach ($k in $m['App'].Keys) { $a[$k] = $m['App'][$k] }
        foreach ($k in @('Name', 'Category', 'Target', 'Type', 'Installer', 'Args', 'RunAs', 'DetectPath', 'Default', 'Winget', 'Verify', 'PortableDir', 'Startup', 'Desktop', 'Exe')) {
            if (-not $a.Contains($k)) { $a[$k] = '' }
        }
        [pscustomobject]$a
    }
}

function Get-ZinFontName {
    param([string]$Path)
    try {
        Add-Type -AssemblyName System.Drawing
        $pfc = New-Object System.Drawing.Text.PrivateFontCollection
        $pfc.AddFontFile($Path)
        $n = $pfc.Families[0].Name
        $pfc.Dispose()
        return $n
    } catch { return [IO.Path]::GetFileNameWithoutExtension($Path) }
}

function Install-ZinOfflineApp {
    # RunAs=pe-offline items (design 8.7.4): fonts, portable apps, NetFx3. Returns $true on success.
    param([Parameter(Mandatory)]$App, [Parameter(Mandatory)][string]$WinRoot, [string]$Sxs)
    switch ($App.Type) {
        'font' {
            $files = @(Get-ChildItem $App.Folder -Recurse -File -Include *.ttf, *.otf, *.ttc)
            if ($files.Count -eq 0) { Write-ZinLog "No font files in $($App.Folder)" 'WARN'; return $false }
            $fontsDir = Join-Path $WinRoot 'Windows\Fonts'
            $entries = @{}
            foreach ($f in $files) {
                Copy-Item $f.FullName $fontsDir -Force
                $suffix = if ($f.Extension -eq '.otf') { ' (OpenType)' } else { ' (TrueType)' }
                $entries[(Get-ZinFontName $f.FullName) + $suffix] = $f.Name
            }
            Invoke-ZinOfflineHive -WinRoot $WinRoot -Hive SOFTWARE -Action {
                param($k)
                foreach ($n in $entries.Keys) { & reg.exe add "$k\Microsoft\Windows NT\CurrentVersion\Fonts" /v $n /t REG_SZ /d $entries[$n] /f | Out-Null }
            }
            Write-ZinLog "Fonts installed offline: $($files.Count)"
            return $true
        }
        'portable' {
            $dirOnline = if ($App.PortableDir) { $App.PortableDir } elseif ($App.DetectPath) { Split-Path -Parent $App.DetectPath } else { "%ProgramFiles%\$($App.Id)" }
            $dest = Expand-ZinOfflinePath -Path $dirOnline -WindowsRoot $WinRoot
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            Get-ChildItem $App.Folder -Force | Where-Object { $_.Name -ne 'app.ini' } | Copy-Item -Destination $dest -Recurse -Force
            $exeName = if ($App.Exe) { $App.Exe } elseif ($App.DetectPath) { Split-Path -Leaf $App.DetectPath } else { '' }
            if ($exeName) {
                $target = (Expand-ZinOfflinePath -Path $dirOnline -WindowsRoot 'C:\') + "\$exeName"
                $title = ($App.Name -replace '\s*\(.*\)$', '')
                if ($App.Startup -ne '0') { New-ZinShortcut -Path (Join-Path $WinRoot "ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\$title.lnk") -Target $target }
                if ($App.Desktop -ne '0') { New-ZinShortcut -Path (Join-Path $WinRoot "Users\Public\Desktop\$title.lnk") -Target $target }
                New-ZinShortcut -Path (Join-Path $WinRoot "ProgramData\Microsoft\Windows\Start Menu\Programs\$title.lnk") -Target $target
            }
            $reg = Join-Path $App.Folder 'defaults.reg'
            if (Test-Path $reg) { Import-ZinDefaultUserReg -WinRoot $WinRoot -RegFile $reg }
            return $true
        }
        'feature' { return (Enable-ZinNetFx3 -WinRoot $WinRoot -Sxs $Sxs) }
        default { Write-ZinLog "pe-offline not supported for Type=$($App.Type) ($($App.Id))" 'WARN'; return $false }
    }
}

function Import-ZinDefaultUserReg {
    # Imports a .reg written against HKEY_CURRENT_USER into the offline Default user hive (NTUSER.DAT).
    param([Parameter(Mandatory)][string]$WinRoot, [Parameter(Mandatory)][string]$RegFile)
    $hive = Join-Path $WinRoot 'Users\Default\NTUSER.DAT'
    & reg.exe load HKU\ZIN_DEFAULT $hive 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-ZinLog "Cannot load $hive" 'WARN'; return }
    try {
        $text = [IO.File]::ReadAllText($RegFile) -replace 'HKEY_CURRENT_USER', 'HKEY_USERS\ZIN_DEFAULT'
        $tmp = Join-Path $env:TEMP 'zin-default.reg'
        [IO.File]::WriteAllText($tmp, $text, [System.Text.Encoding]::Unicode)
        & reg.exe import $tmp 2>&1 | Out-Null
        Write-ZinLog "Default user registry imported: $RegFile"
    } finally {
        [gc]::Collect(); & reg.exe unload HKU\ZIN_DEFAULT 2>&1 | Out-Null
    }
}

function Copy-ZinPostPayload {
    <#
      Stages ZinPost into W:\ZinPost (design 8.7.2):
        - app folders for RunAs=system|user (+ deferred pe-offline items that failed)
        - ZinPost.ps1 + ZinCommon.psm1, zinpost.json (ordered app list + options)
        - SetupComplete.cmd (system phase). Returns the FirstLogonCommands to add to unattend.
    #>
    param(
        [Parameter(Mandatory)][string]$WinRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Apps,
        [Parameter(Mandatory)][string]$ScriptsRoot,
        [string]$ZinDataSerial = '',
        [bool]$WingetUpgrade = $false,
        [bool]$RunSdio = $true
    )
    $post = Join-Path $WinRoot 'ZinPost'
    New-Item -ItemType Directory -Path "$post\Apps" -Force | Out-Null
    Copy-Item (Join-Path $ScriptsRoot 'zinpost\ZinPost.ps1') $post -Force
    Copy-Item (Join-Path $ScriptsRoot 'common\ZinCommon.psm1') $post -Force
    $list = @()
    foreach ($a in $Apps) {
        $dest = Join-Path "$post\Apps" $a.Id
        Copy-Item $a.Folder $dest -Recurse -Force
        $list += [ordered]@{ Id = $a.Id; Name = $a.Name; Type = $a.Type; Installer = $a.Installer; Args = $a.Args; RunAs = $a.RunAs; DetectPath = $a.DetectPath; Winget = $a.Winget }
        Write-ZinLog "ZinPost staged: $($a.Id) ($($a.RunAs))"
    }
    $cfg = [ordered]@{ created = (Get-Date).ToString('s'); usbTag = $ZinDataSerial; wingetUpgrade = $WingetUpgrade; runSdio = $RunSdio; apps = $list }
    Write-ZinUtf8File -Path "$post\zinpost.json" -Content (ConvertTo-Json -InputObject $cfg -Depth 5)

    $scriptsDir = Join-Path $WinRoot 'Windows\Setup\Scripts'
    New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
    $sc = Join-Path $scriptsDir 'SetupComplete.cmd'
    $line = 'if exist "%SystemDrive%\ZinPost\ZinPost.ps1" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SystemDrive%\ZinPost\ZinPost.ps1" -Phase System'
    $existing = if (Test-Path $sc) { [IO.File]::ReadAllText($sc) } else { "@echo off`r`n" }
    if ($existing -notmatch 'ZinPost\.ps1') { Write-ZinUtf8File -Path $sc -Content ($existing.TrimEnd() + "`r`n" + $line + "`r`n") }

    # FirstLogonCommands: system phase again (no-op if SetupComplete already ran; OEM-key installs skip SetupComplete,
    # design 8.7.3) then the per-user phase.
    @(
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ZinPost\ZinPost.ps1 -Phase System',
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ZinPost\ZinPost.ps1 -Phase User'
    )
}

#endregion

#region Presets --------------------------------------------------------------

function Get-ZinPreset {
    param([Parameter(Mandatory)][string]$PresetDir)
    if (-not (Test-Path $PresetDir)) { return @() }
    foreach ($f in Get-ChildItem $PresetDir -Filter *.json -File | Sort-Object Name) {
        try { $p = Read-ZinJson $f.FullName; $p | Add-Member -NotePropertyName File -NotePropertyValue $f.FullName -Force; $p }
        catch { Write-ZinLog "Bad preset $($f.Name): $($_.Exception.Message)" 'WARN' }
    }
}

function Get-ZinPresetTitle {
    param([Parameter(Mandatory)]$Preset, [string]$Lang = 'vi-VN')
    if ($Preset.PSObject.Properties.Name -contains 'title' -and $Preset.title) {
        $t = $Preset.title.PSObject.Properties | Where-Object Name -eq $Lang | Select-Object -First 1
        if ($t) { return $t.Value }
        return ($Preset.title.PSObject.Properties | Select-Object -First 1).Value
    }
    $Preset.name
}

function Select-ZinSuggestedPreset {
    # Suggests the first preset that fits the machine (design 8.5 "auto by machine").
    param([Parameter(Mandatory)][object[]]$Presets, [Parameter(Mandatory)]$Readiness)
    foreach ($p in $Presets) {
        $req = ($p.PSObject.Properties.Name -contains 'requiresWin11') -and $p.requiresWin11
        if ($req -and -not $Readiness.Ready) { continue }
        return $p
    }
    $Presets | Select-Object -First 1
}

function Resolve-ZinPresetImage {
    # Resolves preset.image (relative to ZINDATA, wildcards allowed, newest file wins) and preset.edition (name pattern) to an index.
    param([Parameter(Mandatory)]$Preset, [Parameter(Mandatory)][string]$ZinData)
    $pattern = Join-Path $ZinData $Preset.image
    $file = Get-ChildItem $pattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $file) { throw "Preset '$($Preset.name)': image not found ($pattern)" }
    @{ Path = $file.FullName; Edition = $Preset.edition }
}

#endregion

#region Report ---------------------------------------------------------------

function Write-ZinReport {
    param([Parameter(Mandatory)]$Info, [Parameter(Mandatory)]$Result, [string]$ZinData, [string]$WinRoot)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('==================== ZinWinPE - Installation report ====================')
    $lines.Add(('Date        : {0:yyyy-MM-dd HH:mm}' -f (Get-Date)))
    $lines.Add("Machine     : $($Info.Manufacturer) $($Info.FriendlyName) ($($Info.Model))")
    $lines.Add("Serial      : $($Info.Serial)    BIOS: $($Info.BiosVersion)")
    $lines.Add("CPU / RAM   : $($Info.CPU) / $($Info.RamGB) GB")
    $lines.Add("Firmware    : $($Info.Firmware), Secure Boot $($Info.SecureBoot), TPM $($Info.TPM)")
    foreach ($d in $Info.Disks) { $lines.Add("Disk        : #$($d.Number) $($d.Model) $($d.SizeGB) GB $($d.Bus)") }
    foreach ($b in $Info.Batteries) { $lines.Add("Battery     : design $($b.DesignmWh) mWh, full $($b.FullmWh) mWh, wear $($b.WearPercent)%") }
    if ($Info.OemKey) { $lines.Add('OEM key     : present in firmware (MSDM) - Windows activates automatically') }
    $lines.Add('')
    $lines.Add("Preset      : $($Result.Preset)")
    $lines.Add("Image       : $($Result.Image) [index $($Result.Index)] $($Result.Edition)")
    $lines.Add("Target      : disk $($Result.Disk) ($($Result.Style)), mode $($Result.Mode)")
    $lines.Add("Drivers     : $($Result.DriverSource) $($Result.DriverPath)")
    foreach ($m in @($Result.MissingDrivers)) { $lines.Add("  missing   : $m") }
    $lines.Add("Apps        : $(@($Result.Apps) -join ', ')")
    foreach ($w in @($Result.Warnings)) { $lines.Add("WARNING     : $w") }
    $lines.Add(("Duration    : {0:mm\:ss}" -f $Result.Duration))
    $lines.Add("Status      : $($Result.Status)")
    $text = $lines -join "`r`n"
    $paths = @()
    if ($ZinData) {
        $serial = if ($Info.Serial) { $Info.Serial -replace '[^\w\-]', '_' } else { 'NOSERIAL' }
        $p = Join-Path $ZinData ("Reports\{0}_{1:yyyyMMdd-HHmm}.txt" -f $serial, (Get-Date))
        try { Write-ZinUtf8File -Path $p -Content $text; $paths += $p } catch { Write-ZinLog "Cannot write report on USB: $($_.Exception.Message)" 'WARN' }
    }
    if ($WinRoot -and (Test-Path (Join-Path $WinRoot 'ZinPost'))) {
        $p = Join-Path $WinRoot 'ZinPost\report.txt'; Write-ZinUtf8File -Path $p -Content $text; $paths += $p
    }
    $paths
}

#endregion

#region Orchestration --------------------------------------------------------

function Invoke-ZinInstall {
    <#
      Full pipeline (design 8.3). $Plan keys:
        ImagePath, Index | Edition, DiskNumber, Mode (Wipe|Existing), PartitionNumber, Style (Auto|GPT|MBR),
        Unattend (object or $null), Apps (Id list), Drivers (bool), NetFx3 (bool), Os (win10|win11|''),
        Preset (name), WingetUpgrade (bool), RunSdio (bool), Locale
      $Progress: scriptblock { param([int]$Percent, [string]$Message) }
    #>
    param([Parameter(Mandatory)][hashtable]$Plan, [scriptblock]$Progress = { param($p, $m) })
    $t0 = Get-Date
    $zinData = Find-ZinData
    $scriptsRoot = Split-Path -Parent $PSScriptRoot
    $info = Get-ZinMachineInfo
    $res = [ordered]@{
        Preset = $Plan.Preset; Image = $Plan.ImagePath; Index = 0; Edition = ''; Disk = $Plan.DiskNumber; Style = ''; Mode = $Plan.Mode
        DriverSource = 'none'; DriverPath = ''; MissingDrivers = @(); Apps = @(); Warnings = New-Object System.Collections.Generic.List[string]
        Status = 'FAILED'; Duration = [timespan]::Zero; Reports = @()
    }
    $src = $null; $layout = $null
    try {
        & $Progress 1 'source'
        $src = Resolve-ZinImageFile $Plan.ImagePath
        $editions = Get-ZinImageEdition $src.ImageFile
        $ed = $null
        if ($Plan.ContainsKey('Index') -and $Plan.Index) { $ed = $editions | Where-Object Index -eq $Plan.Index | Select-Object -First 1 }
        elseif ($Plan.Edition) { $ed = $editions | Where-Object { $_.Name -like $Plan.Edition } | Select-Object -First 1 }
        if (-not $ed) { throw "Edition not found (index '$($Plan.Index)', name '$($Plan.Edition)')" }
        $res.Index = $ed.Index; $res.Edition = $ed.Name
        $os = if ($Plan.Os) { $Plan.Os } else { $ed.Os }
        Write-ZinLog "Edition: [$($ed.Index)] $($ed.Name) ($os)"

        & $Progress 3 'disk'
        $layout = Initialize-ZinTargetDisk -DiskNumber $Plan.DiskNumber -Mode $Plan.Mode -PartitionNumber ([int]$Plan.PartitionNumber) -Style $Plan.Style
        $res.Style = $layout.Style
        $W = $layout.Win + '\'

        & $Progress 5 'apply'
        Expand-ZinWindowsImage -ImageFile $src.ImageFile -Index $ed.Index -ApplyDir $W -OnPercent { param($p) & $Progress ([int](5 + $p * 0.6)) 'apply' }

        if ($Plan.Drivers -and $zinData) {
            & $Progress 66 'drivers'
            try {
                $d = Invoke-ZinDriverOS -WindowsRoot $W -ZinData $zinData -Os $os
                $res.DriverSource = $d.Source; $res.DriverPath = $d.Path; $res.MissingDrivers = $d.Missing
            } catch { $res.Warnings.Add("Drivers: $($_.Exception.Message)") ; Write-ZinLog "Drivers: $($_.Exception.Message)" 'ERROR' }
        }

        & $Progress 75 'apps'
        $appsRoot = if ($zinData) { Join-Path $zinData 'ZinPE\Apps' } else { '' }
        $catalog = if ($appsRoot) { @(Get-ZinAppCatalog $appsRoot) } else { @() }
        $selected = @($catalog | Where-Object { @($Plan.Apps) -contains $_.Id })
        $post = New-Object System.Collections.Generic.List[object]
        foreach ($a in $selected) {
            if ($a.RunAs -eq 'pe-offline') {
                $ok = $false
                try { $ok = Install-ZinOfflineApp -App $a -WinRoot $W -Sxs $src.Sxs } catch { Write-ZinLog "Offline app $($a.Id): $($_.Exception.Message)" 'WARN' }
                if (-not $ok -and $a.Type -eq 'feature') { $post.Add($a) }    # NetFx3 online later
                elseif (-not $ok) { $res.Warnings.Add("App $($a.Id) not installed") }
            } else { $post.Add($a) }
            $res.Apps += $a.Id
        }
        if ($Plan.NetFx3 -and -not (@($Plan.Apps) -contains 'NetFx3')) {
            if (-not (Enable-ZinNetFx3 -WinRoot $W -Sxs $src.Sxs)) { $res.Warnings.Add('.NET 3.5 not enabled offline') }
        }
        $assoc = if ($zinData) { Join-Path $zinData 'ZinPE\Config\DefaultAppAssociations.xml' } else { '' }
        if ($assoc -and (Test-Path $assoc) -and $selected.Count -gt 0) {
            Invoke-ZinProcess -FilePath 'dism.exe' -ArgumentList "/English /Image:$W /Import-DefaultAppAssociations:`"$assoc`"" -Hidden | Out-Null
        }

        $firstLogon = @()
        $needPost = ($post.Count -gt 0) -or [bool]$Plan.RunSdio -or [bool]$Plan.WingetUpgrade
        if ($needPost) {
            $firstLogon = Copy-ZinPostPayload -WinRoot $W -Apps $post.ToArray() -ScriptsRoot $scriptsRoot -WingetUpgrade ([bool]$Plan.WingetUpgrade) -RunSdio ([bool]$Plan.RunSdio)
        }

        & $Progress 85 'unattend'
        if ($Plan.Unattend) {
            Set-ZinOfflineTweaks -WinRoot $W -Options $Plan.Unattend
            $tpl = Get-ZinUnattendTemplate
            if ($tpl) {
                $xml = New-ZinUnattendXml -Template $tpl -Options $Plan.Unattend -FirstLogonCommands $firstLogon
                Write-ZinUtf8File -Path (Join-Path $W 'Windows\Panther\unattend.xml') -Content $xml
                Write-ZinLog 'unattend.xml written to Windows\Panther'
            } else { $res.Warnings.Add('Unattend template missing') }
        } elseif ($firstLogon.Count -gt 0) {
            $res.Warnings.Add('Unattend disabled: ZinPost runs only through SetupComplete.cmd')
        }

        & $Progress 92 'boot'
        $locale = if ($Plan.Locale) { $Plan.Locale } else { 'en-US' }
        Set-ZinBootFiles -WinRoot $W -SysRoot $layout.Sys -Style $layout.Style -Locale $locale
        if ($layout.Rec) { try { Set-ZinRecovery -WinRoot $W -RecRoot ($layout.Rec + '\') } catch { $res.Warnings.Add("Recovery: $($_.Exception.Message)") } }

        $res.Status = 'OK'
        & $Progress 98 'report'
    } catch {
        $res.Warnings.Add($_.Exception.Message)
        Write-ZinLog "INSTALL FAILED: $($_.Exception.Message)" 'ERROR'
        Write-ZinLog $_.ScriptStackTrace 'DEBUG'
    } finally {
        $res.Duration = (Get-Date) - $t0
        $winRoot = if ($layout) { $layout.Win + '\' } else { '' }
        try { $res.Reports = Write-ZinReport -Info $info -Result ([pscustomobject]$res) -ZinData $zinData -WinRoot $winRoot } catch { }
        if ($src -and $src.Iso) { Dismount-ZinIso $src.Iso }
        if ($layout) { Remove-ZinTempLetters -Letters @($layout.Temp | Where-Object { $_ -and ("$($_):" -ne $layout.Win) }) }
        & $Progress 100 $res.Status
    }
    [pscustomobject]$res
}

function Get-ZinUnattendTemplate {
    $zd = Find-ZinData
    $scripts = Split-Path -Parent $PSScriptRoot
    foreach ($p in @("$zd\ZinPE\Unattend\zin-unattend.xml", 'X:\ZinPE\Unattend\zin-unattend.xml', (Join-Path $scripts '..\Unattend\zin-unattend.xml'), (Join-Path $scripts '..\config\Unattend\zin-unattend.xml'))) {
        if ($p -and (Test-Path $p)) { return [IO.File]::ReadAllText((Resolve-Path $p).ProviderPath, [System.Text.Encoding]::UTF8) }
    }
    $null
}

#endregion

Export-ModuleMember -Function *-Zin*
