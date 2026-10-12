<#
.SYNOPSIS
  ZinDriverSync - builds the driver store on the build machine (design 9.2-9.5, 11.3 B5).
.DESCRIPTION
  -Vendor packs (T3): reads the official catalogs, downloads the packs for models listed in
   drivers\models.json, verifies hashes, extracts .exe/.cab -> .inf, writes
   OS\<Vendor>\<Key>\<os>\ + pack-index.json, and generates Drivers\index.json.
     Dell   DriverPackCatalog.cab           match: sku       (SystemSKUNumber = systemID)
     HP     HPClientDriverPackCatalog.cab   match: baseboard (Platform ID)
     Lenovo catalogv2.xml                   match: mtm4      (first 4 chars of Model)
  -WinPE (T1): Dell WinPE driver pack -> drivers\store\T1 (injected by builder\inject-t1.ps1)
  -PE (T2): drivers\store\PE (manual drop) -> Drivers\PE + pe-index.json
  -SDIO: drivers\store\SDIO (SDIO_x64_*.exe + drivers\*.7z), trimmed by -Package, + sdio-index.tsv
  Package: Lite (T2 + SDIO essentials) | Standard (Lite + full SDIO, default D2) | Full (Standard + OEM packs)
.EXAMPLE
  .\ZinDriverSync.ps1 -Package Standard
  .\ZinDriverSync.ps1 -Package Full -Os win11
#>
[CmdletBinding()]
param(
    [ValidateSet('Lite', 'Standard', 'Full')][string]$Package = 'Standard',
    [ValidateSet('win10', 'win11')][string[]]$Os = @('win11', 'win10'),
    [string]$Store = (Join-Path $PSScriptRoot 'store'),
    [string]$Cache = (Join-Path $PSScriptRoot 'cache'),
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'out\ZINDATA\ZinPE\Drivers'),
    [switch]$SkipVendor,
    [switch]$SkipSdio,
    [switch]$SkipWinPE,
    [double]$BudgetGB = 30
)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $Repo 'src\common\ZinCommon.psm1') -DisableNameChecking
Import-Module (Join-Path $Repo 'src\zindriver\ZinDriver.psm1') -DisableNameChecking
Set-ZinLogFile (Join-Path $Repo 'out\logs\driversync.log')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$SevenZip = @("$env:ProgramFiles\7-Zip\7z.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $SevenZip) { throw '7-Zip is required' }
$Models = Read-ZinJson (Join-Path $PSScriptRoot 'models.json')
New-Item -ItemType Directory -Path $Cache, $Store, $OutDir -Force | Out-Null

function Get-File([string]$Url, [string]$Dest, [string]$Sha256 = '', [string]$Md5 = '') {
    if (-not (Test-Path $Dest)) {
        Write-ZinLog "Download $Url"
        New-Item -ItemType Directory -Path (Split-Path $Dest) -Force | Out-Null
        Invoke-WebRequest $Url -OutFile "$Dest.part" -UseBasicParsing
        Move-Item "$Dest.part" $Dest -Force
    }
    if ($Sha256) { $h = (Get-FileHash $Dest -Algorithm SHA256).Hash; if ($h -ne $Sha256.ToUpper()) { Remove-Item $Dest; throw "SHA-256 mismatch: $Dest" } }
    elseif ($Md5) { $h = (Get-FileHash $Dest -Algorithm MD5).Hash; if ($h -ne $Md5.ToUpper()) { Remove-Item $Dest; throw "MD5 mismatch: $Dest" } }
    $Dest
}

function Get-CatalogXml([string]$Url, [string]$Name) {
    $file = Join-Path $Cache ([IO.Path]::GetFileName(([uri]$Url).AbsolutePath))
    if ((Test-Path $file) -and ((Get-Item $file).LastWriteTime -lt (Get-Date).AddDays(-7))) { Remove-Item $file }
    Get-File $Url $file | Out-Null
    if ($file -like '*.cab') {
        $x = Join-Path $Cache "$Name.xml"
        & expand.exe $file $x | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "expand failed: $file" }
        $file = $x
    }
    [xml](Get-Content $file -Raw -Encoding UTF8)
}

function Expand-Pack([string]$File, [string]$Dest, [ValidateSet('cab', 'hp', 'lenovo', '7z')][string]$Kind) {
    if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    switch ($Kind) {
        'cab'    { & expand.exe $File -F:* $Dest | Out-Null }
        'hp'     { Start-Process $File -ArgumentList "/s /e /f `"$Dest`"" -Wait }
        'lenovo' { Start-Process $File -ArgumentList "/VERYSILENT /DIR=`"$Dest`" /EXTRACT=`"YES`"" -Wait }
        '7z'     { & $SevenZip x -y "-o$Dest" $File | Out-Null }
    }
    if (-not (Get-ChildItem $Dest -Filter *.inf -Recurse | Select-Object -First 1)) {
        # Some packs are nested archives; try 7-Zip as a fallback.
        & $SevenZip x -y "-o$Dest" $File | Out-Null
    }
    $n = @(Get-ChildItem $Dest -Filter *.inf -Recurse).Count
    if ($n -eq 0) { throw "No .inf after extracting $File" }
    $n
}

function Get-XText($Node) {
    # XML nodes come back as strings (plain element) or XmlElement (attributes / CDATA).
    if ($null -eq $Node) { return '' }
    if ($Node -is [string]) { return $Node.Trim() }
    if ($Node -is [array]) { $Node = $Node[0] }
    "$($Node.InnerText)".Trim()
}

function Test-ModelWanted([string]$Name, [string[]]$Patterns) {
    foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
    $false
}

$rules = New-Object System.Collections.Generic.List[object]

#region Vendor packs (T3) ---------------------------------------------------------
if (-not $SkipVendor -and $Package -eq 'Full') {
    # --- Dell -------------------------------------------------------------------
    try {
        $x = Get-CatalogXml 'https://downloads.dell.com/catalog/DriverPackCatalog.cab' 'DellDriverPackCatalog'
        $base = 'https://' + $x.DriverPackManifest.baseLocation
        foreach ($pkg in $x.DriverPackManifest.DriverPackage) {
            if ($pkg.type -ne 'win') { continue }
            $osCodes = @($pkg.SupportedOperatingSystems.OperatingSystem | Where-Object osArch -eq 'x64' | ForEach-Object { $_.osCode })
            foreach ($o in $Os) {
                $code = if ($o -eq 'win11') { 'Windows11' } else { 'Windows10' }
                if ($osCodes -notcontains $code) { continue }
                foreach ($brand in @($pkg.SupportedSystems.Brand)) {
                    foreach ($model in @($brand.Model)) {
                        $full = "$(Get-XText $brand.Display) $($model.name)".Trim()
                        if (-not (Test-ModelWanted $full @($Models.dell))) { continue }
                        $key = ($full -replace '[^\w]+', '_')
                        $dest = Join-Path $OutDir "OS\Dell\$key\$o"
                        if (-not (Test-Path (Join-Path $dest 'pack-index.json'))) {
                            $file = Get-File "$base/$($pkg.path)" (Join-Path $Cache "dell\$([IO.Path]::GetFileName($pkg.path))") -Md5 $pkg.hashMD5
                            $n = Expand-Pack $file $dest 'cab'
                            New-ZinDriverIndex -Root $dest -OutFile (Join-Path $dest 'pack-index.json') | Out-Null
                            Write-ZinLog "Dell $full ($o): $n inf"
                        }
                        $rules.Add([ordered]@{ manufacturer = 'Dell'; match = 'sku'; value = "$($model.systemID)"; os = @($o); path = "OS\Dell\$key\$o"; name = $full })
                    }
                }
            }
        }
    } catch { Write-ZinLog "Dell catalog: $($_.Exception.Message)" 'ERROR' }

    # --- HP ---------------------------------------------------------------------
    try {
        $x = Get-CatalogXml 'https://hpia.hpcloud.hp.com/downloads/driverpackcatalog/HPClientDriverPackCatalog.cab' 'HPClientDriverPackCatalog'
        $cat = $x.NewDataSet.HPClientDriverPackCatalog
        $sp = @{}
        foreach ($s in $cat.SoftPaqList.SoftPaq) { $sp[$s.Id] = $s }
        foreach ($p in $cat.ProductOSDriverPackList.ProductOSDriverPack) {
            if (-not (Test-ModelWanted $p.SystemName @($Models.hp))) { continue }
            foreach ($o in $Os) {
                $want = if ($o -eq 'win11') { 'Windows 11 64-bit*' } else { 'Windows 10 64-bit*' }
                if ($p.OSName -notlike $want) { continue }
                $s = $sp[$p.SoftPaqId]
                if (-not $s) { continue }
                $plat = ($p.SystemId -split ',')[0].Trim()
                $dest = Join-Path $OutDir "OS\HP\$plat\$o"
                if (-not (Test-Path (Join-Path $dest 'pack-index.json'))) {
                    $file = Get-File $s.Url (Join-Path $Cache "hp\$($s.Id).exe") -Sha256 $s.SHA256
                    $n = Expand-Pack $file $dest 'hp'
                    New-ZinDriverIndex -Root $dest -OutFile (Join-Path $dest 'pack-index.json') | Out-Null
                    Write-ZinLog "HP $($p.SystemName) ($o): $n inf"
                }
                $rules.Add([ordered]@{ manufacturer = 'HP'; match = 'baseboard'; value = (($p.SystemId -split ',' | ForEach-Object { $_.Trim() }) -join ';'); os = @($o); path = "OS\HP\$plat\$o"; name = $p.SystemName })
            }
        }
    } catch { Write-ZinLog "HP catalog: $($_.Exception.Message)" 'ERROR' }

    # --- Lenovo -----------------------------------------------------------------
    try {
        $x = Get-CatalogXml 'https://download.lenovo.com/cdrt/td/catalogv2.xml' 'LenovoCatalogV2'
        foreach ($m in $x.ModelList.Model) {
            if (-not (Test-ModelWanted $m.name @($Models.lenovo))) { continue }
            foreach ($o in $Os) {
                $sccm = @($m.SCCM | Where-Object { $_.os -eq $o }) | Sort-Object { $_.version } -Descending | Select-Object -First 1
                if (-not $sccm) { continue }
                $types = @($m.Types.Type | ForEach-Object { "$_".Trim().Substring(0, 4).ToUpper() } | Select-Object -Unique)
                $key = $types[0]
                $dest = Join-Path $OutDir "OS\Lenovo\$key\$o"
                $url = Get-XText $sccm
                if (-not (Test-Path (Join-Path $dest 'pack-index.json'))) {
                    $file = Get-File $url (Join-Path $Cache "lenovo\$([IO.Path]::GetFileName(([uri]$url).AbsolutePath))")
                    $n = Expand-Pack $file $dest 'lenovo'
                    New-ZinDriverIndex -Root $dest -OutFile (Join-Path $dest 'pack-index.json') | Out-Null
                    Write-ZinLog "Lenovo $($m.name) ($o): $n inf"
                }
                $rules.Add([ordered]@{ manufacturer = 'LENOVO'; match = 'mtm4'; value = ($types -join ';'); os = @($o); path = "OS\Lenovo\$key\$o"; name = $m.name })
            }
        }
    } catch { Write-ZinLog "Lenovo catalog: $($_.Exception.Message)" 'ERROR' }

    # --- manual packs (Surface, others): drivers\store\OS\<Vendor>\<Key>\<os> + rules in models.json "manualRules"
    $manual = Join-Path $Store 'OS'
    if (Test-Path $manual) { Copy-Item "$manual\*" (Join-Path $OutDir 'OS') -Recurse -Force }
    if ($Models.PSObject.Properties.Name -contains 'manualRules') { foreach ($r in $Models.manualRules) { $rules.Add($r) } }
}
#endregion

#region WinPE (T1) + PE extended (T2) --------------------------------------------
if (-not $SkipWinPE) {
    try {
        $x = Get-CatalogXml 'https://downloads.dell.com/catalog/DriverPackCatalog.cab' 'DellDriverPackCatalog'
        $base = 'https://' + $x.DriverPackManifest.baseLocation
        $pe = @($x.DriverPackManifest.DriverPackage | Where-Object { $_.type -eq 'winpe' -and ($_.SupportedOperatingSystems.OperatingSystem.osCode -match '11') }) |
            Sort-Object { [datetime]$_.dateTime } -Descending | Select-Object -First 1
        if ($pe) {
            $t1 = Join-Path $Store 'T1\Dell-WinPE11'
            if (-not (Test-Path $t1)) {
                $file = Get-File "$base/$($pe.path)" (Join-Path $Cache "dell\$([IO.Path]::GetFileName($pe.path))") -Md5 $pe.hashMD5
                $n = Expand-Pack $file $t1 'cab'
                Write-ZinLog "Dell WinPE 11 pack $($pe.dellVersion): $n inf -> $t1"
            }
        } else { Write-ZinLog 'Dell WinPE 11 pack not found in catalog' 'WARN' }
    } catch { Write-ZinLog "WinPE pack: $($_.Exception.Message)" 'ERROR' }

    $t2 = Join-Path $Store 'PE'
    if (Test-Path $t2) {
        $peOut = Join-Path $OutDir 'PE'
        if (Test-Path $peOut) { Remove-Item $peOut -Recurse -Force }
        Copy-Item $t2 $peOut -Recurse -Force
        New-ZinDriverIndex -Root $peOut -OutFile (Join-Path $peOut 'pe-index.json') | Out-Null
    } else { Write-ZinLog "No T2 drop folder ($t2): put Intel VMD/RST, AMD RAID, Serial IO... there" 'WARN' }
}
#endregion

#region SDIO ------------------------------------------------------------------------
if (-not $SkipSdio) {
    $sdioSrc = Join-Path $Store 'SDIO'
    $sdioOut = Join-Path $OutDir 'OS\Generic\SDIO'
    if (-not (Test-Path $sdioSrc)) {
        Write-ZinLog "SDIO not found at $sdioSrc - download SDIO + driverpacks (sdi-tool.org) there first" 'WARN'
    } else {
        $packs = @(Get-ChildItem (Join-Path $sdioSrc 'drivers') -Filter *.7z)
        $excl = @($Models.sdio.exclude)
        $lite = @($Models.sdio.lite)
        $sel = @($packs | Where-Object {
                $n = $_.Name
                if (@($excl | Where-Object { $n -like $_ }).Count) { return $false }
                if ($Package -eq 'Lite') { return [bool]@($lite | Where-Object { $n -like $_ }).Count }
                $true
            })
        Write-ZinLog "SDIO: $($sel.Count) of $($packs.Count) packs selected ($Package)"
        New-Item -ItemType Directory -Path (Join-Path $sdioOut 'drivers') -Force | Out-Null
        Get-ChildItem $sdioSrc -File | Copy-Item -Destination $sdioOut -Force          # SDIO_x64_*.exe, sdi.cfg
        foreach ($d in @('indexes', 'tools')) { if (Test-Path "$sdioSrc\$d") { Copy-Item "$sdioSrc\$d" $sdioOut -Recurse -Force } }
        foreach ($p in $sel) {
            $dst = Join-Path $sdioOut "drivers\$($p.Name)"
            if (-not (Test-Path $dst) -or (Get-Item $dst).Length -ne $p.Length) { Copy-Item $p.FullName $dst -Force }
        }
        # Remove packs that are no longer selected
        Get-ChildItem (Join-Path $sdioOut 'drivers') -Filter *.7z | Where-Object { $sel.Name -notcontains $_.Name } | Remove-Item -Force

        # sdio-index.tsv: HWID <TAB> pack <TAB> inf <TAB> date  (streamed by ZinDriver, design 9.4 step 2)
        $tsv = Join-Path $sdioOut 'sdio-index.tsv'
        $w = New-Object System.IO.StreamWriter($tsv, $false, (New-Object System.Text.UTF8Encoding($false)))
        try {
            foreach ($p in $sel) {
                $tmp = Join-Path $env:TEMP "zin-sdio-$($p.BaseName)"
                Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
                & $SevenZip x -y "-o$tmp" $p.FullName '*.inf' -r | Out-Null
                $count = 0
                foreach ($inf in Get-ChildItem $tmp -Filter *.inf -Recurse -File) {
                    try { $info = Get-ZinInfInfo -Path $inf.FullName } catch { continue }
                    if (-not $info.Amd64) { continue }
                    $rel = $inf.FullName.Substring($tmp.Length + 1) -replace '\\', '/'
                    $date = $info.Date.ToString('yyyy-MM-dd')
                    foreach ($id in $info.Ids) { $w.WriteLine("$id`t$($p.Name)`t$rel`t$date"); $count++ }
                }
                Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
                Write-ZinLog "  indexed $($p.Name): $count ids"
            }
        } finally { $w.Close() }
    }
}
#endregion

#region index.json + size report ----------------------------------------------------
$index = [ordered]@{ version = (Get-Content (Join-Path $Repo 'VERSION') -TotalCount 1).Trim(); package = $Package; rules = $rules.ToArray(); fallback = 'OS\Generic\SDIO' }
Write-ZinUtf8File -Path (Join-Path $OutDir 'index.json') -Content (ConvertTo-Json -InputObject $index -Depth 6)
Write-ZinLog "index.json: $($rules.Count) rules"

$sizes = Get-ChildItem $OutDir -Directory | ForEach-Object {
    [pscustomobject]@{ Folder = $_.Name; GB = [math]::Round(((Get-ChildItem $_.FullName -Recurse -File | Measure-Object Length -Sum).Sum) / 1GB, 2) }
}
$sizes | Format-Table -AutoSize
$total = ($sizes | Measure-Object GB -Sum).Sum
Write-ZinLog ("Drivers total: {0:N1} GB (package {1}, budget {2} GB - design 9.5)" -f $total, $Package, $BudgetGB)
if ($total -gt $BudgetGB) { Write-ZinLog 'Over budget: add patterns to models.json sdio.exclude or use -Package Lite' 'WARN' }
#endregion
