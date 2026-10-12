<#
.SYNOPSIS
  FixBoot - one-touch boot repair for UEFI and Legacy (design 7.5).
.DESCRIPTION
  Finds Windows installations, finds the matching EFI / active system partition on the
  same disk, backs up the old BCD, then rebuilds boot files with bcdboot
  (+ bootsect /nt60 /mbr for Legacy).
.EXAMPLE
  FixBoot.ps1                      # interactive
  FixBoot.ps1 -WindowsDrive D: -Firmware UEFI -Yes
#>
[CmdletBinding()]
param(
    [string]$WindowsDrive,
    [ValidateSet('Auto', 'UEFI', 'BIOS', 'ALL')][string]$Firmware = 'Auto',
    [string]$Locale = 'en-US',
    [string]$Lang,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
$ScriptsRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ScriptsRoot 'common\ZinCommon.psm1') -DisableNameChecking -Force

$zinData = Find-ZinData
Initialize-ZinLang -Code $Lang -ZinData $zinData
Set-ZinLogFile $(if ($zinData) { Join-Path $zinData 'ZinPE\Logs\fixboot.log' } else { Join-Path $env:TEMP 'fixboot.log' })
Write-ZinLog '=== FixBoot ==='

$EspGuid = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'

function Get-WindowsInstall {
    foreach ($v in Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne 'X' }) {
        $root = "$($v.DriveLetter):"
        if (-not (Test-Path "$root\Windows\System32\config\SYSTEM")) { continue }
        $part = Get-Partition -DriveLetter $v.DriveLetter -ErrorAction SilentlyContinue
        if (-not $part) { continue }
        $disk = Get-Disk -Number $part.DiskNumber
        $ver = ''
        try { $ver = (Get-Item "$root\Windows\System32\ntoskrnl.exe").VersionInfo.ProductVersion } catch { }
        [pscustomobject]@{
            Drive      = $root
            Label      = $v.FileSystemLabel
            SizeGB     = [math]::Round($v.Size / 1GB)
            DiskNumber = $part.DiskNumber
            DiskModel  = $disk.FriendlyName
            Style      = "$($disk.PartitionStyle)"
            Version    = $ver
        }
    }
}

function Get-SystemPartition($Install) {
    $parts = @(Get-Partition -DiskNumber $Install.DiskNumber)
    if ($Install.Style -eq 'GPT') {
        $esp = $parts | Where-Object { $_.GptType -eq $EspGuid } | Select-Object -First 1
        return $esp
    }
    $active = $parts | Where-Object { $_.IsActive } | Select-Object -First 1
    if ($active) { return $active }
    # No active partition: the Windows partition itself becomes the system partition.
    $parts | Where-Object { $_.DriveLetter -eq $Install.Drive.TrimEnd(':') } | Select-Object -First 1
}

function Mount-SystemPartition($Partition) {
    # Returns a drive letter (with colon) for the partition, assigning a free one when needed.
    if ($Partition.DriveLetter -and "$($Partition.DriveLetter)".Trim()) { return @{ Letter = "$($Partition.DriveLetter):"; Temp = $false } }
    $used = @(Get-Volume | Where-Object DriveLetter | ForEach-Object { "$($_.DriveLetter)" })
    $free = @('S', 'T', 'U', 'V', 'R', 'Q', 'P') | Where-Object { $used -notcontains $_ } | Select-Object -First 1
    Add-PartitionAccessPath -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -AccessPath "$($free):\"
    Start-Sleep -Milliseconds 500
    @{ Letter = "$($free):"; Temp = $true }
}

function Backup-Bcd([string]$SysLetter) {
    $dest = if ($zinData) { Join-Path $zinData ("Backup\BCD\{0:yyyyMMdd-HHmmss}" -f (Get-Date)) } else { Join-Path $env:TEMP 'BCD-backup' }
    foreach ($bcd in @("$SysLetter\EFI\Microsoft\Boot\BCD", "$SysLetter\Boot\BCD")) {
        if (Test-Path $bcd) {
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            $name = if ($bcd -like '*EFI*') { 'BCD-efi' } else { 'BCD-bios' }
            & bcdedit.exe /export (Join-Path $dest $name) 2>&1 | Out-Null
            Copy-Item $bcd (Join-Path $dest "$name.raw") -Force -ErrorAction SilentlyContinue
            Write-ZinLog "BCD backup: $bcd -> $dest"
        }
    }
}

# --- Select installation ---------------------------------------------------
$installs = @(Get-WindowsInstall)
if ($installs.Count -eq 0) { Write-ZinLog (Get-ZinText 'fixboot.no_windows') 'ERROR'; exit 1 }

$target = $null
if ($WindowsDrive) {
    $target = $installs | Where-Object { $_.Drive -eq $WindowsDrive.TrimEnd('\') } | Select-Object -First 1
    if (-not $target) { Write-ZinLog "No Windows on $WindowsDrive" 'ERROR'; exit 1 }
} elseif ($installs.Count -eq 1) {
    $target = $installs[0]
} else {
    Write-Host (Get-ZinText 'fixboot.choose')
    for ($i = 0; $i -lt $installs.Count; $i++) {
        $w = $installs[$i]
        Write-Host ("  [{0}] {1}  {2} GB  Windows {3}  (disk {4} {5}, {6})" -f ($i + 1), $w.Drive, $w.SizeGB, $w.Version, $w.DiskNumber, $w.DiskModel, $w.Style)
    }
    $n = [int](Read-Host '#')
    $target = $installs[$n - 1]
}

$fw = if ($Firmware -eq 'Auto') { Get-ZinFirmwareType } else { $Firmware }
Write-ZinLog ("Target {0} on disk {1} ({2}), firmware {3}" -f $target.Drive, $target.DiskNumber, $target.Style, $fw)

if ($target.Style -eq 'MBR' -and $fw -eq 'UEFI') { Write-ZinLog (Get-ZinText 'fixboot.mbr_uefi') 'WARN' }
if ($target.Style -eq 'GPT' -and $fw -eq 'BIOS') { Write-ZinLog (Get-ZinText 'fixboot.gpt_bios') 'WARN' }

$sys = Get-SystemPartition $target
if (-not $sys) { Write-ZinLog (Get-ZinText 'fixboot.no_system_partition') 'ERROR'; exit 1 }

if (-not $Yes) {
    $ans = Read-Host (Get-ZinText 'fixboot.confirm' @($target.Drive, $fw))
    if ($ans -notmatch '^(y|yes|c|co)$') { Write-ZinLog 'Cancelled by user'; exit 0 }
}

$m = Mount-SystemPartition $sys
try {
    Backup-Bcd $m.Letter
    $flag = switch ($fw) { 'UEFI' { 'UEFI' } 'BIOS' { 'BIOS' } default { 'ALL' } }
    if ($target.Style -eq 'GPT') { $flag = if ($fw -eq 'ALL') { 'ALL' } else { 'UEFI' } }

    if ($flag -ne 'UEFI') {
        # Legacy: make sure the system partition is active and the MBR/PBR use bootmgr.
        if ($target.Style -eq 'MBR' -and -not $sys.IsActive) {
            Set-Partition -DiskNumber $sys.DiskNumber -PartitionNumber $sys.PartitionNumber -IsActive $true
            Write-ZinLog "Partition $($sys.PartitionNumber) set active"
        }
        Invoke-ZinProcess -FilePath 'bootsect.exe' -ArgumentList "/nt60 $($m.Letter) /mbr /force" -Hidden | Out-Null
    }

    $code = Invoke-ZinProcess -FilePath 'bcdboot.exe' -ArgumentList "$($target.Drive)\Windows /s $($m.Letter) /f $flag /l $Locale" -Hidden
    if ($code -ne 0) {
        # A corrupted BCD makes bcdboot fail: rename it and retry once with a fresh store.
        foreach ($bcd in @("$($m.Letter)\EFI\Microsoft\Boot\BCD", "$($m.Letter)\Boot\BCD")) {
            if (Test-Path $bcd) { attrib -h -s -r $bcd; Rename-Item $bcd ("BCD.bad-{0:yyyyMMddHHmmss}" -f (Get-Date)) -Force }
        }
        $code = Invoke-ZinProcess -FilePath 'bcdboot.exe' -ArgumentList "$($target.Drive)\Windows /s $($m.Letter) /f $flag /l $Locale" -Hidden
    }
    if ($code -eq 0) { Write-ZinLog (Get-ZinText 'fixboot.done'); $result = 0 }
    else { Write-ZinLog (Get-ZinText 'fixboot.failed' @($code)) 'ERROR'; $result = 3 }
} finally {
    if ($m.Temp) {
        Remove-PartitionAccessPath -DiskNumber $sys.DiskNumber -PartitionNumber $sys.PartitionNumber -AccessPath "$($m.Letter)\" -ErrorAction SilentlyContinue
    }
}
if (-not $Yes) { Read-Host (Get-ZinText 'common.press_enter') | Out-Null }
exit $result
