# Reliable partition dump for the V50 (Windows equivalent of mu300-linux tools/backup-device.sh).
#
# Three failure modes this had to get right, all learned on this device:
#  1. A shell command with no output returns $null; calling .Trim() on it throws and kills the loop.
#     Every device command therefore goes through Out-String.
#  2. `adb pull` of a large raw partition can come back TRUNCATED with exit code 0, so every chunk's
#     size is checked and the whole file is verified against the device's own sha256sum.
#  3. /data was completely full once (a stray 17 GB dump), which silently truncated everything.
#     So: check free space first, and stage the dump in /data only when there is room.
param(
  [string]$Out = "D:\OneDrive\User\Network\CPE\V50\backup\2026-10-09-pre-install",
  [int]$ChunkMB = 8
)
$ErrorActionPreference = 'Continue'
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$s   = "192.168.0.1:5555"
$T   = "/data/local/tmp/mu300-dump.bin"

New-Item -ItemType Directory -Force -Path $Out | Out-Null
$sumsNew = "$Out\sha256sums.new.txt"
if (Test-Path $sumsNew) { Move-Item $sumsNew "$Out\sha256sums.new.old" -Force }

function Su([string]$c) { ((& $adb -s $s shell "su -c `"$c`"") | Out-String).Trim() }
function SuRaw([string]$c) { (& $adb -s $s shell "su -c `"$c`"") }

$freeLine = Su "df -k /data | tail -1"
$freeKb = [int64](($freeLine -split '\s+')[-3])
Write-Host ("==> /data free: {0} MiB" -f [math]::Round($freeKb/1024))
if ($freeKb -lt ($ChunkMB * 3 * 1024)) { Write-Host "    too little staging room; raise -ChunkMB down or free /data first"; exit 1 }

$CRITICAL = @('prodnv','miscdata','persist','ztecfg','ztepersist','calinv','isedata','teecfg_a','teecfg_b',
              'nr_fixnv1_a','nr_fixnv1_b','nr_fixnv2_a','nr_fixnv2_b','nr_runtimenv1','nr_runtimenv2',
              'nr_deltanv_a','nr_deltanv_b','nr_phy_a','nr_phy_b')
$BOOTCHAIN = @('sml_a','sml_b','uboot_a','uboot_b','trustos_a','trustos_b','vbmeta_a','vbmeta_b','misc')
if ($env:MU300_ONLY) { $CRITICAL = $env:MU300_ONLY.Split(','); $BOOTCHAIN = @() }

Write-Host ("==> Dumping to $Out")
Write-Host ""
$total = 0; $okCount = 0; $fail = @()
foreach ($p in ($CRITICAL + $BOOTCHAIN)) {
    $dev = Su "readlink -f /dev/block/by-name/$p 2>/dev/null"
    if (-not $dev) { Write-Host ("  {0,-16} not on this device, skipped" -f $p); continue }

    # blockdev is authoritative: a partition's sysfs size is not what dd will actually write
    # (miscdata is 1 MB although mmcblk0p10/size describes a different 64 MB partition)
    $bytes = [int64](Su "blockdev --getsize64 $dev 2>/dev/null")
    if ($bytes -le 0) { $bytes = [int64](Su "cat /sys/class/block/$(Split-Path $dev -Leaf)/size") * 1024 }
    $want = (Su "sha256sum $dev").Split(' ')[0]

    $chunk = [int64]$ChunkMB * 1MB
    $n = [int][math]::Ceiling($bytes / $chunk)
    $tmp = "$Out\.part_$p"
    $fs = [System.IO.File]::Create($tmp)
    $bad = $false
    for ($i = 0; $i -lt $n; $i++) {
        $skip = [int64]($i * $chunk / 512)
        $cnt  = [int64][math]::Min($chunk, $bytes - [int64]$i * $chunk) / 512
        if ($cnt -le 0) { break }
        SuRaw "dd if=$dev of=$T bs=512 skip=$skip count=$cnt 2>/dev/null" *> $null
        if (Test-Path "$Out\.chunk") { Move-Item "$Out\.chunk" "$Out\.chunk.old" -Force }
        & $adb -s $s pull $T "$Out\.chunk" *> $null
        if (-not (Test-Path "$Out\.chunk")) {
            Write-Host ("    [dbg] chunk {0}: pull produced no file (skip={1} cnt={2})" -f $i,$skip,$cnt)
            $devSize = Su "ls -l $T"
            Write-Host ("    [dbg] device file: {0}" -f $devSize)
            $bad = $true; break }
        $got = (Get-Item "$Out\.chunk").Length
        if ($got -ne ($cnt * 512)) {
            Write-Host ("    [dbg] chunk {0}: got {1} expected {2} (skip={3} cnt={4})" -f $i,$got,($cnt*512),$skip,$cnt)
            $bad = $true; break }
        $fs.Write([System.IO.File]::ReadAllBytes("$Out\.chunk"), 0, $got)
    }
    $fs.Close()
    foreach ($f in @("$Out\.chunk","$Out\.chunk.old")) { if (Test-Path $f) { Move-Item $f "$f.bak" -Force } }

    if ($bad) { Write-Host ("  {0,-16} DUMP FAILED (transfer)" -f $p); $fail += $p; continue }

    $have = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
    if ($have -ne $want) {
        Write-Host ("  {0,-16} CHECKSUM MISMATCH - not kept" -f $p); $fail += $p
        Move-Item $tmp "$Out\BAD-$p.img" -Force; continue
    }
    Move-Item $tmp "$Out\$p.img" -Force
    "$have  $p.img" | Out-File -FilePath $sumsNew -Append -Encoding utf8
    $sz = (Get-Item "$Out\$p.img").Length
    Write-Host ("  {0,-16} {1,6} MiB  ok" -f $p, [math]::Round($sz/1MB))
    $total += $sz; $okCount++
}
SuRaw "rm -f $T" *> $null
if (Test-Path $sumsNew) { Move-Item $sumsNew "$Out\sha256sums.txt" -Force }

SuRaw "dd if=/dev/block/mmcblk0 bs=512 count=34 2>/dev/null > $T" *> $null
& $adb -s $s pull $T "$Out\gpt-header.bin" *> $null
SuRaw "rm -f $T" *> $null
(Su "ls -l /dev/block/by-name") | Out-File "$Out\by-name.txt" -Encoding utf8

Write-Host ""
Write-Host ("==> {0} partitions, {1} MiB -> {2}" -f $okCount, [math]::Round($total/1MB), $Out)
if ($fail.Count -gt 0) { Write-Host ("    failed: " + ($fail -join ', ')) }
Write-Host "    Contains IMEI and calibration data - keep off the device, out of any repository."
