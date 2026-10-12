<#
.SYNOPSIS
  Creates the two BCD stores of ZINBOOT (design 5.1, appendix B):
    \EFI\Microsoft\Boot\BCD  (UEFI: winload.efi)   and   \Boot\BCD (Legacy: winload.exe)
  Entries: ZinWinPE 11 x64 (ramdisk, default) | Menu phu GRUB2.
  "Boot from internal disk" has no native bootmgr entry type, so it lives in the GRUB2 menu.
.NOTES
  UEFI + Secure Boot: Windows Boot Manager only starts Microsoft-signed Windows boot apps, so the
  "GRUB2" BCD entry (shim, signed by the Microsoft 3rd-party UEFI CA) is expected to work only with
  Secure Boot OFF. With Secure Boot ON use the firmware one-time boot menu -> "Boot from file" ->
  \EFI\zin\shimx64.efi (docs/mok-enroll.md). Verify on real machines (TODO P1 / Boot).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ZinBoot,          # staging folder of the ZINBOOT partition
    [string]$WimPath = '\ZinPE\boot11.wim',
    [string]$Title = 'ZinWinPE 11 x64',
    [string]$Locale = 'en-US',
    [int]$Timeout = 5,
    [switch]$NoGrub
)
$ErrorActionPreference = 'Stop'

function Invoke-Bcd([string]$Store, [string[]]$BcdArgs) {
    $out = & bcdedit.exe /store $Store @BcdArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "bcdedit $($BcdArgs -join ' ') failed: $out" }
    "$out"
}

function New-Store([string]$Store, [ValidateSet('UEFI', 'BIOS')][string]$Fw) {
    if (Test-Path $Store) { Remove-Item $Store -Force }
    New-Item -ItemType Directory -Path (Split-Path $Store) -Force | Out-Null
    & bcdedit.exe /createstore $Store | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "createstore failed: $Store" }

    $bootmgrPath = if ($Fw -eq 'UEFI') { '\EFI\Microsoft\Boot\bootmgfw.efi' } else { $null }
    Invoke-Bcd $Store @('/create', '{bootmgr}', '/d', 'ZinWinPE Boot Manager') | Out-Null
    Invoke-Bcd $Store @('/set', '{bootmgr}', 'device', 'boot') | Out-Null
    Invoke-Bcd $Store @('/set', '{bootmgr}', 'locale', $Locale) | Out-Null
    Invoke-Bcd $Store @('/set', '{bootmgr}', 'timeout', "$Timeout") | Out-Null
    Invoke-Bcd $Store @('/set', '{bootmgr}', 'displaybootmenu', 'yes') | Out-Null
    if ($bootmgrPath) { Invoke-Bcd $Store @('/set', '{bootmgr}', 'path', $bootmgrPath) | Out-Null }

    Invoke-Bcd $Store @('/create', '{ramdiskoptions}', '/d', 'Ramdisk options') | Out-Null
    Invoke-Bcd $Store @('/set', '{ramdiskoptions}', 'ramdisksdidevice', 'boot') | Out-Null
    Invoke-Bcd $Store @('/set', '{ramdiskoptions}', 'ramdisksdipath', '\Boot\boot.sdi') | Out-Null

    $out = Invoke-Bcd $Store @('/create', '/d', $Title, '/application', 'osloader')
    $guid = [regex]::Match($out, '\{[0-9a-fA-F\-]{36}\}').Value
    $winload = if ($Fw -eq 'UEFI') { '\Windows\System32\boot\winload.efi' } else { '\Windows\System32\boot\winload.exe' }
    foreach ($kv in @(
            @('device', "ramdisk=[boot]$WimPath,{ramdiskoptions}"),
            @('osdevice', "ramdisk=[boot]$WimPath,{ramdiskoptions}"),
            @('path', $winload), @('systemroot', '\Windows'), @('locale', $Locale),
            @('winpe', 'yes'), @('detecthal', 'yes'), @('nx', 'OptIn'), @('ems', 'no'), @('bootmenupolicy', 'Legacy'))) {
        Invoke-Bcd $Store @('/set', $guid, $kv[0], $kv[1]) | Out-Null
    }
    Invoke-Bcd $Store @('/displayorder', $guid, '/addfirst') | Out-Null
    Invoke-Bcd $Store @('/default', $guid) | Out-Null

    if (-not $NoGrub) {
        if ($Fw -eq 'UEFI') {
            $o = Invoke-Bcd $Store @('/create', '/d', 'Menu phu (GRUB2) - MemTest / Linux / ISO', '/application', 'bootapp')
            $g = [regex]::Match($o, '\{[0-9a-fA-F\-]{36}\}').Value
            Invoke-Bcd $Store @('/set', $g, 'device', 'boot') | Out-Null
            Invoke-Bcd $Store @('/set', $g, 'path', '\EFI\zin\shimx64.efi') | Out-Null
        } else {
            # Legacy: bootmgr -> g2ldr.mbr -> g2ldr (GRUB2 lnxboot + core.img), built by boot/build-grub.sh
            $o = Invoke-Bcd $Store @('/create', '/d', 'Menu phu (GRUB2) - MemTest / Linux / ISO', '/application', 'bootsector')
            $g = [regex]::Match($o, '\{[0-9a-fA-F\-]{36}\}').Value
            Invoke-Bcd $Store @('/set', $g, 'device', 'boot') | Out-Null
            Invoke-Bcd $Store @('/set', $g, 'path', '\g2ldr.mbr') | Out-Null
        }
        Invoke-Bcd $Store @('/displayorder', $g, '/addlast') | Out-Null
    }
    Write-Host "BCD $Fw -> $Store ($guid)"
}

New-Store (Join-Path $ZinBoot 'EFI\Microsoft\Boot\BCD') 'UEFI'
New-Store (Join-Path $ZinBoot 'Boot\BCD') 'BIOS'
Get-ChildItem $ZinBoot -Recurse -Filter 'BCD.LOG*' -Force | Remove-Item -Force -ErrorAction SilentlyContinue
