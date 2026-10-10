# Pull the mu300 Linux boot log off the device after it has fallen back to Android.
# The initramfs writes every stage to /dev/kmsg at KERN_ERR, so it survives in the pstore ramoops buffer,
# and it also persists to boot_b at 48 MiB. Both are read here, exactly like the repo's tools/collect-logs.sh.
param(
  [string]$Out = "D:\OneDrive\User\Network\CPE\V50\logs",
  [string]$Serial = '<设备序列号>'
)
$ErrorActionPreference = 'Continue'
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$T = "/data/local/tmp/mu300-pull.bin"

New-Item -ItemType Directory -Force -Path $Out | Out-Null

# On this device root is only reachable via /debug_ramdisk/su (a symlink to MagiskSU), and it
# must be given `-c` -- bare `su id` opens an interactive shell, reads empty stdin and prints
# nothing. Probe the known candidates once and reuse the winner.
$SuBin = 'su'
foreach ($cand in @('/debug_ramdisk/su', '/system/xbin/su', '/system/bin/su')) {
  $probe = (& $adb -s $Serial shell "$cand -c id" 2>$null | Out-String).Trim()
  if ($probe -match 'uid=0') { $SuBin = $cand; break }
}
Write-Host "su binary: $SuBin"
function Su([string]$c) { ((& $adb -s $Serial shell "$SuBin -c '$c'") 2>$null | Out-String).Trim() }

Write-Host '=== device state ==='
$slot = Su 'getprop ro.boot.slot_suffix'
$ver  = Su 'getprop ro.build.display.id'
"slot : $slot"
"android: $ver"
($slot, $ver) | Out-File "$Out\state.txt" -Encoding utf8

if ($slot -eq '_b') { $LS = 'a' } else { $LS = 'b' }
"linux slot (where the log lives): boot_$LS"

# --- pstore: the kernel/initramfs log of the failed boot
Write-Host ''
Write-Host '=== pstore ==='
$ps = Su 'ls /sys/fs/pstore'
$ps
foreach ($f in ($ps -split "`n")) {
    $f = $f.Trim(); if (-not $f) { continue }
    Su "cat /sys/fs/pstore/$f > $T" *> $null
    & $adb -s $Serial pull $T "$Out\$f" *> $null
    "  pulled $f"
}

# --- LK log: bootloader decisions, including the rollback counter
Write-Host ''
Write-Host '=== uboot log ==='
Su "dd if=/dev/block/by-name/uboot_log bs=1M count=4 2>/dev/null > $T" *> $null
& $adb -s $Serial pull $T "$Out\uboot_log.raw" *> $null

# --- init's own persist block at 48 MiB of boot_b (8 MiB)
Write-Host ''
Write-Host '=== init persist log (boot_b @48MiB) ==='
Su "dd if=/dev/block/by-name/boot_$LS bs=4096 skip=12288 count=2048 2>/dev/null > $T" *> $null
& $adb -s $Serial pull $T "$Out\linux-persist.raw" *> $null
Su "rm -f $T" *> $null

# turn the binary blobs into readable text
foreach ($raw in @("$Out\linux-persist.raw")) {
    if (Test-Path $raw) {
        $bytes = [System.IO.File]::ReadAllBytes($raw)
        $txt = -join ($bytes | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127 -or $_ -eq 10 -or $_ -eq 13) { [char]$_ } else { ' ' } })
        Set-Content -Path ($raw -replace '\.raw$','.txt') -Value $txt -Encoding utf8
    }
}
if (Test-Path "$Out\uboot_log.raw") {
    $bytes = [System.IO.File]::ReadAllBytes("$Out\uboot_log.raw")
    $sb = New-Object System.Text.StringBuilder
    $cur = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) {
        if ($b -ge 32 -and $b -lt 127) { [void]$cur.Append([char]$b) }
        else { if ($cur.Length -ge 6) { [void]$sb.AppendLine($cur.ToString()) }; [void]$cur.Clear() }
    }
    if ($cur.Length -ge 6) { [void]$sb.AppendLine($cur.ToString()) }
    Set-Content -Path "$Out\uboot_log.txt" -Value $sb.ToString() -Encoding utf8
}

Write-Host ''
Write-Host "=== saved to $Out ==="
Get-ChildItem $Out | Select-Object Name, Length | Format-Table -AutoSize

$persist = "$Out\linux-persist.txt"
if (Test-Path $persist) {
    Write-Host ''
    Write-Host '=== init stages (boot/init) ==='
    (Get-Content $persist) | Select-String -Pattern 'stage=' | Select-Object -Last 60 | ForEach-Object { $_.Line.Trim() }
}
$lk = "$Out\uboot_log.txt"
if (Test-Path $lk) {
    Write-Host ''
    Write-Host '=== bootloader slot decisions ==='
    (Get-Content $lk) | Select-String -Pattern 'slot|tries|rollback|boot' | Select-Object -Last 25 | ForEach-Object { $_.Line.Trim() }
}
