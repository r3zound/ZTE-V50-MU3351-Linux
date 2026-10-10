#!/system/bin/sh
# Parse GPT primary header directly: gives last-used LBA and first-usable LBA.
DEV=/dev/block/mmcblk0
OUT=/data/local/tmp/gpt_head.bin
dd if=$DEV of=$OUT bs=512 count=34 2>/dev/null
echo "=== GPT HEADER (LBA1) HEX ==="
dd if=$DEV bs=512 count=1 skip=1 2>/dev/null | od -A d -t x1 | head -40
echo "=== PARTITION ENTRIES (LBA2..33) type guids ==="
dd if=$DEV bs=512 count=32 skip=2 2>/dev/null | od -A d -t x1 | head -10
echo "=== sgdisk --help ==="
sgdisk --help 2>&1 | head -30
