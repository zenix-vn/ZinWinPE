<#
.SYNOPSIS
  Regenerates LICENSES.md from packages\defs\*.ini and apps\*\app.ini (design 16).
  Column "Dung thuong mai" comes from Commercial= (Yes / No / Check).
#>
[CmdletBinding()]
param([string]$Out = (Join-Path (Split-Path -Parent $PSScriptRoot) 'LICENSES.md'))
$Repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $Repo 'src\common\ZinCommon.psm1') -DisableNameChecking

# Vietnamese labels are built from code points so this file stays ASCII (PS 5.1 + no BOM).
function U([string]$s) { [regex]::Unescape($s) }
$label = @{ Yes = (U 'Có'); No = (U '❌ Không'); Check = (U '⚠️ Cần kiểm tra') }

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# LICENSES')
[void]$sb.AppendLine('')
[void]$sb.AppendLine((U '> Tự sinh bởi `packages/New-LicensesMd.ps1` từ `packages/defs/*.ini` và `apps/*/app.ini` — không sửa tay.'))
[void]$sb.AppendLine((U '> Mục đích sử dụng: **cửa hàng sửa chữa = thương mại** (thiết kế mục 16). Chỉ đóng gói công cụ có cột "Dùng thương mại" = Có, hoặc có license mua riêng.'))
[void]$sb.AppendLine('')
[void]$sb.AppendLine((U '## Công cụ trong WinPE (`ZinPE\Programs`)'))
[void]$sb.AppendLine('')
[void]$sb.AppendLine((U '| Công cụ | Nhóm | Phiên bản | License | Dùng thương mại | Nguồn |'))
[void]$sb.AppendLine('|---|---|---|---|---|---|')
foreach ($f in Get-ChildItem (Join-Path $Repo 'packages\defs') -Filter *.ini | Sort-Object Name) {
    $d = Read-ZinIni $f.FullName
    $c = Get-ZinIniValue $d 'Program' 'Commercial' 'Check'
    $url = Get-ZinIniValue $d 'Program' 'Url' ''
    $src = if ($url) { "[link]($url)" } else { (U 'thủ công') }
    [void]$sb.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} |' -f (Get-ZinIniValue $d 'Program' 'Name' $f.BaseName), (Get-ZinIniValue $d 'Program' 'Group' ''), (Get-ZinIniValue $d 'Program' 'Version' '-'), (Get-ZinIniValue $d 'Program' 'License' ''), $label[$c], $src))
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine((U '## Phần mềm cài cho khách (`ZinPE\Apps`, mục 8.7)'))
[void]$sb.AppendLine('')
[void]$sb.AppendLine((U '| Phần mềm | Cách cài | License | Cần kiểm thử |'))
[void]$sb.AppendLine('|---|---|---|---|')
foreach ($f in Get-ChildItem (Join-Path $Repo 'apps') -Filter app.ini -Recurse | Sort-Object FullName) {
    $d = Read-ZinIni $f.FullName
    $v = if ((Get-ZinIniValue $d 'App' 'Verify' '0') -eq '1') { (U '⚠️') } else { '' }
    [void]$sb.AppendLine(('| {0} | {1} | {2} | {3} |' -f (Get-ZinIniValue $d 'App' 'Name' ''), (Get-ZinIniValue $d 'App' 'Target' ''), (Get-ZinIniValue $d 'App' 'License' ''), $v))
}
Write-ZinUtf8File -Path $Out -Content $sb.ToString()
Write-Host "Written $Out"
