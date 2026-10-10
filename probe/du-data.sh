#!/system/bin/sh
echo "=== /data top-level usage (MiB) ==="
du -m -d 1 /data 2>/dev/null | sort -rn | head -20
echo "=== /data/adb (magisk) ==="
du -m -d 1 /data/adb 2>/dev/null | sort -rn | head -10
echo "=== biggest single files in /data (>50M) ==="
find /data -type f -size +50M -exec ls -l {} \; 2>/dev/null | head -25
echo "=== cache dirs ==="
du -m -d 1 /data/cache 2>/dev/null | sort -rn | head -10
du -m -d 1 /data/media 2>/dev/null | sort -rn | head -5
echo "=== sdcard ==="
du -m -d 1 /sdcard 2>/dev/null | sort -rn | head -15
