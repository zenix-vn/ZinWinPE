<#
.SYNOPSIS
  ZinWinPE PE Loader (design 6.4 / 6.5). Runs once at WinPE startup, before Explorer.
.DESCRIPTION
  1. Time zone, wallpaper with dynamic version
  2. Find ZINDATA by ZinPE\zinpe.tag
  3. Load T2 drivers for devices without driver (drvload) + rescan disks
  4. Load portable tools from ZinPE\Programs\**\*.ini (+ .7z/.wim) -> X:\Programs, shortcuts
  5. Network (PENetwork or wpeutil) + SNTP time sync
  Modes: Normal | FullRAM | Safe. Press F (Full RAM) or S (Safe) during the 3s prompt.
#>
[CmdletBinding()]
param(
    [ValidateSet('', 'Normal', 'FullRAM', 'Safe')][string]$Mode = '',
    [int]$PromptSeconds = 3,
    [switch]$NoSplash,
    [switch]$NoExplorer
)
$ErrorActionPreference = 'Continue'
$ScriptsRoot = Split-Path -Parent $PSScriptRoot           # ...\ZinPE\Scripts
Import-Module (Join-Path $ScriptsRoot 'common\ZinCommon.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $ScriptsRoot 'zindriver\ZinDriver.psm1') -DisableNameChecking -Force

$ProgramsRam = 'X:\Programs'
$StartMenu = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'ZinWinPE'
$Desktop = [Environment]::GetFolderPath('Desktop')
if (-not $Desktop) { $Desktop = 'X:\Users\Default\Desktop' }

#region Splash ---------------------------------------------------------------
$script:Splash = $null
function Show-Splash {
    param([string]$LogoPath, [string]$Version)
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $f = New-Object System.Windows.Forms.Form
        $f.FormBorderStyle = 'None'; $f.StartPosition = 'CenterScreen'; $f.TopMost = $true
        $f.Size = New-Object System.Drawing.Size(460, 200)
        $f.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#0E1016')
        $gold = [System.Drawing.ColorTranslator]::FromHtml('#DEB85C')
        if ($LogoPath -and (Test-Path $LogoPath)) {
            $pb = New-Object System.Windows.Forms.PictureBox
            $pb.Image = [System.Drawing.Image]::FromFile($LogoPath); $pb.SizeMode = 'Zoom'
            $pb.Location = New-Object System.Drawing.Point(24, 36); $pb.Size = New-Object System.Drawing.Size(128, 128)
            $f.Controls.Add($pb)
        }
        $title = New-Object System.Windows.Forms.Label
        $title.Text = "ZinWinPE $Version"; $title.ForeColor = $gold
        $title.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
        $title.Location = New-Object System.Drawing.Point(170, 50); $title.AutoSize = $true
        $f.Controls.Add($title)
        $status = New-Object System.Windows.Forms.Label
        $status.ForeColor = [System.Drawing.Color]::Gainsboro; $status.Font = New-Object System.Drawing.Font('Segoe UI', 10)
        $status.Location = New-Object System.Drawing.Point(172, 100); $status.Size = New-Object System.Drawing.Size(270, 60)
        $f.Controls.Add($status)
        $f.Show(); [System.Windows.Forms.Application]::DoEvents()
        $script:Splash = @{ Form = $f; Status = $status }
    } catch { $script:Splash = $null }
}
function Set-Status([string]$Text) {
    Write-ZinLog $Text
    if ($script:Splash) { $script:Splash.Status.Text = $Text; [System.Windows.Forms.Application]::DoEvents() }
}
function Close-Splash { if ($script:Splash) { $script:Splash.Form.Close(); $script:Splash = $null } }
#endregion

#region Steps ----------------------------------------------------------------
function Read-BootMode([string]$Default) {
    if ($PromptSeconds -le 0) { return $Default }
    try {
        Write-Host ''
        Write-Host "  ZinWinPE - mode: $Default.  [F] Full RAM   [S] Safe   (${PromptSeconds}s)" -ForegroundColor Yellow
        $deadline = (Get-Date).AddSeconds($PromptSeconds)
        while ((Get-Date) -lt $deadline) {
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true).Key
                if ($k -eq 'F') { return 'FullRAM' }
                if ($k -eq 'S') { return 'Safe' }
                if ($k -eq 'Enter') { return $Default }
            }
            Start-Sleep -Milliseconds 100
        }
    } catch { }
    $Default
}

function Set-ZinWallpaper {
    # Draws the version string on the branded wallpaper (design 6.6 "dynamic version").
    param([string]$Source, [string]$Version, [string]$Mode)
    if (-not (Test-Path $Source)) { return }
    try {
        Add-Type -AssemblyName System.Drawing
        $img = [System.Drawing.Image]::FromFile($Source)
        $bmp = New-Object System.Drawing.Bitmap($img)
        $img.Dispose()
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.TextRenderingHint = 'AntiAlias'
        $font = New-Object System.Drawing.Font('Segoe UI', 14)
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#DEB85C'))
        $text = "ZinWinPE $Version  |  $Mode  |  $(Get-ZinFirmwareType)"
        $size = $g.MeasureString($text, $font)
        $g.DrawString($text, $font, $brush, ($bmp.Width - $size.Width - 24), ($bmp.Height - $size.Height - 64))
        $g.Dispose()
        $out = 'X:\Windows\Web\zinwinpe-wallpaper.bmp'
        $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Bmp); $bmp.Dispose()
        Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $out -ErrorAction SilentlyContinue
        $sig = '[DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int SystemParametersInfo(int a, int b, string c, int d);'
        $t = Add-Type -MemberDefinition $sig -Name ZinWp -Namespace Zin -PassThru -ErrorAction SilentlyContinue
        if ($t) { [void]$t::SystemParametersInfo(20, 0, $out, 3) }
    } catch { Write-ZinLog "Wallpaper: $($_.Exception.Message)" 'WARN' }
}

function Get-ProgramManifests([string]$ZinData) {
    $dir = Join-Path $ZinData 'ZinPE\Programs'
    if (-not (Test-Path $dir)) { return @() }
    foreach ($f in Get-ChildItem $dir -Filter *.ini -Recurse -File) {
        try {
            $ini = Read-ZinIni $f.FullName
            if (-not $ini.Contains('Program')) { continue }
            $p = $ini['Program']
            [pscustomobject]@{
                Name      = Get-ZinIniValue $ini 'Program' 'Name' $f.BaseName
                Group     = Get-ZinIniValue $ini 'Program' 'Group' 'Utilities'
                Archive   = Get-ZinIniValue $ini 'Program' 'Archive' ''
                Folder    = Get-ZinIniValue $ini 'Program' 'Folder' ''
                Exe       = Get-ZinIniValue $ini 'Program' 'Exe' ''
                Args      = Get-ZinIniValue $ini 'Program' 'Args' ''
                Desktop   = (Get-ZinIniValue $ini 'Program' 'Desktop' '0') -eq '1'
                LoadToRam = (Get-ZinIniValue $ini 'Program' 'LoadToRam' '1') -eq '1'
                Arch      = Get-ZinIniValue $ini 'Program' 'Arch' 'x64'
                Shortcuts = @($p.Keys | Where-Object { $_ -match '^Shortcut\d+$' } | ForEach-Object { $p[$_] })
                Dir       = $f.DirectoryName
                Enabled   = (Get-ZinIniValue $ini 'Program' 'Enabled' '1') -eq '1'
            }
        } catch { Write-ZinLog "Bad manifest $($f.FullName): $($_.Exception.Message)" 'WARN' }
    }
}

function Install-Program($P, [string]$Mode, [string]$SevenZip) {
    <#
      .7z  -> extracted to X:\Programs\<Name>
      .wim -> Normal: mounted read-only (dism) ; FullRAM / LoadToRam=1: applied to RAM
      Folder= (no archive) -> run in place from USB ; FullRAM copies it to RAM
    #>
    $dest = Join-Path $ProgramsRam ($P.Name -replace '[\\/:*?"<>|]', '_')
    $baseDir = $null
    $toRam = $P.LoadToRam -or $Mode -eq 'FullRAM'
    if ($P.Archive) {
        $arc = Join-Path $P.Dir $P.Archive
        if (-not (Test-Path $arc)) { Write-ZinLog "Archive missing: $arc" 'WARN'; return $null }
        if ($arc -like '*.wim') {
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            if ($toRam) { & dism.exe /Apply-Image "/ImageFile:$arc" /Index:1 "/ApplyDir:$dest" /English | Out-Null }
            else { & dism.exe /Mount-Image "/ImageFile:$arc" /Index:1 "/MountDir:$dest" /ReadOnly /English | Out-Null }
            if ($LASTEXITCODE -ne 0) { Write-ZinLog "dism failed ($LASTEXITCODE) for $arc" 'WARN'; return $null }
        } else {
            if (-not $SevenZip) { Write-ZinLog "7z.exe missing, cannot unpack $arc" 'ERROR'; return $null }
            $out = & $SevenZip x -y "-o$dest" $arc 2>&1
            if ($LASTEXITCODE -ne 0) { Write-ZinLog "7z failed for $arc : $($out | Select-Object -Last 1)" 'WARN'; return $null }
        }
        $baseDir = $dest
    } elseif ($P.Folder) {
        $src = Join-Path $P.Dir $P.Folder
        if (-not (Test-Path $src)) { Write-ZinLog "Folder missing: $src" 'WARN'; return $null }
        if ($Mode -eq 'FullRAM') { Copy-Item $src $dest -Recurse -Force; $baseDir = $dest } else { $baseDir = $src }
    } else {
        $baseDir = $P.Dir
    }
    $baseDir
}

function Add-ProgramShortcuts($P, [string]$BaseDir) {
    $items = @()
    if ($P.Exe) { $items += "$($P.Name)|$($P.Exe)|$($P.Args)" }
    $items += $P.Shortcuts
    $first = $true
    foreach ($s in $items) {
        $parts = $s.Split('|')
        $name = $parts[0]; $exe = Join-Path $BaseDir $parts[1]
        $arg = if ($parts.Count -gt 2) { $parts[2] } else { '' }
        if (-not (Test-Path $exe)) { Write-ZinLog "Exe not found for shortcut '$name': $exe" 'WARN'; continue }
        New-ZinShortcut -Path (Join-Path (Join-Path $StartMenu $P.Group) "$name.lnk") -Target $exe -Arguments $arg
        if ($first -and $P.Desktop) { New-ZinShortcut -Path (Join-Path $Desktop "$name.lnk") -Target $exe -Arguments $arg }
        $first = $false
    }
}

function Add-BuiltinShortcuts([string]$ScriptsDir, [string]$Icon) {
    $ps = Join-Path $PSHOME 'powershell.exe'
    $list = @(
        @{ Name = 'ZinSetup - Install Windows'; Script = 'zinsetup\ZinSetup.ps1'; Group = ''; Desktop = $true },
        @{ Name = 'FixBoot';                   Script = 'fixboot\FixBoot.ps1';   Group = 'System'; Desktop = $true },
        @{ Name = 'ZinDriver - Load drivers';  Script = 'zindriver\ZinDriver.ps1'; Args = '-Mode PE'; Group = 'System'; Desktop = $false },
        @{ Name = 'Machine info';              Script = 'tools\SysInfo.ps1';     Group = 'HWTest'; Desktop = $true },
        @{ Name = 'Quick hardware test';       Script = 'tools\QuickTest.ps1';   Group = 'HWTest'; Desktop = $true }
    )
    foreach ($s in $list) {
        $file = Join-Path $ScriptsDir $s.Script
        if (-not (Test-Path $file)) { continue }
        $a = "-NoProfile -ExecutionPolicy Bypass -File `"$file`""
        if ($s.ContainsKey('Args')) { $a += " $($s.Args)" }
        $grp = if ($s.Group) { Join-Path $StartMenu $s.Group } else { $StartMenu }
        New-ZinShortcut -Path (Join-Path $grp "$($s.Name).lnk") -Target $ps -Arguments $a -Icon $Icon
        if ($s.Desktop) { New-ZinShortcut -Path (Join-Path $Desktop "$($s.Name).lnk") -Target $ps -Arguments $a -Icon $Icon }
    }
}

function Start-ZinNetwork {
    $pen = @('X:\Programs\PENetwork\PENetwork.exe', 'X:\Program Files\PENetwork\PENetwork.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($pen) { Start-Process $pen -ArgumentList '/minimized' -ErrorAction SilentlyContinue }
    else { & wpeutil.exe InitializeNetwork 2>&1 | Out-Null }
}

#endregion

#region Main -----------------------------------------------------------------
$t0 = Get-Date
$zinData = Find-ZinData
$cfg = Get-ZinConfig -ZinData $zinData
if (-not $Mode) { $Mode = Read-BootMode $cfg.Mode }
if (-not $Mode) { $Mode = 'Normal' }

$logDir = if ($zinData) { Join-Path $zinData 'ZinPE\Logs' } else { 'X:\Windows\Temp' }
try { Set-ZinLogFile (Join-Path $logDir 'loader.log') } catch { Set-ZinLogFile 'X:\Windows\Temp\loader.log' }
$version = Get-ZinVersion -ZinData $zinData
Write-ZinLog "=== ZinWinPE Loader $version, mode=$Mode, firmware=$(Get-ZinFirmwareType) ==="

$brand = @('X:\ZinPE\branding', "$zinData\ZinPE\Config\branding") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $NoSplash) { Show-Splash -LogoPath $(if ($brand) { Join-Path $brand 'logo-128.png' }) -Version $version }

Set-Status 'Time zone...'
& tzutil.exe /s $cfg.TimeZone 2>&1 | Out-Null
if ($brand) { Set-ZinWallpaper -Source (Join-Path $brand 'wallpaper-1920x1080.png') -Version $version -Mode $Mode }

if (-not $zinData) {
    Write-ZinLog 'ZINDATA (ZinPE\zinpe.tag) not found - running with built-in tools only' 'WARN'
} else {
    [Environment]::SetEnvironmentVariable('ZINDATA', $zinData, 'Machine')
    $env:ZINDATA = $zinData
    Write-ZinLog "ZINDATA = $zinData"
}

if ($Mode -ne 'Safe' -and $zinData -and $cfg.LoadPeDrivers -eq '1') {
    Set-Status 'Loading drivers...'
    try { Invoke-ZinDriverPE -ZinData $zinData | Out-Null } catch { Write-ZinLog "Driver load error: $($_.Exception.Message)" 'ERROR' }
}

$scriptsDir = $ScriptsRoot
if ($Mode -eq 'FullRAM' -and $zinData) {
    # Copy scripts + config to RAM so the USB can be removed.
    Set-Status 'Copying ZinPE to RAM...'
    foreach ($d in @('Scripts', 'Lang', 'Config', 'Presets', 'Unattend')) {
        $src = Join-Path $zinData "ZinPE\$d"
        if (Test-Path $src) { Copy-Item $src "X:\ZinPE\$d" -Recurse -Force }
    }
    $scriptsDir = 'X:\ZinPE\Scripts'
}

$icon = if ($brand) { Join-Path $brand 'zinwinpe.ico' } else { '' }
Add-BuiltinShortcuts -ScriptsDir $scriptsDir -Icon $icon

if ($Mode -ne 'Safe' -and $zinData) {
    $sevenZip = Find-ZinTool '7z.exe'
    $wow64 = Test-Path 'X:\Windows\SysWOW64\kernel32.dll'
    $progs = @(Get-ProgramManifests $zinData | Where-Object { $_.Enabled })
    $i = 0
    foreach ($p in $progs) {
        $i++
        if ($p.Arch -eq 'x86' -and -not $wow64) { Write-ZinLog "Skip x86 tool (no WoW64): $($p.Name)"; continue }
        Set-Status ("Tools {0}/{1}: {2}" -f $i, $progs.Count, $p.Name)
        $base = Install-Program -P $p -Mode $Mode -SevenZip $sevenZip
        if ($base) { Add-ProgramShortcuts -P $p -BaseDir $base }
    }
    Write-ZinLog "Tools processed: $($progs.Count)"
}

if ($Mode -ne 'Safe' -and $cfg.StartNetwork -eq '1') {
    Set-Status 'Network...'
    Start-ZinNetwork
    # Time sync waits for DHCP; run it in the background so the desktop is not delayed.
    $ntp = $cfg.NtpServer
    Start-Job -ScriptBlock {
        param($m, $s, $f)
        Import-Module $m -DisableNameChecking
        Set-ZinLogFile $f
        Start-Sleep -Seconds 5
        Sync-ZinTime -Server $s | Out-Null
    } -ArgumentList (Join-Path $ScriptsRoot 'common\ZinCommon.psm1'), $ntp, (Get-ZinLogFile) -ErrorAction SilentlyContinue | Out-Null
}

Close-Splash
Write-ZinLog ("Loader finished in {0:N0}s" -f ((Get-Date) - $t0).TotalSeconds)
if (-not $NoExplorer -and -not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
#endregion
