#!/system/bin/sh
# Replicate install.sh region_probe: find end of last partition, compute free space after it.
# GPT: protective MBR LBA0, primary header LBA1, 128 entries x 128B at LBA2.
DEV=/dev/block/mmcblk0
disk=$(cat /sys/block/mmcblk0/size)
echo "disk sectors: $disk"

# first usable LBA from primary header offset 40 (8 bytes LE)
dd if=$DEV bs=512 count=1 skip=1 of=/data/local/tmp/h.bin 2>/dev/null
first_usable=$(od -A n -t d8 -j 40 -N 8 /data/local/tmp/h.bin | tr -d ' ')
last_usable=$(od -A n -t d8 -j 48 -N 8 /data/local/tmp/h.bin | tr -d ' ')
echo "first_usable=$first_usable last_usable=$last_usable"

# read 128 partition entries (128*128 = 16384 bytes) starting at sector 2
dd if=$DEV bs=512 count=32 skip=2 of=/data/local/tmp/p.bin 2>/dev/null
echo "size of partition table bytes: $(stat -c %s /data/local/tmp/p.bin 2>/dev/null)"

# last end LBA: max over entries of entry[i].last_lba at offset 32 within each 128-byte record
maxend=0
i=0
while [ $i -lt 128 ]; do
  off=$((i * 128 + 32))
  e=$(od -A n -t d8 -j $off -N 8 /data/local/tmp/p.bin | tr -d ' ')
  # a used entry has a nonzero type GUID
  t=$(od -A n -t x1 -j $((i * 128)) -N 16 /data/local/tmp/p.bin | tr -d ' \n')
  if [ -n "$e" ] && [ "$e" != "0" ] && [ "$e" -gt "$maxend" ] 2>/dev/null; then
    maxend=$e
  fi
  i=$((i + 1))
done
echo "LAST_END=$maxend"
free_sectors=$((last_usable - maxend))
echo "free after last partition: $free_sectors sectors = $((free_sectors / 2 / 1024 / 1024)) MiB"
echo "disk total: $((disk / 2 / 1024 / 1024)) MiB"

echo "=== find newest few partition names by size ==="
ls -l /dev/block/by-name/ | awk '{print $9, $11}' | head -50
