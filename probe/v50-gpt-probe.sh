#!/system/bin/sh
# V50 (ums9620_2h10_feimao) partition/GPT probe
echo "=== TOOLS ==="
for t in sgdisk parted fdisk lsblk busybox; do
  p=$(command -v $t 2>/dev/null)
  echo "$t: ${p:-MISSING}"
done

echo "=== GPT PARTS (by-name sizes in 512B blocks) ==="
for n in boot_a boot_b misc userdata cache super system product vndkro odm; do
  f=/dev/block/by-name/$n
  if [ -e "$f" ]; then
    sz=$(cat /sys/class/block/$(basename $(readlink -f $f))/size 2>/dev/null)
    echo "$n -> $sz blocks ($(($sz/2/1024/1024)) MiB)"
  else
    echo "$n -> ABSENT"
  fi
done

echo "=== mmcblk0 total ==="
echo "blocks: $(cat /sys/block/mmcblk0/size) = $(( $(cat /sys/block/mmcblk0/size) / 2 / 1024 / 1024 )) MiB"

echo "=== busybox fdisk -l (if available) ==="
if command -v busybox >/dev/null 2>&1; then
  busybox fdisk -l /dev/block/mmcblk0 2>&1 | head -80
fi

echo "=== modem / wifi ==="
ls /dev/ | grep -iE "modem|wlan|uart|tty" | head -20
echo "=== sdcard slot ==="
ls /dev/block/mmcblk1 2>&1 | head -3
