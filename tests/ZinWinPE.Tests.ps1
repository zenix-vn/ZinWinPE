# Pester 5 unit tests for the pure (hardware-independent) parts of ZinWinPE.
# Run:  Invoke-Pester ./tests   (works on Windows PowerShell 5.1 and PowerShell 7, also on macOS/Linux)

BeforeAll {
    $Repo = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $Repo 'src/common/ZinCommon.psm1') -DisableNameChecking -Force
    Import-Module (Join-Path $Repo 'src/zindriver/ZinDriver.psm1') -DisableNameChecking -Force
    Import-Module (Join-Path $Repo 'src/zinsetup/ZinSetup.Core.psm1') -DisableNameChecking -Force
    $Tmp = Join-Path ([IO.Path]::GetTempPath()) ("zintest-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $Tmp | Out-Null
}
AfterAll { Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Read-ZinIni' {
    It 'keeps ";" inside values but strips " ; comments"' {
        $f = Join-Path $Tmp 'a.ini'
        Set-Content $f "; header`n[App]`nName=Test`nInstaller=a.exe;b.exe`nTarget=zinpost        ; image | zinpost`nEmpty=`n" -Encoding UTF8
        $i = Read-ZinIni $f
        $i['App']['Installer'] | Should -Be 'a.exe;b.exe'
        $i['App']['Target'] | Should -Be 'zinpost'
        Get-ZinIniValue $i 'App' 'Empty' 'dflt' | Should -Be 'dflt'
        Get-ZinIniValue $i 'Nope' 'X' 'd' | Should -Be 'd'
    }
    It 'parses every app manifest in apps/' {
        foreach ($f in Get-ChildItem (Join-Path $Repo 'apps') -Filter app.ini -Recurse) {
            $i = Read-ZinIni $f.FullName
            $i['App']['Name'] | Should -Not -BeNullOrEmpty
            $i['App']['RunAs'] | Should -BeIn @('system', 'user', 'pe-offline')
            $i['App']['Target'] | Should -BeIn @('image', 'zinpost')
        }
    }
    It 'parses every tool package definition' {
        foreach ($f in Get-ChildItem (Join-Path $Repo 'packages/defs') -Filter *.ini) {
            $i = Read-ZinIni $f.FullName
            $i['Program']['Group'] | Should -BeIn @('Partition', 'Backup', 'Recovery', 'HWTest', 'System', 'Network', 'Antivirus', 'Utilities')
            $i['Program']['Commercial'] | Should -BeIn @('Yes', 'No', 'Check')
            $i['Program']['Archive'] | Should -Be "$($f.BaseName).7z"
        }
    }
}

Describe 'Language files' {
    It 'en-US and vi-VN have the same keys' {
        $en = ConvertTo-ZinFlatMap (Read-ZinJson (Join-Path $Repo 'src/lang/en-US.json'))
        $vi = ConvertTo-ZinFlatMap (Read-ZinJson (Join-Path $Repo 'src/lang/vi-VN.json'))
        @($en.Keys | Where-Object { -not $vi.ContainsKey($_) }) | Should -BeNullOrEmpty
        @($vi.Keys | Where-Object { -not $en.ContainsKey($_) }) | Should -BeNullOrEmpty
    }
    It 'every Get-ZinText / Tag key used in scripts exists' {
        $en = ConvertTo-ZinFlatMap (Read-ZinJson (Join-Path $Repo 'src/lang/en-US.json'))
        $used = foreach ($f in Get-ChildItem (Join-Path $Repo 'src') -Recurse -Include *.ps1, *.psm1) {
            $t = Get-Content $f.FullName -Raw
            [regex]::Matches($t, "Get-ZinText '([a-z_]+\.[a-z0-9_]+)'") | ForEach-Object { $_.Groups[1].Value }
            [regex]::Matches($t, 'Tag="((setup|installer|common)\.[a-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value }
        }
        @($used | Sort-Object -Unique | Where-Object { -not $en.ContainsKey($_) }) | Should -BeNullOrEmpty
    }
    It 'falls back to en-US and formats arguments' {
        Import-ZinLang -LangDir (Join-Path $Repo 'src/lang') -Code 'xx-XX'
        Get-ZinText 'installer.warn_space' @(10, 5) | Should -Be 'Not enough space: need 10 GB, ZINDATA has 5 GB.'
        Import-ZinLang -LangDir (Join-Path $Repo 'src/lang') -Code 'vi-VN'
        Get-ZinText 'common.cancel' | Should -Not -Be 'Cancel'
        Get-ZinText 'no.such.key' | Should -Be 'no.such.key'
    }
}

Describe 'INF parsing' {
    It 'collects amd64 hardware IDs and DriverVer' {
        $inf = @'
[Version]
Signature="$WINDOWS NT$"
Class=Net
DriverVer=03/15/2024,10.68.1234.0 ; comment
[Manufacturer]
%Intel% = Intel, NTamd64.10.0, NTx86
[Intel.NTamd64.10.0]
%Dev1% = Inst1, PCI\VEN_8086&DEV_15F3&SUBSYS_00008086, PCI\VEN_8086&DEV_15F3
[Intel.NTx86]
%DevX86% = InstX, PCI\VEN_8086&DEV_9999
[Strings]
Intel = "Intel"
'@ -split "`n"
        $r = ConvertFrom-ZinInfText -Lines $inf
        $r.Amd64 | Should -BeTrue
        $r.Class | Should -Be 'Net'
        $r.Date | Should -Be (Get-Date -Year 2024 -Month 3 -Day 15).Date
        $r.Ids | Should -Contain 'PCI\VEN_8086&DEV_15F3&SUBSYS_00008086'
        $r.Ids | Should -Contain 'PCI\VEN_8086&DEV_15F3'
        $r.Ids | Should -Not -Contain 'PCI\VEN_8086&DEV_9999'
    }
    It 'marks x86-only infs as not amd64' {
        $r = ConvertFrom-ZinInfText -Lines @('[Manufacturer]', '%M% = M, NTx86', '[M.NTx86]', '%D% = I, USB\VID_1234&PID_5678')
        $r.Amd64 | Should -BeFalse
    }
}

Describe 'Driver matching' {
    BeforeAll {
        $dev = [pscustomobject]@{ Name = 'LAN'; DeviceID = 'PCI\X'; ErrorCode = 28; HardwareIDs = @('PCI\VEN_10EC&DEV_8168&SUBSYS_1', 'PCI\VEN_10EC&DEV_8168'); CompatibleIDs = @('PCI\CC_0200') }
        $index = @(
            [pscustomobject]@{ inf = 'old.inf'; date = '2019-01-01'; ids = @('PCI\VEN_10EC&DEV_8168') },
            [pscustomobject]@{ inf = 'new.inf'; date = '2023-05-01'; ids = @('PCI\VEN_10EC&DEV_8168') },
            [pscustomobject]@{ inf = 'generic.inf'; date = '2024-01-01'; ids = @('PCI\CC_0200') }
        )
    }
    It 'prefers the newest inf for the most specific hardware ID and ignores compatible IDs' {
        $m = @(Find-ZinDriverMatch -Devices @($dev) -Index $index)
        $m.Count | Should -Be 1
        $m[0].Entry.inf | Should -Be 'new.inf'
        $m[0].HardwareID | Should -Be 'PCI\VEN_10EC&DEV_8168'
    }
    It 'prefers an exact SUBSYS match over a newer generic one' {
        $idx2 = $index + [pscustomobject]@{ inf = 'oem.inf'; date = '2018-01-01'; ids = @('PCI\VEN_10EC&DEV_8168&SUBSYS_1') }
        (@(Find-ZinDriverMatch -Devices @($dev) -Index $idx2))[0].Entry.inf | Should -Be 'oem.inf'
    }
    It 'reads only the wanted IDs from a TSV index' {
        $tsv = Join-Path $Tmp 'sdio-index.tsv'
        @("PCI\VEN_10EC&DEV_8168`tDP_LAN.7z`tr/8168.inf`t2023-05-01",
          "PCI\VEN_10EC&DEV_8168&SUBSYS_1`tDP_LAN.7z`tr/8168.inf`t2023-05-01",
          "USB\VID_0000`tDP_X.7z`tx.inf`t2020-01-01") | Set-Content $tsv
        $e = Read-ZinDriverIndexTsv -Path $tsv -Ids @('pci\ven_10ec&dev_8168')
        $e.Count | Should -Be 1
        $e[0].pack | Should -Be 'DP_LAN.7z'
        @($e[0].ids) | Should -Be @('PCI\VEN_10EC&DEV_8168')
    }
}

Describe 'Find-ZinVendorPack' {
    BeforeAll {
        $index = [pscustomobject]@{ rules = @(
                [pscustomobject]@{ manufacturer = 'Dell'; match = 'sku'; value = '081C'; os = @('win11'); path = 'OS\Dell\Latitude_7490\win11' },
                [pscustomobject]@{ manufacturer = 'HP'; match = 'baseboard'; value = '83B3;83B2'; os = @('win11'); path = 'OS\HP\83B3\win11' },
                [pscustomobject]@{ manufacturer = 'LENOVO'; match = 'mtm4'; value = '20L5;20L6'; path = 'OS\Lenovo\20L5\win11' }
            ) }
    }
    It 'matches Dell by SKU with "Dell Inc." manufacturer' {
        $info = [pscustomobject]@{ Manufacturer = 'Dell Inc.'; Model = 'Latitude 7490'; FriendlyName = 'Latitude 7490'; SKU = '081C'; BaseBoard = ''; MTM4 = '' }
        (Find-ZinVendorPack -Info $info -Index $index -Os win11).path | Should -Be 'OS\Dell\Latitude_7490\win11'
        Find-ZinVendorPack -Info $info -Index $index -Os win10 | Should -BeNullOrEmpty
    }
    It 'matches HP by one of several platform IDs' {
        $info = [pscustomobject]@{ Manufacturer = 'HP'; Model = 'HP EliteBook 840 G5'; FriendlyName = ''; SKU = ''; BaseBoard = '83B2'; MTM4 = '' }
        (Find-ZinVendorPack -Info $info -Index $index -Os win11).path | Should -Be 'OS\HP\83B3\win11'
    }
    It 'matches Lenovo by MTM and ignores the os filter when absent' {
        $info = [pscustomobject]@{ Manufacturer = 'LENOVO'; Model = '20L6S0AB00'; FriendlyName = 'ThinkPad T480'; SKU = ''; BaseBoard = ''; MTM4 = '20L6' }
        (Find-ZinVendorPack -Info $info -Index $index -Os win10).path | Should -Be 'OS\Lenovo\20L5\win11'
    }
    It 'returns nothing for an unknown machine' {
        $info = [pscustomobject]@{ Manufacturer = 'ASUSTeK COMPUTER INC.'; Model = 'X515'; FriendlyName = ''; SKU = ''; BaseBoard = 'X515EA'; MTM4 = '' }
        Find-ZinVendorPack -Info $info -Index $index | Should -BeNullOrEmpty
    }
}

Describe 'New-ZinPartitionScript' {
    It 'GPT layout: EFI 260 MB, MSR, Windows, 1 GB recovery with the WinRE type/attributes' {
        $s = New-ZinPartitionScript -DiskNumber 1 -Style GPT -WinLetter W -SysLetter S -RecLetter R
        $s[0] | Should -Be 'select disk 1'
        $s | Should -Contain 'convert gpt'
        $s | Should -Contain 'create partition efi size=260'
        $s | Should -Contain 'create partition msr size=16'
        $s | Should -Contain 'shrink minimum=1024'
        $s | Should -Contain 'set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac'
        $s | Should -Contain 'gpt attributes=0x8000000000000001'
        ([array]::IndexOf($s, 'assign letter=W')) | Should -BeLessThan ([array]::IndexOf($s, 'assign letter=R'))
    }
    It 'MBR layout: 500 MB active System Reserved + Windows, no recovery' {
        $s = New-ZinPartitionScript -DiskNumber 0 -Style MBR -WinLetter W -SysLetter S
        $s | Should -Contain 'convert mbr'
        $s | Should -Contain 'create partition primary size=500'
        $s | Should -Contain 'active'
        ($s -join "`n") | Should -Not -Match 'shrink|set id'
    }
}

Describe 'New-ZinUnattendXml' {
    BeforeAll { $tpl = Get-Content (Join-Path $Repo 'config/Unattend/zin-unattend.xml') -Raw }
    It 'produces well-formed XML with escaped values and all tokens replaced' {
        $p = Read-ZinJson (Join-Path $Repo 'config/Presets/10-Win11-Pro-Shop.json')
        $p.unattend.localUser = 'Ky & Thuat <1>'
        $xml = New-ZinUnattendXml -Template $tpl -Options $p.unattend -FirstLogonCommands @('cmd /c echo "a" & echo b')
        $xml | Should -Not -Match '\{\{'
        $doc = [xml]$xml
        $ns = @{ u = 'urn:schemas-microsoft-com:unattend' }
        (Select-Xml -Xml $doc -XPath '//u:LocalAccount/u:Name' -Namespace $ns).Node.InnerText | Should -Be 'Ky & Thuat <1>'
        (Select-Xml -Xml $doc -XPath '//u:TimeZone' -Namespace $ns).Node.InnerText | Should -Be 'SE Asia Standard Time'
        (Select-Xml -Xml $doc -XPath '//u:SynchronousCommand/u:CommandLine' -Namespace $ns).Node.InnerText | Should -Be 'cmd /c echo "a" & echo b'
        (Select-Xml -Xml $doc -XPath '//u:AutoLogon/u:LogonCount' -Namespace $ns).Node.InnerText | Should -Be '1'
        (Select-Xml -Xml $doc -XPath '//u:HideOnlineAccountScreens' -Namespace $ns).Node.InnerText | Should -Be 'true'
    }
    It 'omits FirstLogonCommands and AutoLogon when not needed' {
        $o = [pscustomobject]@{ localUser = 'User'; autoLogon = $false; bypassNRO = $false; preventDeviceEncryption = $false; timeZone = 'UTC'; inputLocale = '0409:00000409'; systemLocale = 'en-US'; uiLanguage = 'en-US'; userLocale = 'en-US'; computerName = '' }
        $xml = New-ZinUnattendXml -Template $tpl -Options $o
        $xml | Should -Not -Match 'FirstLogonCommands|AutoLogon'
        { [xml]$xml } | Should -Not -Throw
    }
}

Describe 'Presets' {
    It 'every preset is valid and references known apps' {
        $apps = @(Get-ChildItem (Join-Path $Repo 'apps') -Directory | ForEach-Object Name)
        $presets = @(Get-ZinPreset -PresetDir (Join-Path $Repo 'config/Presets'))
        $presets.Count | Should -BeGreaterThan 0
        foreach ($p in $presets) {
            $p.name | Should -Not -BeNullOrEmpty
            $p.os | Should -BeIn @('win10', 'win11')
            $p.partition.mode | Should -BeIn @('Wipe', 'Existing')
            foreach ($a in $p.apps) { $apps | Should -Contain $a }
            Get-ZinPresetTitle -Preset $p -Lang 'vi-VN' | Should -Not -BeNullOrEmpty
        }
    }
    It 'suggests a non-Win11 preset for an unsupported machine' {
        $presets = @(Get-ZinPreset -PresetDir (Join-Path $Repo 'config/Presets'))
        (Select-ZinSuggestedPreset -Presets $presets -Readiness ([pscustomobject]@{ Ready = $false })).requiresWin11 | Should -BeFalse
        (Select-ZinSuggestedPreset -Presets $presets -Readiness ([pscustomobject]@{ Ready = $true })).name | Should -Be 'Win11-Pro-Shop'
    }
}

Describe 'Test-ZinWin11Cpu' {
    It 'classifies <Name>' -ForEach @(
        @{ Name = 'Intel(R) Core(TM) i5-6300U CPU @ 2.40GHz'; Ok = $false },
        @{ Name = 'Intel(R) Core(TM) i7-7600U CPU @ 2.80GHz'; Ok = $false },
        @{ Name = 'Intel(R) Core(TM) i5-8350U CPU @ 1.70GHz'; Ok = $true },
        @{ Name = 'Intel(R) Core(TM) i7-10510U CPU @ 1.80GHz'; Ok = $true },
        @{ Name = '12th Gen Intel(R) Core(TM) i5-1235U'; Ok = $true },
        @{ Name = 'Intel(R) Core(TM) i7-1065G7 CPU @ 1.30GHz'; Ok = $true },
        @{ Name = 'Intel(R) Core(TM) Ultra 7 155H'; Ok = $true },
        @{ Name = 'AMD Ryzen 5 1600 Six-Core Processor'; Ok = $false },
        @{ Name = 'AMD Ryzen 7 PRO 4750U with Radeon Graphics'; Ok = $true },
        @{ Name = 'Intel(R) Celeron(R) CPU N3060 @ 1.60GHz'; Ok = $false }
    ) {
        Test-ZinWin11Cpu $Name | Should -Be $Ok
    }
}

Describe 'Expand-ZinOfflinePath' {
    It 'maps environment variables to the offline root' {
        Expand-ZinOfflinePath -Path '%ProgramFiles(x86)%\UltraViewer\a.exe' -WindowsRoot 'W:\' | Should -Be 'W:\Program Files (x86)\UltraViewer\a.exe'
        Expand-ZinOfflinePath -Path '%ProgramFiles%\UniKey' -WindowsRoot 'W:' | Should -Be 'W:\Program Files\UniKey'
        Expand-ZinOfflinePath -Path '%SystemRoot%\Fonts' -WindowsRoot 'W:\' | Should -Be 'W:\Windows\Fonts'
    }
}
