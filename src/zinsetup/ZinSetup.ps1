<#
.SYNOPSIS
  ZinSetup - bilingual (EN/VI) Windows installer for ZinWinPE (design 8.2 A, 8.3, 8.5, 8.6).
.EXAMPLE
  ZinSetup.ps1                                   # GUI
  ZinSetup.ps1 -Preset Win11-Pro-Shop -Disk 0 -Yes   # unattended CLI (quick install)
#>
[CmdletBinding()]
param(
    [string]$Preset,
    [int]$Disk = -1,
    [string]$Lang,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
$ScriptsRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ScriptsRoot 'common\ZinCommon.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $PSScriptRoot 'ZinSetup.Core.psm1') -DisableNameChecking -Force

$ZinData = Find-ZinData
$Config = Get-ZinConfig -ZinData $ZinData
Initialize-ZinLang -Code $Lang -ZinData $ZinData
$LogFile = if ($ZinData) { Join-Path $ZinData ("ZinPE\Logs\setup-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date)) } else { Join-Path $env:TEMP 'zinsetup.log' }
Set-ZinLogFile $LogFile
Write-ZinLog "=== ZinSetup $(Get-ZinVersion -ZinData $ZinData) ==="

$PresetDir = if ($ZinData) { Join-Path $ZinData 'ZinPE\Presets' } else { 'X:\ZinPE\Presets' }
$Presets = @(Get-ZinPreset -PresetDir $PresetDir)
$Machine = Get-ZinMachineInfo
$Readiness = Test-ZinWin11Ready -Info $Machine
Write-ZinLog "Machine: $($Machine.Manufacturer) $($Machine.FriendlyName), $($Machine.CPU), $($Machine.RamGB) GB, $($Machine.Firmware), TPM '$($Machine.TPM)', Win11 ready: $($Readiness.Ready) $($Readiness.Reasons -join ',')"

function New-PlanFromPreset($P, [int]$DiskNumber) {
    $img = Resolve-ZinPresetImage -Preset $P -ZinData $ZinData
    $part = if ($P.PSObject.Properties.Name -contains 'partition') { $P.partition } else { [pscustomobject]@{ mode = 'Wipe'; style = 'Auto' } }
    @{
        Preset = $P.name; ImagePath = $img.Path; Edition = $img.Edition; Os = "$($P.os)"
        DiskNumber = $DiskNumber; Mode = "$($part.mode)"; PartitionNumber = 0; Style = "$($part.style)"
        Unattend = $P.unattend; Apps = @($P.apps); Drivers = [bool]$P.drivers; NetFx3 = [bool]$P.netfx3
        RunSdio = [bool]$P.runSdio; WingetUpgrade = [bool]$P.wingetUpgrade; Locale = 'en-US'
    }
}

function Get-ReasonText { ($Readiness.Reasons | ForEach-Object { Get-ZinText "setup.reason_$_" }) -join ', ' }

#region CLI ---------------------------------------------------------------------
if ($Preset) {
    $p = $Presets | Where-Object { $_.name -eq $Preset } | Select-Object -First 1
    if (-not $p) { Write-ZinLog "Preset '$Preset' not found in $PresetDir" 'ERROR'; exit 2 }
    if ($Disk -lt 0) { Write-ZinLog '-Disk is required with -Preset' 'ERROR'; exit 2 }
    if (-not $Yes) {
        $d = Get-ZinTargetDisk | Where-Object Number -eq $Disk
        $ans = Read-Host ((Get-ZinText 'setup.confirm_wipe' @($Disk, $d.Model, $d.SizeGB, $p.name)) + ' [y/N]')
        if ($ans -notmatch '^(y|yes|c|co)$') { exit 0 }
    }
    $plan = New-PlanFromPreset $p $Disk
    $r = Invoke-ZinInstall -Plan $plan -Progress { param($pc, $m) Write-Progress -Activity 'ZinSetup' -Status $m -PercentComplete $pc }
    $r | Format-List Status, Edition, Disk, Style, DriverSource, Apps, Warnings, Duration, Reports
    if ($r.Status -eq 'OK') { exit 0 } else { exit 1 }
}
#endregion

#region GUI ---------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Tag="setup.title" Width="940" Height="680" WindowStartupLocation="CenterScreen"
        Background="#0E1016" Foreground="#E8E8E8" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#DEB85C"/><Setter Property="Foreground" Value="#0E1016"/>
      <Setter Property="Padding" Value="14,6"/><Setter Property="Margin" Value="4"/><Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#E8E8E8"/><Setter Property="Margin" Value="0,3"/></Style>
    <Style TargetType="RadioButton"><Setter Property="Foreground" Value="#E8E8E8"/><Setter Property="Margin" Value="0,3"/></Style>
    <Style TargetType="TextBlock"><Setter Property="Margin" Value="0,6,0,2"/></Style>
    <Style TargetType="ComboBox"><Setter Property="Margin" Value="0,0,0,4"/><Setter Property="MinHeight" Value="26"/></Style>
  </Window.Resources>
  <DockPanel Margin="12">
    <Grid DockPanel.Dock="Top" Margin="0,0,0,8">
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <Image x:Name="Logo" Width="56" Height="56" Margin="0,0,12,0"/>
      <StackPanel Grid.Column="1">
        <TextBlock x:Name="MachineText" FontSize="15" FontWeight="SemiBold" Foreground="#DEB85C" Margin="0"/>
        <TextBlock x:Name="HwText" Margin="0"/>
        <TextBlock x:Name="ReadyText" Margin="0"/>
      </StackPanel>
      <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Top">
        <Button x:Name="BtnEN" Content="EN" Padding="8,2"/>
        <Button x:Name="BtnVI" Content="VI" Padding="8,2"/>
      </StackPanel>
    </Grid>
    <StackPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
      <ProgressBar x:Name="Prog" Height="18" Minimum="0" Maximum="100" Foreground="#DEB85C"/>
      <DockPanel>
        <Button x:Name="BtnLog" Tag="setup.open_log" DockPanel.Dock="Right"/>
        <TextBlock x:Name="StatusText" VerticalAlignment="Center"/>
      </DockPanel>
    </StackPanel>
    <TabControl x:Name="Tabs" Background="#161A22">
      <TabItem Tag="setup.tab_quick">
        <StackPanel Margin="16" MaxWidth="620" HorizontalAlignment="Left">
          <TextBlock Tag="setup.select_disk"/>
          <ComboBox x:Name="QDisk"/>
          <TextBlock Tag="setup.select_preset"/>
          <ComboBox x:Name="QPreset"/>
          <TextBlock x:Name="QPresetInfo" TextWrapping="Wrap" Foreground="#A0A6B0"/>
          <Button x:Name="QInstall" Tag="setup.install" HorizontalAlignment="Left" Margin="0,16,0,0" FontSize="16" Padding="28,8"/>
        </StackPanel>
      </TabItem>
      <TabItem Tag="setup.tab_advanced">
        <Grid Margin="12">
          <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="16"/><ColumnDefinition/></Grid.ColumnDefinitions>
          <StackPanel>
            <TextBlock Tag="setup.source"/>
            <DockPanel><Button x:Name="ARefresh" Tag="setup.refresh" DockPanel.Dock="Right" Margin="4,0,0,4" Padding="8,2"/><ComboBox x:Name="ASource"/></DockPanel>
            <TextBlock Tag="setup.edition"/>
            <ComboBox x:Name="AEdition"/>
            <TextBlock Tag="setup.select_disk"/>
            <ComboBox x:Name="ADisk"/>
            <TextBlock Tag="setup.partition_mode"/>
            <RadioButton x:Name="AModeWipe" Tag="setup.mode_wipe" IsChecked="True"/>
            <RadioButton x:Name="AModeExisting" Tag="setup.mode_existing"/>
            <TextBlock Tag="setup.partition"/>
            <ComboBox x:Name="APart" IsEnabled="False"/>
            <TextBlock Tag="setup.style"/>
            <ComboBox x:Name="AStyle"/>
            <WrapPanel Margin="0,10,0,0">
              <Button x:Name="AInstall" Tag="setup.install"/>
              <Button x:Name="BtnWinNT" Tag="setup.manual" Background="#3A3F4B" Foreground="#E8E8E8"/>
              <Button x:Name="BtnNative" Tag="setup.native_setup" Background="#3A3F4B" Foreground="#E8E8E8"/>
            </WrapPanel>
          </StackPanel>
          <ScrollViewer Grid.Column="2" VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <CheckBox x:Name="AUnattend" Tag="setup.unattend" IsChecked="True" FontWeight="SemiBold"/>
              <StackPanel Margin="20,0,0,0">
                <TextBlock Tag="setup.local_user"/><TextBox x:Name="AUser" Text="User"/>
                <TextBlock Tag="setup.password"/><TextBox x:Name="APassword"/>
                <CheckBox x:Name="ABypassNRO" Tag="setup.bypass_nro" IsChecked="True"/>
                <CheckBox x:Name="AEncrypt" Tag="setup.prevent_encryption" IsChecked="True"/>
                <CheckBox x:Name="AWin11Bypass" Tag="setup.win11_bypass"/>
                <CheckBox x:Name="AVnLocale" Tag="setup.vn_locale" IsChecked="True"/>
              </StackPanel>
              <CheckBox x:Name="ADrivers" Tag="setup.drivers" IsChecked="True"/>
              <CheckBox x:Name="ANetFx3" Tag="setup.netfx3"/>
              <CheckBox x:Name="ASdio" Tag="setup.run_sdio" IsChecked="True"/>
              <CheckBox x:Name="AWinget" Tag="setup.winget"/>
              <TextBlock Tag="setup.apps" FontWeight="SemiBold"/>
              <ItemsControl x:Name="AApps"/>
            </StackPanel>
          </ScrollViewer>
        </Grid>
      </TabItem>
    </TabControl>
  </DockPanel>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
$xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
    $n = $_.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1
    $ui[$n.Value] = $win.FindName($n.Value)
}

function Update-UiText {
    param($Element)
    if ($Element -is [System.Windows.FrameworkElement] -and $Element.Tag -is [string] -and $Element.Tag -match '^(setup|common)\.') {
        $t = Get-ZinText $Element.Tag
        if ($Element -is [System.Windows.Window]) { $Element.Title = $t }
        elseif ($Element -is [System.Windows.Controls.HeaderedContentControl]) { $Element.Header = $t }
        elseif ($Element -is [System.Windows.Controls.ContentControl]) { $Element.Content = $t }
        elseif ($Element -is [System.Windows.Controls.TextBlock]) { $Element.Text = $t }
    }
    if ($Element -is [System.Windows.DependencyObject]) {
        foreach ($c in [System.Windows.LogicalTreeHelper]::GetChildren($Element)) { Update-UiText $c }
    }
}

function Set-Language([string]$Code) {
    Initialize-ZinLang -Code $Code -ZinData $ZinData
    Update-UiText $win
    $ui.ReadyText.Text = if ($Readiness.Ready) { Get-ZinText 'setup.win11_ready' } else { Get-ZinText 'setup.win11_not_ready' @(Get-ReasonText) }
    Update-PresetList
    Update-AppList
}

# --- header -------------------------------------------------------------------
$logo = @('X:\ZinPE\branding\logo-64.png', "$ZinData\ZinPE\Config\branding\logo-64.png", (Join-Path $ScriptsRoot '..\assets\branding\logo-64.png')) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($logo) { $ui.Logo.Source = New-Object System.Windows.Media.Imaging.BitmapImage ([uri](Resolve-Path $logo).ProviderPath) }
$ui.MachineText.Text = "$($Machine.Manufacturer) $($Machine.FriendlyName)  |  S/N $($Machine.Serial)"
$ui.HwText.Text = "$($Machine.CPU)  |  RAM $($Machine.RamGB) GB  |  $($Machine.Firmware), Secure Boot $($Machine.SecureBoot), TPM $($Machine.TPM)"
$ui.ReadyText.Foreground = if ($Readiness.Ready) { '#7BD88F' } else { '#F2A65A' }

# --- disks --------------------------------------------------------------------
$script:Disks = @()
function Update-Disks {
    $script:Disks = @(Get-ZinTargetDisk)
    foreach ($cb in @($ui.QDisk, $ui.ADisk)) {
        $cb.Items.Clear()
        foreach ($d in $script:Disks) {
            $cb.Items.Add(("#{0}  {1}  {2} GB  {3}  {4}" -f $d.Number, $d.Model, $d.SizeGB, $d.Bus, $d.Style)) | Out-Null
        }
        if ($cb.Items.Count -gt 0) { $cb.SelectedIndex = 0 }
    }
    if ($script:Disks.Count -eq 0) { $ui.StatusText.Text = Get-ZinText 'setup.no_disk' }
}
function Update-Partitions {
    $ui.APart.Items.Clear()
    if ($ui.ADisk.SelectedIndex -lt 0) { return }
    foreach ($p in $script:Disks[$ui.ADisk.SelectedIndex].Partitions) {
        $win_ = if ($p.HasWindows) { '  [Windows]' } else { '' }
        $ui.APart.Items.Add(("{0}: {1} {2} GB {3} {4}{5}" -f $p.PartitionNumber, $p.Letter, $p.SizeGB, $p.FileSystem, $p.Label, $win_)) | Out-Null
    }
    $idx = 0
    for ($i = 0; $i -lt $ui.APart.Items.Count; $i++) { if ($script:Disks[$ui.ADisk.SelectedIndex].Partitions[$i].HasWindows) { $idx = $i } }
    if ($ui.APart.Items.Count -gt 0) { $ui.APart.SelectedIndex = $idx }
}

# --- presets ------------------------------------------------------------------
$script:Suggested = $null
function Update-PresetList {
    $sel = $ui.QPreset.SelectedIndex
    $ui.QPreset.Items.Clear()
    if ($Presets.Count -eq 0) { return }
    $script:Suggested = if ($Config.DefaultPreset) { $Presets | Where-Object name -eq $Config.DefaultPreset | Select-Object -First 1 } else { $null }
    if (-not $script:Suggested) { $script:Suggested = Select-ZinSuggestedPreset -Presets $Presets -Readiness $Readiness }
    foreach ($p in $Presets) {
        $t = Get-ZinPresetTitle -Preset $p -Lang (Get-ZinLangCode)
        if ($p -eq $script:Suggested) { $t += '  ' + (Get-ZinText 'setup.suggested') }
        $ui.QPreset.Items.Add($t) | Out-Null
    }
    $ui.QPreset.SelectedIndex = if ($sel -ge 0) { $sel } else { [array]::IndexOf($Presets, $script:Suggested) }
}
function Update-PresetInfo {
    if ($ui.QPreset.SelectedIndex -lt 0) { $ui.QPresetInfo.Text = ''; return }
    $p = $Presets[$ui.QPreset.SelectedIndex]
    $img = $(try { (Resolve-ZinPresetImage -Preset $p -ZinData $ZinData).Path } catch { "!! $($_.Exception.Message)" })
    $ui.QPresetInfo.Text = "$img`n$($p.edition)`n+ $(@($p.apps) -join ', ')"
}

# --- sources / editions -------------------------------------------------------
$script:Sources = @(); $script:Editions = @()
function Update-Sources {
    $ui.ASource.Items.Clear()
    $script:Sources = if ($ZinData) { @(Get-ZinImageSource -ZinData $ZinData) } else { @() }
    foreach ($s in $script:Sources) { $ui.ASource.Items.Add("$($s.Name)  ($($s.SizeGB) GB)") | Out-Null }
    if ($script:Sources.Count -gt 0) { $ui.ASource.SelectedIndex = 0 } else { $ui.StatusText.Text = Get-ZinText 'setup.no_images' }
}
function Update-Editions {
    $ui.AEdition.Items.Clear(); $script:Editions = @()
    if ($ui.ASource.SelectedIndex -lt 0) { return }
    $win.Cursor = 'Wait'
    try {
        $src = Resolve-ZinImageFile $script:Sources[$ui.ASource.SelectedIndex].Path
        $script:Editions = @(Get-ZinImageEdition $src.ImageFile)
        foreach ($e in $script:Editions) { $ui.AEdition.Items.Add("$($e.Index). $($e.Name)") | Out-Null }
        $pro = [array]::IndexOf(@($script:Editions | ForEach-Object { $_.Name -match ' Pro$' }), $true)
        $ui.AEdition.SelectedIndex = if ($pro -ge 0) { $pro } else { 0 }
    } catch { $ui.StatusText.Text = $_.Exception.Message } finally { $win.Cursor = $null }
}

# --- apps ---------------------------------------------------------------------
$script:Catalog = if ($ZinData) { @(Get-ZinAppCatalog (Join-Path $ZinData 'ZinPE\Apps') | Sort-Object Target, Category, Name) } else { @() }
$script:AppChecks = @{}
function Update-AppList {
    $checked = @{}
    foreach ($k in $script:AppChecks.Keys) { $checked[$k] = $script:AppChecks[$k].IsChecked }
    $ui.AApps.Items.Clear(); $script:AppChecks = @{}
    foreach ($a in $script:Catalog) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $label = "$($a.Name)  [$($a.Category)]"
        if ($a.Target -eq 'image') { $label += '  (image)' }
        if ($a.Verify -eq '1') { $label += '  (!)' }
        $cb.Content = $label
        $cb.ToolTip = "$($a.Installer) $($a.Args)`nRunAs: $($a.RunAs)  License: $($a.License)"
        $cb.IsChecked = if ($checked.ContainsKey($a.Id)) { $checked[$a.Id] } else { ($a.Default -eq '1' -and $a.Target -eq 'zinpost') }
        $ui.AApps.Items.Add($cb) | Out-Null
        $script:AppChecks[$a.Id] = $cb
    }
}

# --- install (background runspace keeps the UI responsive) ---------------------
$script:Sync = [hashtable]::Synchronized(@{ Busy = $false; Percent = 0; Step = ''; Result = $null; Error = $null })
function Start-Install([hashtable]$Plan) {
    if ($script:Sync.Busy) { return }
    $script:Sync.Busy = $true; $script:Sync.Result = $null; $script:Sync.Error = $null; $script:Sync.Percent = 0
    $ui.QInstall.IsEnabled = $false; $ui.AInstall.IsEnabled = $false
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($CorePath, $Plan, $Sync, $LogFile)
        try {
            Import-Module $CorePath -DisableNameChecking
            Set-ZinLogFile $LogFile
            $Sync.Result = Invoke-ZinInstall -Plan $Plan -Progress { param($p, $m) $Sync.Percent = $p; $Sync.Step = $m }
        } catch { $Sync.Error = $_.Exception.Message } finally { $Sync.Busy = $false }
    }).AddArgument((Join-Path $PSScriptRoot 'ZinSetup.Core.psm1')).AddArgument($Plan).AddArgument($script:Sync).AddArgument($LogFile)
    $script:Job = @{ PS = $ps; Handle = $ps.BeginInvoke() }
    $script:Timer.Start()
}

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [timespan]::FromMilliseconds(300)
$script:Timer.Add_Tick({
    $ui.Prog.Value = $script:Sync.Percent
    if ($script:Sync.Step) { $ui.StatusText.Text = Get-ZinText "setup.progress_$($script:Sync.Step)" }
    if ($script:Sync.Busy) { return }
    $script:Timer.Stop()
    $ui.QInstall.IsEnabled = $true; $ui.AInstall.IsEnabled = $true
    $r = $script:Sync.Result
    if ($r -and $r.Status -eq 'OK') {
        $ui.StatusText.Text = 'OK'
        $msg = Get-ZinText 'setup.done' @(('{0:mm\:ss}' -f $r.Duration))
        if (@($r.Warnings).Count -gt 0) { $msg = (@($r.Warnings) -join "`n") + "`n`n" + $msg }
        if ([System.Windows.MessageBox]::Show($msg, 'ZinSetup', 'YesNo', 'Information') -eq 'Yes') { & wpeutil.exe reboot }
    } else {
        $err = if ($r) { @($r.Warnings) -join "`n" } else { $script:Sync.Error }
        [System.Windows.MessageBox]::Show((Get-ZinText 'setup.failed' @($err, $LogFile)), 'ZinSetup', 'OK', 'Error') | Out-Null
    }
})

function Confirm-Wipe([int]$DiskIndex, [string]$What, [string]$Mode, [int]$PartNumber) {
    $d = $script:Disks[$DiskIndex]
    $msg = if ($Mode -eq 'Wipe') { Get-ZinText 'setup.confirm_wipe' @($d.Number, $d.Model, $d.SizeGB, $What) } else { Get-ZinText 'setup.confirm_existing' @($d.Number, $PartNumber, $What) }
    [System.Windows.MessageBox]::Show($msg, (Get-ZinText 'setup.confirm_title'), 'YesNo', 'Warning') -eq 'Yes'
}

$ui.QInstall.Add_Click({
    if ($ui.QDisk.SelectedIndex -lt 0 -or $ui.QPreset.SelectedIndex -lt 0) { return }
    $p = $Presets[$ui.QPreset.SelectedIndex]
    $req = ($p.PSObject.Properties.Name -contains 'requiresWin11') -and $p.requiresWin11
    if (-not $Readiness.Ready -and ($req -or "$($p.os)" -eq 'win11')) {
        if ([System.Windows.MessageBox]::Show((Get-ZinText 'setup.warn_bypass'), 'ZinSetup', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    if (-not (Confirm-Wipe $ui.QDisk.SelectedIndex (Get-ZinPresetTitle $p (Get-ZinLangCode)) 'Wipe' 0)) { return }
    try { Start-Install (New-PlanFromPreset $p $script:Disks[$ui.QDisk.SelectedIndex].Number) }
    catch { [System.Windows.MessageBox]::Show($_.Exception.Message, 'ZinSetup', 'OK', 'Error') | Out-Null }
})

$ui.AInstall.Add_Click({
    if ($ui.ASource.SelectedIndex -lt 0 -or $ui.AEdition.SelectedIndex -lt 0 -or $ui.ADisk.SelectedIndex -lt 0) { return }
    $ed = $script:Editions[$ui.AEdition.SelectedIndex]
    $mode = if ($ui.AModeWipe.IsChecked) { 'Wipe' } else { 'Existing' }
    $partNo = 0
    if ($mode -eq 'Existing') {
        if ($ui.APart.SelectedIndex -lt 0) { return }
        $partNo = $script:Disks[$ui.ADisk.SelectedIndex].Partitions[$ui.APart.SelectedIndex].PartitionNumber
    }
    if ($ed.Os -eq 'win11' -and -not $Readiness.Ready -and -not $ui.AWin11Bypass.IsChecked) {
        if ([System.Windows.MessageBox]::Show((Get-ZinText 'setup.warn_bypass'), 'ZinSetup', 'YesNo', 'Warning') -ne 'Yes') { return }
        $ui.AWin11Bypass.IsChecked = $true
    }
    if (-not (Confirm-Wipe $ui.ADisk.SelectedIndex $ed.Name $mode $partNo)) { return }
    $vn = [bool]$ui.AVnLocale.IsChecked
    $unattend = $null
    if ($ui.AUnattend.IsChecked) {
        $unattend = [pscustomobject]@{
            computerName = '*'; localUser = $(if ($ui.AUser.Text.Trim()) { $ui.AUser.Text.Trim() } else { 'User' }); password = $ui.APassword.Text
            autoLogon = $true; bypassNRO = [bool]$ui.ABypassNRO.IsChecked; preventDeviceEncryption = [bool]$ui.AEncrypt.IsChecked
            win11Bypass = [bool]$ui.AWin11Bypass.IsChecked
            timeZone = $(if ($vn) { 'SE Asia Standard Time' } else { 'UTC' }); inputLocale = '0409:00000409'
            systemLocale = $(if ($vn) { 'vi-VN' } else { 'en-US' }); uiLanguage = 'en-US'; userLocale = $(if ($vn) { 'vi-VN' } else { 'en-US' })
        }
    }
    $styles = @('Auto', 'GPT', 'MBR')
    $plan = @{
        Preset = '(advanced)'; ImagePath = $script:Sources[$ui.ASource.SelectedIndex].Path; Index = $ed.Index; Os = $ed.Os
        DiskNumber = $script:Disks[$ui.ADisk.SelectedIndex].Number; Mode = $mode; PartitionNumber = $partNo
        Style = $styles[[math]::Max(0, $ui.AStyle.SelectedIndex)]; Unattend = $unattend
        Apps = @($script:AppChecks.Keys | Where-Object { $script:AppChecks[$_].IsChecked })
        Drivers = [bool]$ui.ADrivers.IsChecked; NetFx3 = [bool]$ui.ANetFx3.IsChecked
        RunSdio = [bool]$ui.ASdio.IsChecked; WingetUpgrade = [bool]$ui.AWinget.IsChecked; Locale = 'en-US'
    }
    Start-Install $plan
})

$ui.BtnWinNT.Add_Click({
    $exe = Find-ZinTool 'WinNTSetup_x64.exe' -ExtraDirs @('X:\Programs\WinNTSetup', "$ZinData\ZinPE\Programs\Backup\WinNTSetup")
    if ($exe) { Start-Process $exe } else { [System.Windows.MessageBox]::Show('WinNTSetup_x64.exe not found', 'ZinSetup') | Out-Null }
})
$ui.BtnNative.Add_Click({
    if ($ui.ASource.SelectedIndex -lt 0) { return }
    $s = $script:Sources[$ui.ASource.SelectedIndex]
    if ($s.Kind -ne 'iso') { [System.Windows.MessageBox]::Show('ISO only', 'ZinSetup') | Out-Null; return }
    $m = Mount-ZinIso $s.Path
    Start-Process (Join-Path $m.Root 'sources\setup.exe')
})
$ui.BtnLog.Add_Click({ if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile } })
$ui.BtnEN.Add_Click({ Set-Language 'en-US' })
$ui.BtnVI.Add_Click({ Set-Language 'vi-VN' })
$ui.ADisk.Add_SelectionChanged({ Update-Partitions })
$ui.ASource.Add_SelectionChanged({ Update-Editions })
$ui.ARefresh.Add_Click({ Update-Disks; Update-Sources })
$ui.QPreset.Add_SelectionChanged({ Update-PresetInfo })
$ui.AModeExisting.Add_Checked({ $ui.APart.IsEnabled = $true; $ui.AStyle.IsEnabled = $false })
$ui.AModeWipe.Add_Checked({ $ui.APart.IsEnabled = $false; $ui.AStyle.IsEnabled = $true })
$win.Add_Closing({ param($s, $e) if ($script:Sync.Busy) { $e.Cancel = $true; [System.Windows.MessageBox]::Show((Get-ZinText 'setup.busy'), 'ZinSetup') | Out-Null } })

foreach ($s in @('Auto (UEFI=GPT, BIOS=MBR)', 'GPT', 'MBR')) { $ui.AStyle.Items.Add($s) | Out-Null }
$ui.AStyle.SelectedIndex = 0
if (-not $ZinData) { $ui.StatusText.Text = Get-ZinText 'setup.no_zindata' }
Update-Disks
Update-Sources
Set-Language (Get-ZinLangCode)
if ($Presets.Count -eq 0) { $ui.Tabs.SelectedIndex = 1 }
[void]$win.ShowDialog()
#endregion
