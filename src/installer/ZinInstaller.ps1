<#
.SYNOPSIS
  ZinWinPE Installer (design 12): create / update a USB, create an ISO, add ZinWinPE to a hard disk.
  Runs on full Windows 10/11 as Administrator. No -Action = bilingual GUI.
.EXAMPLE
  ZinInstaller.ps1                                                     # GUI
  ZinInstaller.ps1 -Action Create -Disk 3 -Package D:\out\ZinWinPE-2026.10 [-Style MBR] [-DataFs exFAT] [-BootSizeGB 3] [-BootFiles Auto]
  ZinInstaller.ps1 -Action Update -Package D:\out\ZinWinPE-2026.10
  ZinInstaller.ps1 -Action Iso    -Package D:\out\ZinWinPE-2026.10 -IsoPath D:\out\ZinWinPE.iso
  ZinInstaller.ps1 -Action HardDisk -Package D:\out\ZinWinPE-2026.10
#>
[CmdletBinding()]
param(
    [ValidateSet('Gui', 'Create', 'Update', 'Iso', 'HardDisk')][string]$Action = 'Gui',
    [int]$Disk = -1,
    [string]$Package,
    [ValidateSet('MBR', 'GPT')][string]$Style = 'MBR',
    [ValidateSet('exFAT', 'NTFS')][string]$DataFs = 'exFAT',
    [ValidateSet(2, 3, 4)][int]$BootSizeGB = 3,
    [ValidateSet('Auto', '2011', '2023')][string]$BootFiles = 'Auto',
    [string]$IsoPath,
    [switch]$IsoWithoutData,
    [switch]$NoHide,
    [string]$Lang,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
$ScriptsRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ScriptsRoot 'common\ZinCommon.psm1') -DisableNameChecking -Force
Initialize-ZinLang -Code $Lang
$LogFile = Join-Path $env:TEMP 'ZinWinPE-installer.log'
Set-ZinLogFile $LogFile

function Assert-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run as Administrator' }
}

function Assert-Package([string]$Path) {
    if (-not $Path -or -not (Test-Path (Join-Path $Path 'ZINBOOT\ZinPE\boot11.wim'))) { throw "Not a ZinWinPE package (ZINBOOT\ZinPE\boot11.wim missing): $Path" }
    (Resolve-Path $Path).ProviderPath
}

function Get-UsbDisk {
    Get-Disk | Where-Object { "$($_.BusType)" -in @('USB', 'SD', 'MMC') -and $_.Size -gt 4GB } | Sort-Object Number | ForEach-Object {
        [pscustomobject]@{ Number = $_.Number; Model = "$($_.FriendlyName)".Trim(); SizeGB = [math]::Round($_.Size / 1GB, 1); Style = "$($_.PartitionStyle)" }
    }
}

function Get-FolderGB([string]$Path) {
    if (-not (Test-Path $Path)) { return 0 }
    [math]::Round(((Get-ChildItem $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1GB, 2)
}

function Invoke-Robocopy([string]$Src, [string]$Dst, [string[]]$Extra = @()) {
    Write-ZinLog "robocopy $Src -> $Dst $($Extra -join ' ')"
    & robocopy.exe $Src $Dst /E /R:1 /W:1 /NP /NFL /NDL /NJH /J @Extra | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE): $Src -> $Dst" }
}

function Set-BootFileSet([string]$BootRoot, [string]$Set) {
    if ($Set -eq 'Auto') { return }
    $src = Join-Path $BootRoot "EFI\zin\ca$Set\bootx64.efi"
    if (-not (Test-Path $src)) { Write-ZinLog "Boot file set CA $Set not in package - keeping default" 'WARN'; return }
    Copy-Item $src (Join-Path $BootRoot 'EFI\Boot\bootx64.efi') -Force
    Copy-Item $src (Join-Path $BootRoot 'EFI\Microsoft\Boot\bootmgfw.efi') -Force
    Set-Content (Join-Path $BootRoot 'EFI\zin\bootfiles.txt') "ca$Set" -Encoding ASCII
    Write-ZinLog "UEFI boot files: CA $Set"
}

function Test-Sums([string]$PackageDir, [hashtable]$Map) {
    # $Map: package-relative prefix -> destination root, e.g. @{ 'ZINBOOT\' = 'B:\' }
    $sums = Join-Path $PackageDir 'SHA256SUMS.txt'
    if (-not (Test-Path $sums)) { Write-ZinLog 'SHA256SUMS.txt missing - verification skipped' 'WARN'; return $true }
    $bad = 0; $n = 0
    foreach ($l in Get-Content $sums) {
        if ($l -notmatch '^([0-9A-F]{64})\s+(.+)$') { continue }
        $hash = $Matches[1]; $rel = $Matches[2]
        foreach ($k in $Map.Keys) {
            if ($rel.StartsWith($k, [StringComparison]::OrdinalIgnoreCase)) {
                $f = Join-Path $Map[$k] $rel.Substring($k.Length)
                $n++
                if (-not (Test-Path $f) -or (Get-FileHash $f -Algorithm SHA256).Hash -ne $hash) {
                    # bootx64.efi / bootmgfw.efi / bootfiles.txt legitimately differ when another boot file set was chosen.
                    if ($rel -notmatch 'EFI\\(Boot\\bootx64\.efi|Microsoft\\Boot\\bootmgfw\.efi|zin\\bootfiles\.txt)$') { $bad++; Write-ZinLog "Hash mismatch: $f" 'ERROR' }
                }
            }
        }
    }
    if ($bad -eq 0) { Write-ZinLog (Get-ZinText 'installer.verify_ok' @($n)) } else { Write-ZinLog (Get-ZinText 'installer.verify_fail' @($bad)) 'ERROR' }
    $bad -eq 0
}

function Get-FreeLetters([int]$Count) {
    $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1) })
    @([char[]]([int][char]'Z'..[int][char]'H') | ForEach-Object { "$_" } | Where-Object { $used -notcontains $_ } | Select-Object -First $Count)
}

#region Actions ---------------------------------------------------------------------
function Invoke-Create {
    Assert-Admin
    $pkg = Assert-Package $Package
    $usb = Get-UsbDisk | Where-Object Number -eq $Disk
    if (-not $usb) { throw "Disk $Disk is not a USB/removable disk - refusing (design 12)" }
    if ($usb.SizeGB -lt 58) { Write-ZinLog (Get-ZinText 'installer.warn_small') 'WARN' }
    $need = Get-FolderGB (Join-Path $pkg 'ZINDATA')
    $avail = [math]::Round($usb.SizeGB - $BootSizeGB - 0.5, 1)
    if ($need -gt $avail) { throw (Get-ZinText 'installer.warn_space' @($need, $avail)) }
    if (-not $Yes) {
        if ((Read-Host ((Get-ZinText 'installer.confirm1' @("$($usb.Number) $($usb.Model)", $usb.SizeGB)) + ' [y/N]')) -notmatch '^(y|yes|c|co)$') { return }
        if ((Read-Host (Get-ZinText 'installer.confirm2' @($usb.Number))) -ne "$($usb.Number)") { return }
    }
    $L = Get-FreeLetters 2; $B = $L[0]; $D = $L[1]
    $fs = $DataFs.ToLower()
    $lines = @("select disk $Disk", 'clean')
    $lines += if ($Style -eq 'MBR') { 'convert mbr' } else { 'convert gpt' }
    $lines += @("create partition primary size=$($BootSizeGB * 1024)", 'format quick fs=fat32 label="ZINBOOT"', "assign letter=$B")
    if ($Style -eq 'MBR') { $lines += 'active' }
    $lines += @('create partition primary', "format quick fs=$fs label=`"ZINDATA`"", "assign letter=$D", 'exit')
    if (-not (Invoke-ZinDiskpart -Lines $lines)) { throw 'diskpart failed' }
    Start-Sleep -Seconds 2

    Invoke-Robocopy (Join-Path $pkg 'ZINBOOT') "$($B):\"
    Set-BootFileSet "$($B):\" $BootFiles
    Invoke-Robocopy (Join-Path $pkg 'ZINDATA') "$($D):\"
    if ($Style -eq 'MBR') { Invoke-ZinProcess -FilePath 'bootsect.exe' -ArgumentList "/nt60 $($B): /mbr /force" -Hidden | Out-Null }
    $info = [ordered]@{ version = (Get-Content (Join-Path $pkg 'ZINBOOT\ZinPE\version.txt') -TotalCount 1); created = (Get-Date).ToString('s'); style = $Style; dataFs = $DataFs; bootFiles = $BootFiles }
    Write-ZinUtf8File -Path "$($D):\ZinPE\Config\usb.json" -Content (ConvertTo-Json $info)
    $ok = Test-Sums $pkg @{ 'ZINBOOT\' = "$($B):\"; 'ZINDATA\' = "$($D):\" }

    if (-not $NoHide) {
        $hide = @("select disk $Disk", 'select partition 1', "remove letter=$B")
        $hide += if ($Style -eq 'MBR') { 'set id=1c override' } else { 'gpt attributes=0x8000000000000000' }
        $hide += 'exit'
        Invoke-ZinDiskpart -Lines $hide | Out-Null
    }
    Write-ZinLog "$(Get-ZinText 'installer.done') ZINDATA = $($D):"
    if (-not $ok) { exit 3 }
}

function Find-ZinUsb {
    foreach ($u in Get-UsbDisk) {
        foreach ($p in Get-Partition -DiskNumber $u.Number -ErrorAction SilentlyContinue) {
            if ($p.DriveLetter -and (Test-Path "$($p.DriveLetter):\ZinPE\zinpe.tag")) { return @{ Disk = $u.Number; Data = "$($p.DriveLetter):"; Style = $u.Style } }
        }
    }
    $null
}

function Invoke-Update {
    Assert-Admin
    $pkg = Assert-Package $Package
    $z = Find-ZinUsb
    if (-not $z) { throw 'No ZinWinPE USB found (ZINDATA with ZinPE\zinpe.tag)' }
    $B = (Get-FreeLetters 1)[0]
    $pre = @("select disk $($z.Disk)", 'select partition 1')
    $pre += if ($z.Style -eq 'MBR') { 'set id=0c override' } else { 'gpt attributes=0x0000000000000000' }
    $pre += @("assign letter=$B", 'exit')
    if (-not (Invoke-ZinDiskpart -Lines $pre)) { throw 'Cannot mount ZINBOOT' }
    Start-Sleep -Seconds 2
    try {
        $oldSet = if (Test-Path "$($B):\EFI\zin\bootfiles.txt") { (Get-Content "$($B):\EFI\zin\bootfiles.txt" -TotalCount 1).Trim() } else { 'Auto' }
        # ZINBOOT belongs to ZinWinPE only -> mirror.
        & robocopy.exe (Join-Path $pkg 'ZINBOOT') "$($B):\" /MIR /R:1 /W:1 /NP /NFL /NDL /NJH | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy ZINBOOT failed ($LASTEXITCODE)" }
        $set = if ($BootFiles -ne 'Auto') { $BootFiles } elseif ($oldSet -match 'ca(\d{4})') { $Matches[1] } else { 'Auto' }
        Set-BootFileSet "$($B):\" $set
        # ZINDATA: replace program files, keep ISO, Backup, Reports, Logs and the shop's config (design 12 "Cap nhat").
        $src = Join-Path $pkg 'ZINDATA\ZinPE'
        foreach ($d in @('Scripts', 'Lang')) { & robocopy.exe "$src\$d" "$($z.Data)\ZinPE\$d" /MIR /R:1 /W:1 /NP /NFL /NDL /NJH | Out-Null }
        Invoke-Robocopy $src "$($z.Data)\ZinPE" @('/XD', 'Logs', 'Scripts', 'Lang', '/XF', 'zinpe.ini', 'DefaultAppAssociations.xml', 'usb.json')
        Test-Sums $pkg @{ 'ZINBOOT\' = "$($B):\"; 'ZINDATA\ZinPE\Scripts\' = "$($z.Data)\ZinPE\Scripts\" } | Out-Null
    } finally {
        $post = @("select disk $($z.Disk)", 'select partition 1', "remove letter=$B")
        if (-not $NoHide) { $post += if ($z.Style -eq 'MBR') { 'set id=1c override' } else { 'gpt attributes=0x8000000000000000' } }
        $post += 'exit'
        Invoke-ZinDiskpart -Lines $post | Out-Null
    }
    Write-ZinLog (Get-ZinText 'installer.done')
}

function Invoke-Iso {
    $pkg = Assert-Package $Package
    $adk = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg"
    $oscdimg = Join-Path $adk 'oscdimg.exe'
    if (-not (Test-Path $oscdimg)) { throw "oscdimg.exe not found ($adk) - install the Windows ADK Deployment Tools" }
    if (-not $IsoPath) { $IsoPath = Join-Path (Split-Path $pkg) ((Split-Path $pkg -Leaf) + '.iso') }
    $stage = Join-Path $env:TEMP 'zinwinpe-iso'
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    Invoke-Robocopy (Join-Path $pkg 'ZINBOOT') $stage
    Set-BootFileSet $stage $BootFiles
    if (-not $IsoWithoutData) {
        # One read-only volume: the loader finds ZinPE\zinpe.tag on the CD/Ventoy drive. Windows ISOs are left out.
        Invoke-Robocopy (Join-Path $pkg 'ZINDATA') $stage @('/XD', 'ISO', 'Backup', 'Reports')
    }
    $set = if (Test-Path "$stage\EFI\zin\bootfiles.txt") { (Get-Content "$stage\EFI\zin\bootfiles.txt" -TotalCount 1).Trim() } else { 'ca2011' }
    $efisys = if ($set -eq 'ca2023' -and (Test-Path "$adk\efisys_EX.bin")) { "$adk\efisys_EX.bin" } else { "$adk\efisys.bin" }
    $arg = "-m -o -u2 -udfver102 -l`"ZINWINPE`" -bootdata:2#p0,e,b`"$adk\etfsboot.com`"#pEF,e,b`"$efisys`" `"$stage`" `"$IsoPath`""
    $code = Invoke-ZinProcess -FilePath $oscdimg -ArgumentList $arg -Hidden
    Remove-Item $stage -Recurse -Force
    if ($code -ne 0) { throw "oscdimg failed ($code)" }
    Write-ZinLog ("ISO: {0} ({1:N2} GB)" -f $IsoPath, ((Get-Item $IsoPath).Length / 1GB))
}

function Invoke-HardDisk {
    # Adds "ZinWinPE 11 x64" to this PC's boot menu (copies the wim + boot.sdi to C:\ZinWinPE).
    Assert-Admin
    $pkg = Assert-Package $Package
    $dir = Join-Path $env:SystemDrive 'ZinWinPE'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item (Join-Path $pkg 'ZINBOOT\ZinPE\boot11.wim') $dir -Force
    Copy-Item (Join-Path $pkg 'ZINBOOT\Boot\boot.sdi') $dir -Force
    $old = & bcdedit.exe /enum all | Select-String -Pattern 'ZinWinPE' -Context 3, 0
    if ($old) { Write-ZinLog 'Existing ZinWinPE BCD entries found - remove them with bcdedit /delete {GUID} if duplicated' 'WARN' }
    $o = & bcdedit.exe /create /d 'ZinWinPE Ramdisk' /device
    $rd = [regex]::Match("$o", '\{[0-9a-fA-F\-]{36}\}').Value
    & bcdedit.exe /set $rd ramdisksdidevice "partition=$env:SystemDrive" | Out-Null
    & bcdedit.exe /set $rd ramdisksdipath '\ZinWinPE\boot.sdi' | Out-Null
    $o = & bcdedit.exe /create /d 'ZinWinPE 11 x64' /application osloader
    $id = [regex]::Match("$o", '\{[0-9a-fA-F\-]{36}\}').Value
    $winload = if ((Get-ZinFirmwareType) -eq 'UEFI') { '\Windows\System32\boot\winload.efi' } else { '\Windows\System32\boot\winload.exe' }
    foreach ($kv in @(@('device', "ramdisk=[$env:SystemDrive]\ZinWinPE\boot11.wim,$rd"), @('osdevice', "ramdisk=[$env:SystemDrive]\ZinWinPE\boot11.wim,$rd"),
            @('path', $winload), @('systemroot', '\Windows'), @('winpe', 'yes'), @('detecthal', 'yes'))) {
        & bcdedit.exe /set $id $kv[0] $kv[1] | Out-Null
    }
    & bcdedit.exe /displayorder $id /addlast | Out-Null
    $timeout = (& bcdedit.exe /enum '{bootmgr}' | Select-String '^timeout\s+(\d+)').Matches.Groups[1].Value
    if (-not $timeout -or [int]$timeout -lt 3) { & bcdedit.exe /timeout 5 | Out-Null }
    Write-ZinLog "BCD entry added: $id (C:\ZinWinPE)"
}
#endregion

#region GUI -------------------------------------------------------------------------
function Show-Gui {
    Add-Type -AssemblyName PresentationFramework, Microsoft.VisualBasic, System.Windows.Forms
    [xml]$x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Tag="installer.title" Width="620" SizeToContent="Height" WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="#0E1016" Foreground="#E8E8E8" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="TextBlock"><Setter Property="Margin" Value="0,8,0,2"/></Style>
    <Style TargetType="RadioButton"><Setter Property="Foreground" Value="#E8E8E8"/><Setter Property="Margin" Value="0,2"/></Style>
    <Style TargetType="Button"><Setter Property="Background" Value="#DEB85C"/><Setter Property="Padding" Value="12,4"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
  </Window.Resources>
  <StackPanel Margin="16">
    <DockPanel>
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal"><Button x:Name="BtnEN" Content="EN" Margin="2"/><Button x:Name="BtnVI" Content="VI" Margin="2"/></StackPanel>
      <TextBlock Text="ZinWinPE Installer" FontSize="20" FontWeight="Bold" Foreground="#DEB85C" Margin="0"/>
    </DockPanel>
    <TextBlock Tag="installer.package"/>
    <DockPanel><Button x:Name="Browse" Tag="installer.browse" DockPanel.Dock="Right" Margin="4,0,0,0"/><TextBox x:Name="Pkg"/></DockPanel>
    <TextBlock Tag="installer.action"/>
    <RadioButton x:Name="ACreate" Tag="installer.action_create" IsChecked="True"/>
    <RadioButton x:Name="AUpdate" Tag="installer.action_update"/>
    <RadioButton x:Name="AIso" Tag="installer.action_iso"/>
    <TextBlock Tag="installer.usb"/>
    <ComboBox x:Name="Usb"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <StackPanel>
        <TextBlock Tag="installer.style"/><ComboBox x:Name="StyleCb"/>
        <TextBlock Tag="installer.fs"/><ComboBox x:Name="FsCb"/>
      </StackPanel>
      <StackPanel Grid.Column="2">
        <TextBlock Tag="installer.boot_size"/><ComboBox x:Name="SizeCb"/>
        <TextBlock Tag="installer.bootfiles"/><ComboBox x:Name="BootCb"/>
      </StackPanel>
    </Grid>
    <TextBlock x:Name="Info" Foreground="#F2A65A" TextWrapping="Wrap"/>
    <Button x:Name="Start" Tag="installer.start" HorizontalAlignment="Right" Margin="0,12,0,0" FontSize="15" Padding="24,6"/>
  </StackPanel>
</Window>
'@
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $c = @{}; foreach ($n in @('BtnEN', 'BtnVI', 'Browse', 'Pkg', 'ACreate', 'AUpdate', 'AIso', 'Usb', 'StyleCb', 'FsCb', 'SizeCb', 'BootCb', 'Info', 'Start')) { $c[$n] = $w.FindName($n) }
    $script:UsbList = @()
    function Set-Texts($el) {
        if ($el -is [System.Windows.FrameworkElement] -and $el.Tag -is [string] -and $el.Tag -like 'installer.*') {
            $t = Get-ZinText $el.Tag
            if ($el -is [System.Windows.Window]) { $el.Title = $t } elseif ($el -is [System.Windows.Controls.ContentControl]) { $el.Content = $t } elseif ($el -is [System.Windows.Controls.TextBlock]) { $el.Text = $t }
        }
        if ($el -is [System.Windows.DependencyObject]) { foreach ($ch in [System.Windows.LogicalTreeHelper]::GetChildren($el)) { Set-Texts $ch } }
    }
    function Fill {
        $c.StyleCb.Items.Clear(); $c.StyleCb.Items.Add((Get-ZinText 'installer.style_mbr')) | Out-Null; $c.StyleCb.Items.Add((Get-ZinText 'installer.style_gpt')) | Out-Null; $c.StyleCb.SelectedIndex = 0
        $c.BootCb.Items.Clear(); foreach ($b in @((Get-ZinText 'installer.bootfiles_auto'), 'CA 2011', 'CA 2023')) { $c.BootCb.Items.Add($b) | Out-Null }; $c.BootCb.SelectedIndex = 0
        Set-Texts $w
    }
    $c.FsCb.Items.Add('exFAT') | Out-Null; $c.FsCb.Items.Add('NTFS') | Out-Null; $c.FsCb.SelectedIndex = 0
    foreach ($s in 2, 3, 4) { $c.SizeCb.Items.Add("$s GB") | Out-Null }; $c.SizeCb.SelectedIndex = 1
    $script:UsbList = @(Get-UsbDisk)
    foreach ($u in $script:UsbList) { $c.Usb.Items.Add(("#{0}  {1}  {2} GB  ({3})" -f $u.Number, $u.Model, $u.SizeGB, $u.Style)) | Out-Null }
    if ($c.Usb.Items.Count) { $c.Usb.SelectedIndex = 0 }
    $def = Get-ChildItem (Join-Path $ScriptsRoot '..\out') -Directory -Filter 'ZinWinPE-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if ($def) { $c.Pkg.Text = $def.FullName }
    Fill
    $c.BtnEN.Add_Click({ Initialize-ZinLang -Code 'en-US'; Fill })
    $c.BtnVI.Add_Click({ Initialize-ZinLang -Code 'vi-VN'; Fill })
    $c.Browse.Add_Click({ $d = New-Object System.Windows.Forms.FolderBrowserDialog; if ($d.ShowDialog() -eq 'OK') { $c.Pkg.Text = $d.SelectedPath } })
    $c.Usb.Add_SelectionChanged({
        $c.Info.Text = ''
        if ($c.Usb.SelectedIndex -ge 0 -and $script:UsbList[$c.Usb.SelectedIndex].SizeGB -lt 58) { $c.Info.Text = Get-ZinText 'installer.warn_small' }
    })
    $c.Start.Add_Click({
        $act = if ($c.ACreate.IsChecked) { 'Create' } elseif ($c.AUpdate.IsChecked) { 'Update' } else { 'Iso' }
        $a = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Action $act -Package `"$($c.Pkg.Text)`" -Lang $(Get-ZinLangCode) -Yes"
        if ($act -eq 'Create') {
            if ($c.Usb.SelectedIndex -lt 0) { return }
            $u = $script:UsbList[$c.Usb.SelectedIndex]
            if ([System.Windows.MessageBox]::Show((Get-ZinText 'installer.confirm1' @("#$($u.Number) $($u.Model)", $u.SizeGB)), 'ZinWinPE', 'YesNo', 'Warning') -ne 'Yes') { return }
            $typed = [Microsoft.VisualBasic.Interaction]::InputBox((Get-ZinText 'installer.confirm2' @($u.Number)), 'ZinWinPE', '')
            if ($typed -ne "$($u.Number)") { return }
            $a += " -Disk $($u.Number) -Style $(@('MBR', 'GPT')[$c.StyleCb.SelectedIndex]) -DataFs $($c.FsCb.SelectedItem) -BootSizeGB $(@(2, 3, 4)[$c.SizeCb.SelectedIndex])"
        }
        $a += " -BootFiles $(@('Auto', '2011', '2023')[$c.BootCb.SelectedIndex])"
        # Run in a visible console so robocopy/diskpart progress and errors stay readable.
        Start-Process powershell.exe -ArgumentList $a -Verb RunAs
    })
    [void]$w.ShowDialog()
}
#endregion

try {
    switch ($Action) {
        'Gui'      { Show-Gui }
        'Create'   { Invoke-Create }
        'Update'   { Invoke-Update }
        'Iso'      { Invoke-Iso }
        'HardDisk' { Invoke-HardDisk }
    }
} catch {
    Write-ZinLog $_.Exception.Message 'ERROR'
    Write-ZinLog "Log: $LogFile"
    exit 1
}
