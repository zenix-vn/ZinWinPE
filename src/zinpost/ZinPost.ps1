<#
.SYNOPSIS
  ZinPost - first-boot post-install (design 8.7.2 / 9.6 phase 2). Lives in C:\ZinPost.
.DESCRIPTION
  -Phase System : from SetupComplete.cmd (SYSTEM) or FirstLogonCommands (fallback).
                  SDIO for missing drivers -> apps with RunAs=system -> optional winget upgrade.
  -Phase User   : from FirstLogonCommands. Apps with RunAs=user, then cleanup + optional reboot.
  Flags system.done / user.done / done.flag prevent running twice (design 8.7.3).
#>
[CmdletBinding()]
param(
    [ValidateSet('System', 'User')][string]$Phase = 'System',
    [switch]$Force
)
$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
Import-Module (Join-Path $Root 'ZinCommon.psm1') -DisableNameChecking -Force
Set-ZinLogFile (Join-Path $Root 'post.log')

$cfgFile = Join-Path $Root 'zinpost.json'
if (-not (Test-Path $cfgFile)) { Write-ZinLog 'zinpost.json missing' 'ERROR'; exit 1 }
$cfg = Read-ZinJson $cfgFile
$flag = Join-Path $Root ("{0}.done" -f $Phase.ToLower())
if ((Test-Path $flag) -and -not $Force) { Write-ZinLog "Phase $Phase already done - skip"; exit 0 }
Write-ZinLog "=== ZinPost phase $Phase (user: $env:USERNAME) ==="

function Test-Detect([string]$Path) {
    if (-not $Path) { return $false }
    Test-Path ([Environment]::ExpandEnvironmentVariables($Path))
}

function Install-App($a) {
    $dir = Join-Path $Root "Apps\$($a.Id)"
    if (Test-Detect $a.DetectPath) { Write-ZinLog "$($a.Id): already installed"; return 'present' }
    if ("$($a.Args)".Trim().StartsWith('(')) {
        # Manifest still has a placeholder like "(needs testing: --silent?)" - never run an installer interactively.
        Write-ZinLog "$($a.Id): silent args not verified yet ($($a.Args)) - skipped" 'WARN'; return 'unverified'
    }
    $appArgs = [Environment]::ExpandEnvironmentVariables("$($a.Args)")
    $codes = @()
    switch ($a.Type) {
        'msi' {
            foreach ($inst in "$($a.Installer)".Split(';')) {
                $codes += Invoke-ZinProcess -FilePath 'msiexec.exe' -ArgumentList "/i `"$(Join-Path $dir $inst.Trim())`" $appArgs" -Hidden
            }
        }
        'exe' {
            foreach ($inst in "$($a.Installer)".Split(';')) {
                $codes += Invoke-ZinProcess -FilePath (Join-Path $dir $inst.Trim()) -ArgumentList $appArgs -WorkingDirectory $dir
            }
        }
        'odt' {
            $cfgXml = ($appArgs -replace '^/configure\s+', '').Trim()
            $codes += Invoke-ZinProcess -FilePath (Join-Path $dir 'setup.exe') -ArgumentList "/configure `"$(Join-Path $dir $cfgXml)`"" -WorkingDirectory $dir
        }
        'feature' {
            # NetFx3 that could not be enabled offline: online from Windows Update.
            $codes += Invoke-ZinProcess -FilePath 'dism.exe' -ArgumentList '/Online /Enable-Feature /FeatureName:NetFx3 /All /NoRestart /English' -Hidden
        }
        'winget' {
            $codes += Invoke-ZinProcess -FilePath 'winget.exe' -ArgumentList "install --id $($a.Winget) -e --silent --accept-package-agreements --accept-source-agreements" -Hidden
        }
        default { Write-ZinLog "$($a.Id): Type '$($a.Type)' not handled in ZinPost" 'WARN'; return 'skipped' }
    }
    # 3010 = success, reboot required ; 1641 = reboot initiated
    $ok = @($codes | Where-Object { $_ -ne 0 -and $_ -ne 3010 -and $_ -ne 1641 }).Count -eq 0
    if ($a.DetectPath) { $ok = Test-Detect $a.DetectPath }
    if ($ok) { Write-ZinLog "$($a.Id): OK"; 'ok' } else { Write-ZinLog "$($a.Id): FAILED (exit $($codes -join ','))" 'ERROR'; 'failed' }
}

function Invoke-Sdio {
    # SDIO lives on the USB (too big to copy); runs only if the ZinWinPE USB is still plugged in.
    $zd = Find-ZinData
    if (-not $zd) { Write-ZinLog 'ZinWinPE USB not present - SDIO skipped'; return }
    $sdioDir = Join-Path $zd 'ZinPE\Drivers\OS\Generic\SDIO'
    $exe = Get-ChildItem $sdioDir -Filter 'SDIO_x64*.exe' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $exe) { Write-ZinLog "SDIO not found in $sdioDir" 'WARN'; return }
    $script = Join-Path $Root 'sdio-script.txt'
    # SDIO scripting: install only drivers for devices that have none (Verify=1: confirm on real machines).
    @('logging on', 'enableinstall on', 'init', 'select missing', 'install', 'end') | Set-Content -Path $script -Encoding ASCII
    Invoke-ZinProcess -FilePath $exe.FullName -ArgumentList "-script:`"$script`"" -WorkingDirectory $sdioDir | Out-Null
}

function Get-Missing {
    @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -eq 28 } | ForEach-Object { $_.Name })
}

$results = [ordered]@{}
$apps = @($cfg.apps)

if ($Phase -eq 'System') {
    if ($cfg.runSdio) { Invoke-Sdio }
    foreach ($a in $apps | Where-Object { $_.RunAs -ne 'user' }) { $results[$a.Id] = Install-App $a }
    if ($cfg.wingetUpgrade -and (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        foreach ($a in $apps | Where-Object { $_.Winget }) {
            foreach ($id in "$($a.Winget)".Split(';')) {
                Invoke-ZinProcess -FilePath 'winget.exe' -ArgumentList "upgrade --id $($id.Trim()) -e --silent --accept-package-agreements --accept-source-agreements" -Hidden | Out-Null
            }
        }
    }
} else {
    foreach ($a in $apps | Where-Object { $_.RunAs -eq 'user' }) { $results[$a.Id] = Install-App $a }
}

Set-Content -Path $flag -Value (Get-Date -Format s)

# Report
$report = Join-Path $Root 'report.txt'
$lines = @('', "---- ZinPost phase $Phase ($(Get-Date -Format 'yyyy-MM-dd HH:mm')) ----")
foreach ($k in $results.Keys) { $lines += ('  {0,-14} {1}' -f $k, $results[$k]) }
if ($Phase -eq 'User') { foreach ($m in Get-Missing) { $lines += "  missing driver: $m" } }
Add-Content -Path $report -Value $lines -Encoding UTF8
# Copy the report back to the USB when it is still plugged in.
$zd = Find-ZinData
if ($zd) {
    try {
        $serial = ((Get-CimInstance Win32_BIOS).SerialNumber -replace '[^\w\-]', '_')
        Copy-Item $report (Join-Path $zd ("Reports\{0}_{1:yyyyMMdd-HHmm}_post.txt" -f $serial, (Get-Date))) -Force
    } catch { }
}

if ((Test-Path (Join-Path $Root 'system.done')) -and (Test-Path (Join-Path $Root 'user.done'))) {
    Set-Content -Path (Join-Path $Root 'done.flag') -Value (Get-Date -Format s)
    # Cleanup: installers, SetupComplete hook. Keep logs + report.
    Remove-Item (Join-Path $Root 'Apps') -Recurse -Force -ErrorAction SilentlyContinue
    $sc = Join-Path $env:SystemRoot 'Setup\Scripts\SetupComplete.cmd'
    if (Test-Path $sc) {
        $keep = @(Get-Content $sc | Where-Object { $_ -notmatch 'ZinPost\.ps1' })
        Set-Content -Path $sc -Value $keep -Encoding ASCII
    }
    Write-ZinLog 'ZinPost finished, installers removed'
}
