<#
.SYNOPSIS
  Prepares the quick-install image (design 8.5 "image chuan bi san", 9.5 "gop image"):
  exports the chosen editions/shop images into ONE solid-compressed install.esd, optionally after
  servicing them (cumulative update .msu, .NET 3.5) - run on the Windows build machine as admin.
.EXAMPLE
  .\Merge-ShopImages.ps1 -Sources @(
      @{ File = 'D:\iso-src\Win11_25H2\sources\install.wim'; Edition = 'Windows 11 Pro' },
      @{ File = 'D:\iso-src\Win11_25H2\sources\install.wim'; Edition = 'Windows 11 Home' },
      @{ File = 'E:\WIM\Win11-Pro-Shop-2026.10.wim'; Index = 1 },
      @{ File = 'D:\iso-src\Win10_22H2\sources\install.wim'; Edition = 'Windows 10 Pro' }
    ) -UpdatesDir D:\updates\win11 -Sxs D:\iso-src\Win11_25H2\sources\sxs -Out D:\ZinWinPE\out\ZINDATA\ISO\Windows\install.esd
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][hashtable[]]$Sources,
    [Parameter(Mandatory)][string]$Out,
    [string]$UpdatesDir,
    [string]$Sxs,
    [string]$Wimlib = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'work\pkg\wimlib\wimlib-imagex.exe'),
    [string]$MountDir = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'work\mount-img')
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Wimlib)) { throw "wimlib-imagex.exe not found ($Wimlib) - run packages\build.ps1 -Only wimlib" }
$tmp = Join-Path (Split-Path $Out) 'merge-work'
New-Item -ItemType Directory -Path $tmp, $MountDir -Force | Out-Null
if (Test-Path $Out) { Remove-Item $Out -Force }
$stamp = Get-Date -Format 'yyyy.MM'
$i = 0
foreach ($s in $Sources) {
    $i++
    $idx = $s.Index
    if (-not $idx) {
        $info = & dism.exe /English /Get-WimInfo "/WimFile:$($s.File)"
        $cur = $null
        foreach ($l in $info) { if ($l -match '^Index : (\d+)') { $cur = [int]$Matches[1] } elseif ($l -match '^Name : (.+)$' -and $Matches[1].Trim() -eq $s.Edition) { $idx = $cur; break } }
        if (-not $idx) { throw "Edition '$($s.Edition)' not in $($s.File)" }
    }
    $one = Join-Path $tmp "img$i.wim"
    & dism.exe /English /Export-Image "/SourceImageFile:$($s.File)" "/SourceIndex:$idx" "/DestinationImageFile:$one" /Compress:max | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Export failed: $($s.File) [$idx]" }
    if ($UpdatesDir -or $Sxs) {
        & dism.exe /English /Mount-Image "/ImageFile:$one" /Index:1 "/MountDir:$MountDir" | Out-Null
        try {
            if ($Sxs) { & dism.exe /English "/Image:$MountDir" /Enable-Feature /FeatureName:NetFx3 /All "/Source:$Sxs" /LimitAccess | Out-Null }
            if ($UpdatesDir) {
                foreach ($u in Get-ChildItem $UpdatesDir -Include *.msu, *.cab -Recurse | Sort-Object Name) {
                    Write-Host "  + $($u.Name)"
                    & dism.exe /English "/Image:$MountDir" /Add-Package "/PackagePath:$($u.FullName)" | Out-Null
                }
                & dism.exe /English "/Image:$MountDir" /Cleanup-Image /StartComponentCleanup /ResetBase | Out-Null
            }
            & dism.exe /English /Unmount-Image "/MountDir:$MountDir" /Commit | Out-Null
        } catch { & dism.exe /Unmount-Image "/MountDir:$MountDir" /Discard | Out-Null; throw }
    }
    $name = if ($s.Name) { $s.Name } elseif ($s.Edition) { "$($s.Edition) $stamp" } else { $null }
    $wlArgs = @('export', $one, '1', $Out)
    if ($name) { $wlArgs += $name }
    $wlArgs += '--solid'
    & $Wimlib @wlArgs
    if ($LASTEXITCODE -ne 0) { throw "wimlib export failed for $one" }
    Remove-Item $one -Force
}
Remove-Item $tmp -Recurse -Force
& $Wimlib info $Out
