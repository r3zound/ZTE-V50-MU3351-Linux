# Windows equivalent of mu300-linux tools/backup-device.sh
# Same partitions, same verification logic: dump with adb, then verify against the device's own sha256sum.
$ErrorActionPreference = 'Continue'
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$s   = "192.168.0.1:5555"
$OUT = "D:\OneDrive\User\Network\CPE\V50\backup\2026-10-09-pre-install"
$T   = "/data/local/tmp/mu300-pull.bin"

New-Item -ItemType Directory -Force -Path $OUT | Out-Null
$sums = "$OUT\sha256sums.txt"
if (Test-Path $sums) { Move-Item $sums "$sums.old" -Force }

$CRITICAL = @('prodnv','miscdata','persist','ztecfg','ztepersist','calinv','isedata','teecfg_a','teecfg_b',
              'nr_fixnv1_a','nr_fixnv1_b','nr_fixnv2_a','nr_fixnv2_b','nr_runtimenv1','nr_runtimenv2',
              'nr_deltanv_a','nr_deltanv_b','nr_phy_a','nr_phy_b')
$BOOTCHAIN = @('sml_a','sml_b','uboot_a','uboot_b','trustos_a','trustos_b','vbmeta_a','vbmeta_b','misc')

function Get-Su([string]$c) { (& $adb -s $s shell "su -c `"$c`"") | ForEach-Object { $_ } }

Write-Host "==> Backing up to $OUT`n"
$total = 0
foreach ($p in ($CRITICAL + $BOOTCHAIN)) {
    $dev = (Get-Su "readlink -f /dev/block/by-name/$p 2>/dev/null").Trim()
    if (-not $dev) { Write-Host "  $p : not on this device, skipped"; continue }

    # never stream binary through exec-out; write on device then pull (see issue #2 in the repo)
    & $adb -s $s shell "su -c 'cat $dev > $T'" *> $null
    & $adb -s $s pull $T "$OUT\$p.img" *> $null

    if (-not (Test-Path "$OUT\$p.img")) { Write-Host "  $p : pull failed, SKIPPED"; continue }
    $size = (Get-Item "$OUT\$p.img").Length
    if ($size -le 0) { Write-Host "  $p : empty, skipped"; continue }

    $want = ((Get-Su "sha256sum $dev") -join ' ') -split '\s+' | Select-Object -First 1
    $have = (Get-FileHash "$OUT\$p.img" -Algorithm SHA256).Hash.ToLower()
    if ($want -ne $have) { Write-Host "  $p : CHECKSUM MISMATCH - dump not trustworthy"; continue }

    "$have  $p.img" | Out-File -FilePath $sums -Append -Encoding utf8
    Write-Host ("  {0,-16} {1,6} MiB  ok" -f $p, [math]::Round($size/1MB))
    $total += $size
}
& $adb -s $s shell "su -c 'rm -f $T'" *> $null

# partition table + layout
& $adb -s $s shell "su -c 'dd if=/dev/block/mmcblk0 bs=512 count=34 2>/dev/null > $T'" *> $null
& $adb -s $s pull $T "$OUT\gpt-header.bin" *> $null
& $adb -s $s shell "su -c 'rm -f $T'" *> $null
Get-Su "for p in /sys/block/mmcblk0/mmcblk0p*; do echo \"`${p##*/} `$(cat `$p/start) `$(cat `$p/size)\"; done" | Out-File "$OUT\gpt-layout.txt" -Encoding utf8
Get-Su "ls -l /dev/block/by-name" | Out-File "$OUT\by-name.txt" -Encoding utf8

Write-Host "`n==> Done: $([math]::Round($total/1MB)) MiB in $OUT"
Write-Host "  Contains your IMEI and calibration data - keep off the device and out of any repository."
