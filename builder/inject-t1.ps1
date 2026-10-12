<#
.SYNOPSIS
  Customises the PhoenixPE boot.wim: T1 drivers, ZinPE scripts/branding, version (design 9.1 T1, 11.3 B2).
.DESCRIPTION
  mount -> dism /Add-Driver /Recurse (T1) -> copy X:\ZinPE\{Scripts,Lang,Unattend,branding,version.txt}
  -> unmount /Commit -> export /Compress:max -> size check (< 1.5 GB, design 3.1).
  Run as Administrator on the Windows build machine.
.EXAMPLE
  .\inject-t1.ps1 -BootWim D:\PhoenixPE\Target\sources\boot.wim -T1Drivers D:\ZinWinPE\drivers\store\T1 -OutWim D:\ZinWinPE\out\boot11.wim
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BootWim,
    [string]$T1Drivers,
    [Parameter(Mandatory)][string]$OutWim,
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$MountDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'work\mount'),
    [int]$Index = 1,
    [double]$MaxSizeGB = 1.5
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $RepoRoot 'src\common\ZinCommon.psm1') -DisableNameChecking
Set-ZinLogFile (Join-Path $RepoRoot 'out\logs\inject-t1.log')

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')) { throw 'Run as Administrator' }
if (-not (Test-Path $BootWim)) { throw "boot.wim not found: $BootWim" }
$version = (Get-Content (Join-Path $RepoRoot 'VERSION') -TotalCount 1).Trim()

New-Item -ItemType Directory -Path $MountDir -Force | Out-Null
if (Get-ChildItem $MountDir -Force | Select-Object -First 1) { throw "Mount dir not empty: $MountDir (dism /Cleanup-Wim ?)" }

$work = Join-Path (Split-Path -Parent $OutWim) 'boot-work.wim'
Copy-Item $BootWim $work -Force
Write-ZinLog "Mount $work [$Index] -> $MountDir"
& dism.exe /English /Mount-Image "/ImageFile:$work" "/Index:$Index" "/MountDir:$MountDir"
if ($LASTEXITCODE -ne 0) { throw "Mount failed ($LASTEXITCODE)" }
$commit = $false
try {
    if ($T1Drivers -and (Test-Path $T1Drivers)) {
        Write-ZinLog "Add T1 drivers from $T1Drivers"
        & dism.exe /English "/Image:$MountDir" /Add-Driver "/Driver:$T1Drivers" /Recurse
        if ($LASTEXITCODE -ne 0) { Write-ZinLog "dism /Add-Driver returned $LASTEXITCODE (some drivers may be skipped)" 'WARN' }
    } else { Write-ZinLog 'No T1 driver folder - skipped' 'WARN' }

    $zin = Join-Path $MountDir 'ZinPE'
    New-Item -ItemType Directory -Path $zin -Force | Out-Null
    # Embedded fallback copy; the loader prefers ZINDATA\ZinPE\Scripts when present.
    Copy-Item (Join-Path $RepoRoot 'src') (Join-Path $zin 'Scripts') -Recurse -Force
    Copy-Item (Join-Path $RepoRoot 'src\lang') (Join-Path $zin 'Lang') -Recurse -Force
    Copy-Item (Join-Path $RepoRoot 'config\Unattend') (Join-Path $zin 'Unattend') -Recurse -Force
    Copy-Item (Join-Path $RepoRoot 'config\Presets') (Join-Path $zin 'Presets') -Recurse -Force
    Copy-Item (Join-Path $RepoRoot 'assets\branding') (Join-Path $zin 'branding') -Recurse -Force
    Set-Content -Path (Join-Path $zin 'version.txt') -Value $version -Encoding ASCII
    # Helper binaries used by the scripts (7z.exe, wimlib-imagex.exe + libwim-15.dll) if staged by Build-ZinWinPE.
    $bin = Join-Path $RepoRoot 'out\bin'
    if (Test-Path $bin) { Copy-Item $bin (Join-Path $zin 'Scripts\bin') -Recurse -Force }
    Copy-Item (Join-Path $RepoRoot 'assets\branding\wallpaper-1920x1080.png') (Join-Path $MountDir 'Windows\Web\Wallpaper\zinwinpe.png') -Force -ErrorAction SilentlyContinue
    $commit = $true
} finally {
    $mode = if ($commit) { '/Commit' } else { '/Discard' }
    & dism.exe /English /Unmount-Image "/MountDir:$MountDir" $mode
    if ($LASTEXITCODE -ne 0) { Write-ZinLog "Unmount returned $LASTEXITCODE - run dism /Cleanup-Wim" 'ERROR' }
}

Write-ZinLog "Export (max compression) -> $OutWim"
if (Test-Path $OutWim) { Remove-Item $OutWim -Force }
& dism.exe /English /Export-Image "/SourceImageFile:$work" "/SourceIndex:$Index" "/DestinationImageFile:$OutWim" /Compress:max /Bootable
if ($LASTEXITCODE -ne 0) { throw "Export failed ($LASTEXITCODE)" }
Remove-Item $work -Force

$size = (Get-Item $OutWim).Length / 1GB
Write-ZinLog ("boot11.wim = {0:N2} GB" -f $size)
if ($size -gt $MaxSizeGB) { Write-ZinLog ("boot.wim is larger than {0} GB - remove components/drivers (design 3.1, RAM 4 GB target)" -f $MaxSizeGB) 'WARN' }
