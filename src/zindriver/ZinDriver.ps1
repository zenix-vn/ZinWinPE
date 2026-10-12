<#
.SYNOPSIS
  ZinDriver - detect the machine and load/inject matching drivers (design 9.4).
.EXAMPLE
  ZinDriver.ps1 -Mode Info
  ZinDriver.ps1 -Mode PE
  ZinDriver.ps1 -Mode OS -WindowsRoot W:\ -Os win11
#>
[CmdletBinding()]
param(
    [ValidateSet('Info', 'PE', 'OS')][string]$Mode = 'Info',
    [string]$WindowsRoot,
    [ValidateSet('win10', 'win11')][string]$Os = 'win11',
    [string]$ZinData,
    [string]$LogFile
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ZinDriver.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $PSScriptRoot '..\common\ZinCommon.psm1') -DisableNameChecking

if (-not $ZinData) { $ZinData = Find-ZinData }
if (-not $LogFile) {
    $LogFile = if ($ZinData) { Join-Path $ZinData 'ZinPE\Logs\driver.log' } else { Join-Path $env:TEMP 'driver.log' }
}
Set-ZinLogFile $LogFile
Write-ZinLog "=== ZinDriver $Mode ==="

switch ($Mode) {
    'Info' {
        $info = Get-ZinMachineInfo
        $info | Select-Object Manufacturer, Model, FriendlyName, SKU, BaseBoard, MTM4, Serial, Firmware, SecureBoot, TPM | Format-List
        $missing = @(Get-ZinDevice -ProblemOnly)
        Write-Host "Devices without driver: $($missing.Count)"
        $missing | ForEach-Object { Write-Host ("  {0}  [{1}]" -f $_.Name, $_.HardwareIDs[0]) }
        if ($ZinData -and (Test-Path "$ZinData\ZinPE\Drivers\index.json")) {
            $rule = Find-ZinVendorPack -Info $info -Index (Read-ZinJson "$ZinData\ZinPE\Drivers\index.json") -Os $Os
            Write-Host ("Vendor pack: {0}" -f $(if ($rule) { $rule.path } else { '(none -> SDIO fallback)' }))
        }
    }
    'PE' {
        if (-not $ZinData) { Write-ZinLog 'ZINDATA not found' 'ERROR'; exit 2 }
        Invoke-ZinDriverPE -ZinData $ZinData | Out-Null
    }
    'OS' {
        if (-not $WindowsRoot -or -not (Test-Path (Join-Path $WindowsRoot 'Windows\System32'))) { Write-ZinLog "Invalid -WindowsRoot '$WindowsRoot'" 'ERROR'; exit 2 }
        if (-not $ZinData) { Write-ZinLog 'ZINDATA not found' 'ERROR'; exit 2 }
        $r = Invoke-ZinDriverOS -WindowsRoot $WindowsRoot -ZinData $ZinData -Os $Os
        $r | Format-List
    }
}
