<#
.SYNOPSIS
  Builds the portable tool packages (design 6.4 manifest, 11.3 B4):
  download (Url=) or take a manual drop (packages\cache\<Id>\) -> verify SHA-256 -> unpack
  -> repack .7z -> out\ZINDATA\ZinPE\Programs\<Group>\<Id>.7z + <Id>.ini
.EXAMPLE
  .\build.ps1                       # all packages
  .\build.ps1 -Only wimlib,7-Zip    # some packages
  .\build.ps1 -CommercialOnly       # skip tools whose Commercial= is not Yes (shop use, design 16)
#>
[CmdletBinding()]
param(
    [string[]]$Only,
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'out\ZINDATA\ZinPE\Programs'),
    [string]$Cache = (Join-Path $PSScriptRoot 'cache'),
    [string]$SevenZip,
    [switch]$Refresh,
    [switch]$CommercialOnly
)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $Repo 'src\common\ZinCommon.psm1') -DisableNameChecking
Set-ZinLogFile (Join-Path $Repo 'out\logs\packages.log')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $SevenZip) {
    $SevenZip = @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $SevenZip) { throw '7-Zip (7z.exe) is required on the build machine' }

$work = Join-Path $Repo 'work\pkg'
$summary = New-Object System.Collections.Generic.List[object]

function Get-Source($Id, $Def) {
    $dir = Join-Path $Cache $Id
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $url = Get-ZinIniValue $Def 'Program' 'Url' ''
    if ($url) {
        $name = [IO.Path]::GetFileName(([uri]$url).AbsolutePath)
        if (-not $name -or $name -notmatch '\.') { $name = "$Id.exe" }
        $file = Join-Path $dir $name
        if ($Refresh -or -not (Test-Path $file)) {
            Write-ZinLog "Download $url"
            Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing -UserAgent 'Mozilla/5.0 ZinWinPE-builder'
        }
        return $file
    }
    $items = @(Get-ChildItem $dir -Force)
    if ($items.Count -eq 0) { return $null }
    if ($items.Count -eq 1 -and -not $items[0].PSIsContainer) { return $items[0].FullName }
    $dir    # manual drop: the folder itself is the program
}

function Expand-Source([string]$Src, [string]$Mode, [string]$Dest) {
    if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    if ((Get-Item $Src).PSIsContainer) { Copy-Item "$Src\*" $Dest -Recurse -Force; return }
    $ext = [IO.Path]::GetExtension($Src).ToLower()
    if ($Mode -eq 'copy' -or ($Mode -eq 'manual' -and $ext -eq '.exe')) { Copy-Item $Src $Dest -Force; return }
    & $SevenZip x -y "-o$Dest" $Src | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7z could not unpack $Src" }
    # Flatten a single top-level folder so Exe= paths stay short.
    $top = @(Get-ChildItem $Dest -Force)
    if ($top.Count -eq 1 -and $top[0].PSIsContainer) {
        $inner = $top[0].FullName
        Get-ChildItem $inner -Force | Move-Item -Destination $Dest -Force
        Remove-Item $inner -Recurse -Force
    }
}

$defs = Get-ChildItem (Join-Path $PSScriptRoot 'defs') -Filter *.ini | Sort-Object Name
foreach ($f in $defs) {
    $id = $f.BaseName
    if ($Only -and ($Only -notcontains $id)) { continue }
    $def = Read-ZinIni $f.FullName
    $name = Get-ZinIniValue $def 'Program' 'Name' $id
    $group = Get-ZinIniValue $def 'Program' 'Group' 'Utilities'
    $commercial = Get-ZinIniValue $def 'Program' 'Commercial' 'Check'
    $row = [ordered]@{ Id = $id; Name = $name; Group = $group; Commercial = $commercial; Status = ''; SizeMB = 0 }
    try {
        if ($CommercialOnly -and $commercial -ne 'Yes') { $row.Status = 'skipped (license)'; continue }
        $src = Get-Source $id $def
        if (-not $src) { $row.Status = "MANUAL: drop files in packages\cache\$id\"; continue }

        $hash = Get-ZinIniValue $def 'Program' 'Sha256' ''
        if (-not (Get-Item $src).PSIsContainer) {
            $actual = (Get-FileHash $src -Algorithm SHA256).Hash
            if ($hash -and $actual -ne $hash.ToUpper()) { throw "SHA-256 mismatch for $src (expected $hash, got $actual)" }
            if (-not $hash) { Write-ZinLog "$id : no Sha256 in manifest; downloaded file = $actual" 'WARN' }
        }

        $dest = Join-Path $work $id
        Expand-Source $src (Get-ZinIniValue $def 'Program' 'Extract' 'zip') $dest
        $exe = Get-ZinIniValue $def 'Program' 'Exe' ''
        if ($exe -and -not (Test-Path (Join-Path $dest $exe))) { Write-ZinLog "$id : Exe '$exe' not found after unpack - fix Exe= in defs\$id.ini" 'WARN' }

        $groupDir = Join-Path $OutDir $group
        New-Item -ItemType Directory -Path $groupDir -Force | Out-Null
        $archive = Join-Path $groupDir "$id.7z"
        if (Test-Path $archive) { Remove-Item $archive -Force }
        & $SevenZip a -t7z -mx=7 -mmt=on $archive "$dest\*" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7z failed to pack $id" }
        # Manifest on the USB: drop build-only keys.
        $keep = Get-Content $f.FullName -Encoding UTF8 | Where-Object { $_ -notmatch '^(Url|Sha256|Extract)=' }
        $keep = $keep -replace '^Archive=.*$', "Archive=$id.7z"
        Set-Content -Path (Join-Path $groupDir "$id.ini") -Value $keep -Encoding UTF8
        $row.SizeMB = [math]::Round((Get-Item $archive).Length / 1MB, 1)
        $row.Status = 'OK'
    } catch {
        $row.Status = "ERROR: $($_.Exception.Message)"
        Write-ZinLog "$id : $($_.Exception.Message)" 'ERROR'
    } finally {
        $summary.Add([pscustomobject]$row)
    }
}

$summary | Format-Table -AutoSize Id, Group, Commercial, SizeMB, Status
$total = ($summary | Measure-Object SizeMB -Sum).Sum
Write-ZinLog ("Programs total: {0:N0} MB (budget 3-5 GB, design 9.5)" -f $total)
$summary | Export-Csv (Join-Path $Repo 'out\logs\packages.csv') -NoTypeInformation -Encoding UTF8
