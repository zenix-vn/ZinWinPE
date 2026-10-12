<#
.SYNOPSIS
  Captures a sysprepped Windows partition from inside ZinWinPE (design 8.7.1 step 6).
.EXAMPLE
  Capture-ShopImage.ps1 -Source C: -Name "Win11 Pro Shop 2026.10"
  -> ZINDATA\WIM\Win11-Pro-Shop-2026.10.wim (then merge with Merge-ShopImages.ps1 on the build machine)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Name,
    [string]$Description = '',
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'common\ZinCommon.psm1') -DisableNameChecking
$zd = Find-ZinData
if (-not $OutFile) {
    if (-not $zd) { throw 'ZINDATA not found - pass -OutFile' }
    $OutFile = Join-Path $zd ("WIM\{0}.wim" -f ($Name -replace '[^\w\.\-]+', '-'))
}
Set-ZinLogFile $(if ($zd) { Join-Path $zd 'ZinPE\Logs\capture.log' } else { Join-Path $env:TEMP 'capture.log' })
$root = $Source.TrimEnd('\') + '\'
if (-not (Test-Path "$root\Windows\System32\config\SYSTEM")) { throw "No Windows on $Source" }
if (Test-Path "$root\Windows\Setup\State\State.ini") {
    $state = Get-Content "$root\Windows\Setup\State\State.ini" -Raw
    if ($state -notmatch 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { Write-ZinLog "Image is not generalized (sysprep /generalize /oobe): $state" 'WARN' }
}
New-Item -ItemType Directory -Path (Split-Path $OutFile) -Force | Out-Null
$wimlib = Find-ZinTool 'wimlib-imagex.exe'
if ($wimlib) {
    $code = Invoke-ZinProcess -FilePath $wimlib -ArgumentList "capture $root `"$OutFile`" `"$Name`" `"$Description`" --compress=LZX --check --snapshot"
    if ($code -ne 0) { $code = Invoke-ZinProcess -FilePath $wimlib -ArgumentList "capture $root `"$OutFile`" `"$Name`" `"$Description`" --compress=LZX --check" }
} else {
    $code = Invoke-ZinProcess -FilePath 'dism.exe' -ArgumentList "/Capture-Image /ImageFile:`"$OutFile`" /CaptureDir:$root /Name:`"$Name`" /Compress:max /CheckIntegrity"
}
if ($code -ne 0) { throw "Capture failed ($code)" }
Write-ZinLog ("Captured {0} ({1:N2} GB)" -f $OutFile, ((Get-Item $OutFile).Length / 1GB))
