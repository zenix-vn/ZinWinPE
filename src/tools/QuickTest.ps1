<#
.SYNOPSIS
  One-button shop hardware test (design P2): disk SMART, battery, keyboard, screen, speakers L/R,
  microphone record/playback, webcam presence. The technician marks each step Pass/Fail;
  the result is saved to ZINDATA\Reports\<serial>_<date>_test.txt.
#>
[CmdletBinding()]
param()
$ScriptsRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ScriptsRoot 'common\ZinCommon.psm1') -DisableNameChecking -Force
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$info = Get-ZinMachineInfo
$results = [ordered]@{}

function Ask([string]$Step, [string]$Detail = '') {
    $r = [System.Windows.Forms.MessageBox]::Show("$Step`n$Detail`n`nPASS?", 'ZinWinPE QuickTest', 'YesNoCancel', 'Question')
    $results[$Step] = switch ($r) { 'Yes' { 'PASS' } 'No' { 'FAIL' } default { 'SKIP' } }
}

# 1. Disks (SMART via Storage reliability counters)
$diskLines = @()
try {
    foreach ($pd in Get-PhysicalDisk | Where-Object BusType -ne 'USB') {
        $rel = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        $diskLines += ("{0} {1}GB {2} wear={3}% temp={4}C" -f $pd.FriendlyName, [math]::Round($pd.Size / 1GB), $pd.HealthStatus, $(if ($rel) { $rel.Wear } else { '?' }), $(if ($rel) { $rel.Temperature } else { '?' }))
    }
} catch { $diskLines += 'Storage module unavailable - use CrystalDiskInfo' }
$results['Disk'] = if (@($diskLines | Where-Object { $_ -match 'Unhealthy|Warning' }).Count) { 'FAIL' } else { 'PASS' }
$results['Disk detail'] = $diskLines -join ' | '

# 2. Battery
if ($info.Batteries.Count -gt 0) {
    $b = $info.Batteries[0]
    $results['Battery'] = if ($null -ne $b.WearPercent -and $b.WearPercent -gt 40) { 'FAIL' } else { 'PASS' }
    $results['Battery detail'] = "wear $($b.WearPercent)% ($($b.FullmWh)/$($b.DesignmWh) mWh)"
} else { $results['Battery'] = 'N/A' }

# 3. Keyboard: every key pressed lights up in the list
$f = New-Object System.Windows.Forms.Form
$f.Text = 'Keyboard test - press every key, then close'; $f.Size = New-Object System.Drawing.Size(900, 420); $f.KeyPreview = $true; $f.StartPosition = 'CenterScreen'
$tb = New-Object System.Windows.Forms.TextBox; $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.Dock = 'Fill'; $tb.Font = New-Object System.Drawing.Font('Consolas', 14)
$f.Controls.Add($tb)
$seen = New-Object 'System.Collections.Generic.SortedSet[string]'
$f.Add_KeyDown({ param($s, $e) [void]$seen.Add("$($e.KeyCode)"); $tb.Text = ($seen -join '  '); $e.Handled = $true; $e.SuppressKeyPress = $true })
[void]$f.ShowDialog()
Ask 'Keyboard' "$($seen.Count) keys detected"

# 4. Screen: full-screen colours, click/any key for next
$colors = @('Red', 'Lime', 'Blue', 'White', 'Black', 'Gray')
$sf = New-Object System.Windows.Forms.Form
$sf.FormBorderStyle = 'None'; $sf.WindowState = 'Maximized'; $sf.TopMost = $true; $sf.KeyPreview = $true
$script:ci = 0; $sf.BackColor = [System.Drawing.Color]::FromName($colors[0])
$next = { $script:ci++; if ($script:ci -ge $colors.Count) { $sf.Close() } else { $sf.BackColor = [System.Drawing.Color]::FromName($colors[$script:ci]) } }
$sf.Add_Click($next); $sf.Add_KeyDown($next)
[void]$sf.ShowDialog()
Ask 'Screen' 'Dead pixels / lines / backlight bleed?'

# 5. Speakers: tone left then right (generated 16-bit stereo WAV)
function New-ToneWav([int]$Channel, [int]$Freq = 660, [double]$Seconds = 1.2) {
    $rate = 44100; $n = [int]($rate * $Seconds)
    $ms = New-Object System.IO.MemoryStream; $w = New-Object System.IO.BinaryWriter($ms)
    $w.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $w.Write([int](36 + $n * 4)); $w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
    $w.Write([int]16); $w.Write([int16]1); $w.Write([int16]2); $w.Write([int]$rate); $w.Write([int]($rate * 4)); $w.Write([int16]4); $w.Write([int16]16)
    $w.Write([Text.Encoding]::ASCII.GetBytes('data')); $w.Write([int]($n * 4))
    for ($i = 0; $i -lt $n; $i++) {
        $v = [int16](12000 * [math]::Sin(2 * [math]::PI * $Freq * $i / $rate))
        if ($Channel -eq 0) { $w.Write($v); $w.Write([int16]0) } else { $w.Write([int16]0); $w.Write($v) }
    }
    $ms.Position = 0; $ms
}
try {
    (New-Object System.Media.SoundPlayer (New-ToneWav 0)).PlaySync()
    Start-Sleep -Milliseconds 300
    (New-Object System.Media.SoundPlayer (New-ToneWav 1 880)).PlaySync()
    Ask 'Speakers' 'Low tone LEFT, then high tone RIGHT'
} catch { $results['Speakers'] = "ERROR $($_.Exception.Message)" }

# 6. Microphone: record 4 s with winmm MCI, play back
try {
    $sig = '[DllImport("winmm.dll", CharSet = CharSet.Auto)] public static extern int mciSendString(string cmd, System.Text.StringBuilder ret, int len, IntPtr cb);'
    $mci = Add-Type -MemberDefinition $sig -Name ZinMci -Namespace Zin -PassThru
    $wav = Join-Path $env:TEMP 'zin-mic.wav'
    [System.Windows.Forms.MessageBox]::Show('Speak for 4 seconds after OK', 'Microphone') | Out-Null
    [void]$mci::mciSendString('open new type waveaudio alias zinrec', $null, 0, [IntPtr]::Zero)
    [void]$mci::mciSendString('record zinrec', $null, 0, [IntPtr]::Zero)
    Start-Sleep -Seconds 4
    [void]$mci::mciSendString('stop zinrec', $null, 0, [IntPtr]::Zero)
    [void]$mci::mciSendString("save zinrec `"$wav`"", $null, 0, [IntPtr]::Zero)
    [void]$mci::mciSendString('close zinrec', $null, 0, [IntPtr]::Zero)
    if (Test-Path $wav) { (New-Object System.Media.SoundPlayer $wav).PlaySync() }
    Ask 'Microphone' 'Did you hear the recording?'
} catch { $results['Microphone'] = "ERROR $($_.Exception.Message)" }

# 7. Webcam: presence only (PE has no camera app)
$cams = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPClass -in @('Camera', 'Image') })
$results['Webcam'] = if ($cams.Count) { "DETECTED: $(($cams | ForEach-Object Name) -join ', ')" } else { 'NOT DETECTED' }

# Save
$out = @("ZinWinPE QuickTest  $(Get-Date -Format 'yyyy-MM-dd HH:mm')", "$($info.Manufacturer) $($info.FriendlyName)  S/N $($info.Serial)", '')
foreach ($k in $results.Keys) { $out += ('{0,-16} {1}' -f $k, $results[$k]) }
$text = $out -join "`r`n"
$zd = Find-ZinData
if ($zd) {
    $p = Join-Path $zd ("Reports\{0}_{1:yyyyMMdd-HHmm}_test.txt" -f ($info.Serial -replace '[^\w\-]', '_'), (Get-Date))
    Write-ZinUtf8File -Path $p -Content $text
    $text += "`r`n`r`nSaved: $p"
}
[System.Windows.Forms.MessageBox]::Show($text, 'ZinWinPE QuickTest') | Out-Null
