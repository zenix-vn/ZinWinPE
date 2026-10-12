<#
.SYNOPSIS
  Downloads the latest installers for apps\<App>\app.ini (design 8.7.2, 11.3 B5c) and stages
  apps + manifests into out\ZINDATA\ZinPE\Apps\<App>\.
.DESCRIPTION
  Source order: Source= URL -> winget download --id <Winget> -> manual drop in apps\<App>\.
  Each file's SHA-256 is written to <App>\SHA256SUMS.txt (audit, design 11.3 "kiem hash").
.EXAMPLE
  .\Get-Apps.ps1                 # all apps
  .\Get-Apps.ps1 -Only Chrome,VLC
#>
[CmdletBinding()]
param(
    [string[]]$Only,
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'out\ZINDATA\ZinPE\Apps'),
    [switch]$Refresh
)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $Repo 'src\common\ZinCommon.psm1') -DisableNameChecking
Set-ZinLogFile (Join-Path $Repo 'out\logs\apps.log')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$winget = Get-Command winget.exe -ErrorAction SilentlyContinue

$rows = @()
foreach ($ini in Get-ChildItem $PSScriptRoot -Filter app.ini -Recurse | Sort-Object FullName) {
    $id = $ini.Directory.Name
    if ($Only -and ($Only -notcontains $id)) { continue }
    $m = Read-ZinIni $ini.FullName
    $dest = Join-Path $OutDir $id
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    # Repo content of the app folder (app.ini, config xml, defaults.reg, manual installers/fonts)
    Get-ChildItem $ini.DirectoryName -Force | Copy-Item -Destination $dest -Recurse -Force
    $installer = (Get-ZinIniValue $m 'App' 'Installer' '').Split(';')[0].Trim()
    $status = 'ok'
    try {
        $type = Get-ZinIniValue $m 'App' 'Type' ''
        if ($type -in @('feature', 'font', 'portable', 'odt')) {
            $status = 'manual/repo content'
        } else {
            $target = Join-Path $dest $installer
            if ($Refresh -or -not (Test-Path $target)) {
                $src = Get-ZinIniValue $m 'App' 'Source' ''
                $wg = Get-ZinIniValue $m 'App' 'Winget' ''
                if ($src) {
                    Write-ZinLog "$id : download $src"
                    Invoke-WebRequest $src -OutFile $target -UseBasicParsing
                } elseif ($wg -and $winget) {
                    foreach ($w in $wg.Split(';')) {
                        $tmp = Join-Path $env:TEMP "zin-winget-$id"
                        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
                        & winget.exe download --id $w.Trim() -e --download-directory $tmp --accept-package-agreements --accept-source-agreements --scope machine --architecture x64 | Out-Null
                        $f = Get-ChildItem $tmp -File -Include *.exe, *.msi, *.msix -Recurse | Select-Object -First 1
                        if (-not $f) { throw "winget download produced no installer for $w" }
                        # Keep the manifest's file name so Installer= stays valid.
                        $name = if ($wg.Contains(';')) { $f.Name } else { $installer }
                        Copy-Item $f.FullName (Join-Path $dest $name) -Force
                    }
                } else {
                    $status = "MANUAL: put $installer in apps\$id\"
                }
            }
        }
        $sums = Get-ChildItem $dest -File -Recurse | Where-Object { $_.Extension -in '.exe', '.msi', '.msix', '.ttf', '.otf' } |
            ForEach-Object { '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash, $_.FullName.Substring($dest.Length + 1) }
        if ($sums) { Set-Content (Join-Path $dest 'SHA256SUMS.txt') $sums -Encoding ASCII }
    } catch { $status = "ERROR: $($_.Exception.Message)"; Write-ZinLog "$id : $status" 'ERROR' }
    if ((Get-ZinIniValue $m 'App' 'Verify' '0') -eq '1') { $status += '  (Verify=1: test silent args)' }
    $rows += [pscustomobject]@{ App = $id; Target = (Get-ZinIniValue $m 'App' 'Target' ''); Status = $status }
}
$rows | Format-Table -AutoSize
