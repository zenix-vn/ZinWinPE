<#
.SYNOPSIS
  Quick machine information (model, serial, CPU, RAM, disks + SMART status, battery wear, OEM key).
  Design P2 "Cong cu xem nhanh thong tin may". -Save writes it to ZINDATA\Reports.
#>
[CmdletBinding()]
param([switch]$Save, [switch]$NoPause)
$ScriptsRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ScriptsRoot 'common\ZinCommon.psm1') -DisableNameChecking -Force

$i = Get-ZinMachineInfo
$r = Test-ZinWin11Ready -Info $i
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("Manufacturer : $($i.Manufacturer)")
$lines.Add("Model        : $($i.FriendlyName)  ($($i.Model))  SKU $($i.SKU)")
$lines.Add("Serial       : $($i.Serial)")
$lines.Add("BIOS         : $($i.BiosVersion)  |  $($i.Firmware)  |  Secure Boot $($i.SecureBoot)  |  TPM $($i.TPM)")
$lines.Add("CPU          : $($i.CPU)")
$lines.Add("RAM          : $($i.RamGB) GB")
try {
    Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
        $lines.Add(("  slot {0,-12} {1,5} GB  {2} MHz  {3}" -f $_.DeviceLocator, [math]::Round($_.Capacity / 1GB), $_.Speed, "$($_.PartNumber)".Trim()))
    }
} catch { }
foreach ($d in $i.Disks) {
    $health = ''
    try {
        $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq "$($d.Number)" }
        if ($pd) {
            $health = "$($pd.HealthStatus) $($pd.MediaType)"
            $rel = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            if ($rel) { $health += ("  wear {0}%  temp {1}C  power-on {2}h" -f $rel.Wear, $rel.Temperature, $rel.PowerOnHours) }
        }
    } catch { }
    $lines.Add(("Disk {0}       : {1}  {2} GB  {3}  {4}  {5}" -f $d.Number, $d.Model, $d.SizeGB, $d.Bus, $d.Style, $health))
}
foreach ($b in $i.Batteries) { $lines.Add("Battery      : design $($b.DesignmWh) mWh, full $($b.FullmWh) mWh, wear $($b.WearPercent)%") }
try {
    Get-CimInstance Win32_VideoController | ForEach-Object { $lines.Add("GPU          : $($_.Name)  $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)") }
    Get-CimInstance Win32_NetworkAdapter -Filter 'PhysicalAdapter=True' | ForEach-Object { $lines.Add("Network      : $($_.Name)  $($_.MACAddress)") }
} catch { }
$lines.Add("OEM key      : $(if ($i.OemKey) { $i.OemKey } else { '(none)' })")
$lines.Add("Windows 11   : $(if ($r.Ready) { 'OK' } else { 'NOT ready - ' + ($r.Reasons -join ', ') })")
$missing = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
$lines.Add("No driver    : $($missing.Count) device(s)")
$missing | ForEach-Object { $lines.Add("  - $($_.Name)  [$(@($_.HardwareID)[0])]") }

$lines | ForEach-Object { Write-Host $_ }
if ($Save) {
    $zd = Find-ZinData
    if ($zd) {
        $p = Join-Path $zd ("Reports\{0}_{1:yyyyMMdd-HHmm}_info.txt" -f ($i.Serial -replace '[^\w\-]', '_'), (Get-Date))
        Write-ZinUtf8File -Path $p -Content ($lines -join "`r`n")
        Write-Host "Saved: $p" -ForegroundColor Green
    }
}
if (-not $NoPause) { Read-Host 'Enter' | Out-Null }
