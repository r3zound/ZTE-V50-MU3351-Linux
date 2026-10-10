#!/system/bin/sh
echo "=== WiFi / BT chip ==="
getprop | grep -iE "wlan|wifi|bluetooth|bt\." | head -30
echo "=== wifi driver module ==="
ls /vendor/lib/modules/ 2>/dev/null | head -30
echo "=== dmesg wifi ==="
dmesg 2>/dev/null | grep -iE "wlan|sprdwl|uwe|wifi" | head -20
echo "=== GPU ==="
getprop | grep -iE "gpu|mali|gralloc" | head -15
echo "=== LED gpios / sysfs ==="
ls /sys/class/leds/ 2>/dev/null | head -30
echo "=== network ifaces ==="
ip link 2>/dev/null | head -30
echo "=== usb gadget/otg ==="
getprop | grep -iE "sys.usb|usb.config|gadget" | head -15
echo "=== kernel ==="
uname -a
echo "=== zte board id ==="
getprop ro.boot.zte_boardid
getprop ro.build.fingerprint
