<#
.SYNOPSIS
  Assembles a ZinWinPE release (design 11.3 B3-B7) on the Windows build machine.
.DESCRIPTION
  Input : boot.wim built by PhoenixPE (builder\phoenixpe\README.md), Windows ADK, GRUB2 output from WSL.
  Output: out\ZinWinPE-<ver>\ZINBOOT\  out\ZinWinPE-<ver>\ZINDATA\  SHA256SUMS.txt
          out\ZinWinPE-<ver>-USB.zip (-Zip)   out\ZinWinPE-<ver>.iso (-Iso)
  Steps (each can be skipped):
    1. boot.wim -> T1 drivers + ZinPE scripts -> boot11.wim          (inject-t1.ps1)
    2. ZINBOOT: bootmgr, EFI files (CA 2011 + CA 2023 sets), boot.sdi, fonts, BCD (New-ZinBcd.ps1)
    3. GRUB2 + shim from out\grub\ZINBOOT (boot\build-grub.sh in WSL)
    4. ZINDATA: scripts, lang, config, presets, unattend, branding, (+ Programs/Apps/Drivers built separately)
    5. SHA256SUMS, zip, ISO
.EXAMPLE
  .\Build-ZinWinPE.ps1 -BootWim D:\PhoenixPE\Target\sources\boot.wim -Zip -Iso
#>
[CmdletBinding()]
param(
    [string]$BootWim,
    [string]$T1Drivers = (Join-Path (Split-Path -Parent $PSScriptRoot) 'drivers\store\T1'),
    [ValidateSet('2023', '2011')][string]$DefaultBootFiles = '2023',
    [string]$AdkRoot = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit",
    [switch]$SkipWim,
    [switch]$Zip,
    [switch]$Iso
)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $Repo 'src\common\ZinCommon.psm1') -DisableNameChecking
Set-ZinLogFile (Join-Path $Repo 'out\logs\build.log')
$Version = (Get-Content (Join-Path $Repo 'VERSION') -TotalCount 1).Trim()
$Rel = Join-Path $Repo "out\ZinWinPE-$Version"
$ZB = Join-Path $Rel 'ZINBOOT'
$ZD = Join-Path $Rel 'ZINDATA'
$Oscdimg = Join-Path $AdkRoot 'Deployment Tools\amd64\Oscdimg'
$PeMedia = Join-Path $AdkRoot 'Windows Preinstallation Environment\amd64\Media'
Write-ZinLog "=== Build ZinWinPE $Version ==="
New-Item -ItemType Directory -Path $ZB, $ZD -Force | Out-Null

# --- helper binaries for scripts in PE (7z, wimlib) -> out\bin ----------------------
$bin = Join-Path $Repo 'out\bin'
New-Item -ItemType Directory -Path $bin -Force | Out-Null
foreach ($f in @("$env:ProgramFiles\7-Zip\7z.exe", "$env:ProgramFiles\7-Zip\7z.dll")) { if (Test-Path $f) { Copy-Item $f $bin -Force } }
$wl = Join-Path $Repo 'work\pkg\wimlib'
if (Test-Path $wl) { Copy-Item "$wl\wimlib-imagex.exe", "$wl\libwim-15.dll" $bin -Force -ErrorAction SilentlyContinue }
if (-not (Test-Path "$bin\wimlib-imagex.exe")) { Write-ZinLog 'wimlib-imagex.exe not staged (packages\build.ps1 -Only wimlib) - ZinSetup will fall back to dism' 'WARN' }

# --- 1. boot11.wim --------------------------------------------------------------------
$wimOut = Join-Path $ZB 'ZinPE\boot11.wim'
if (-not $SkipWim) {
    if (-not $BootWim) { throw '-BootWim is required (PhoenixPE output), or use -SkipWim' }
    New-Item -ItemType Directory -Path (Split-Path $wimOut) -Force | Out-Null
    & (Join-Path $PSScriptRoot 'inject-t1.ps1') -BootWim $BootWim -T1Drivers $T1Drivers -OutWim $wimOut
}
Set-Content -Path (Join-Path $ZB 'ZinPE\version.txt') -Value $Version -Encoding ASCII

# --- 2. boot files ---------------------------------------------------------------------
# Taken from the ADK WinPE media (matches the ADK version). The CA 2023 set (bootmgfw_EX / *_EX) ships
# with recent ADK/Windows 11 builds - verify the current Microsoft guidance (design 5.3, KB5025885).
if (-not (Test-Path $PeMedia)) { throw "ADK WinPE media not found: $PeMedia" }
Copy-Item "$PeMedia\bootmgr" $ZB -Force
New-Item -ItemType Directory -Path "$ZB\Boot", "$ZB\EFI\Boot", "$ZB\EFI\Microsoft\Boot", "$ZB\EFI\zin\ca2011", "$ZB\EFI\zin\ca2023" -Force | Out-Null
Copy-Item "$PeMedia\Boot\boot.sdi" "$ZB\Boot\" -Force
Copy-Item "$PeMedia\Boot\Fonts" "$ZB\Boot\" -Recurse -Force
Copy-Item "$PeMedia\EFI\Microsoft\Boot\Fonts" "$ZB\EFI\Microsoft\Boot\" -Recurse -Force
Copy-Item "$PeMedia\EFI\Boot\bootx64.efi" "$ZB\EFI\zin\ca2011\bootx64.efi" -Force
$ex = @("$PeMedia\EFI_EX\Boot\bootx64_EX.efi", "$PeMedia\EFI_EX\Boot\bootx64.efi") | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($ex) { Copy-Item $ex "$ZB\EFI\zin\ca2023\bootx64.efi" -Force } else { Write-ZinLog 'CA 2023 bootx64 (EFI_EX) not in this ADK - only the CA 2011 set is available' 'WARN' }
$fontsEx = "$PeMedia\EFI_EX\Microsoft\Boot\Fonts_EX"
if (Test-Path $fontsEx) { Copy-Item $fontsEx "$ZB\EFI\zin\ca2023\Fonts" -Recurse -Force }
$use = if ($DefaultBootFiles -eq '2023' -and (Test-Path "$ZB\EFI\zin\ca2023\bootx64.efi")) { 'ca2023' } else { 'ca2011' }
Copy-Item "$ZB\EFI\zin\$use\bootx64.efi" "$ZB\EFI\Boot\bootx64.efi" -Force
Copy-Item "$ZB\EFI\zin\$use\bootx64.efi" "$ZB\EFI\Microsoft\Boot\bootmgfw.efi" -Force
Set-Content "$ZB\EFI\zin\bootfiles.txt" $use -Encoding ASCII
Write-ZinLog "Default UEFI boot files: $use (the Installer can switch to the other set)"
& (Join-Path $PSScriptRoot 'New-ZinBcd.ps1') -ZinBoot $ZB

# --- 3. GRUB2 + shim (built in WSL) -----------------------------------------------
$grub = Join-Path $Repo 'out\grub\ZINBOOT'
if (Test-Path $grub) { Copy-Item "$grub\*" $ZB -Recurse -Force; Write-ZinLog 'GRUB2/shim merged' }
else { Write-ZinLog 'out\grub\ZINBOOT missing - run boot/build-grub.sh in WSL (menu phu disabled)' 'WARN' }

# --- 4. ZINDATA payload ------------------------------------------------------------
$zp = Join-Path $ZD 'ZinPE'
New-Item -ItemType Directory -Path "$zp\Logs", "$ZD\Reports", "$ZD\ISO\Windows", "$ZD\ISO\Linux", "$ZD\ISO\Tools", "$ZD\Backup" -Force | Out-Null
if (Test-Path "$zp\Scripts") { Remove-Item "$zp\Scripts" -Recurse -Force }
Copy-Item (Join-Path $Repo 'src') "$zp\Scripts" -Recurse -Force
if (Test-Path $bin) { Copy-Item $bin "$zp\Scripts\bin" -Recurse -Force }
Copy-Item (Join-Path $Repo 'src\lang') "$zp\Lang" -Recurse -Force
New-Item -ItemType Directory -Path "$zp\Config", "$zp\Presets", "$zp\Unattend" -Force | Out-Null
foreach ($f in @('zinpe.ini', 'DefaultAppAssociations.xml')) {
    # Never overwrite a shop's edited config on rebuild.
    if (-not (Test-Path "$zp\Config\$f")) { Copy-Item (Join-Path $Repo "config\$f") "$zp\Config\" }
}
Copy-Item (Join-Path $Repo 'config\Presets\*') "$zp\Presets\" -Force
Copy-Item (Join-Path $Repo 'config\Unattend\*') "$zp\Unattend\" -Force
Copy-Item (Join-Path $Repo 'assets\branding') "$zp\Config\branding" -Recurse -Force
Copy-Item (Join-Path $Repo 'assets\branding\zinwinpe.ico') $zp -Force
Copy-Item (Join-Path $Repo 'config\zinpe.tag') $zp -Force
Copy-Item (Join-Path $Repo 'config\autorun.inf') $ZD -Force
Copy-Item (Join-Path $Repo 'docs\user-guide.md'), (Join-Path $Repo 'docs\mok-enroll.md') $ZD -Force -ErrorAction SilentlyContinue
Set-Content "$zp\version.txt" $Version -Encoding ASCII
foreach ($d in @('Programs', 'Apps', 'Drivers')) {
    if (-not (Test-Path "$zp\$d")) { Write-ZinLog "ZINDATA\ZinPE\$d is empty - run the matching build script (packages / apps / drivers)" 'WARN' }
}

# --- 5. hashes, zip, iso -------------------------------------------------------------
$sums = Join-Path $Rel 'SHA256SUMS.txt'
$important = @(Get-ChildItem $ZB -Recurse -File) + @(Get-ChildItem "$zp\Scripts" -Recurse -File)
$important | ForEach-Object { '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash, $_.FullName.Substring($Rel.Length + 1) } | Set-Content $sums -Encoding ASCII
Write-ZinLog "SHA256SUMS: $($important.Count) files"

if ($Zip) {
    $zipFile = Join-Path $Repo "out\ZinWinPE-$Version-USB.zip"
    if (Test-Path $zipFile) { Remove-Item $zipFile }
    & "$env:ProgramFiles\7-Zip\7z.exe" a -tzip -mx=1 $zipFile "$Rel\*" | Out-Null
    Write-ZinLog "ZIP: $zipFile"
}
if ($Iso) {
    & (Join-Path $Repo 'src\installer\ZinInstaller.ps1') -Action Iso -Package $Rel -IsoPath (Join-Path $Repo "out\ZinWinPE-$Version.iso") -Yes
}
$wimSize = if (Test-Path $wimOut) { '{0:N2} GB' -f ((Get-Item $wimOut).Length / 1GB) } else { 'n/a' }
Write-ZinLog "Done: $Rel (boot11.wim $wimSize)"
