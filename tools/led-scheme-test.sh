#!/bin/sh
# mu300-led's v50 scheme, checked without a device: a fake / under MU300_SYSROOT, a stub mu300-device, and an `iw`
# that reports whatever channel CH is set to. Run it with bash or the device's busybox ash:
#
#   MU300_LED=tools/mu300-linux/rootfs/overlay/opt/mu300/bin/mu300-led sh tools/led-scheme-test.sh
#
# What it holds down: the one colour out of two states, that the network wins over the band, that no two channels are
# ever lit at once, that a state change while the LEDs are dark is shown on the next wake, and that a device without
# the scheme keeps the F50's colours (that is the whole reason LED_SCHEME exists).
LED=${MU300_LED:-$(dirname "$0")/mu300-linux/rootfs/overlay/opt/mu300/bin/mu300-led}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export MU300_SYSROOT=$T/root
export MU300_BIN=$T/bin
export MU300_LED_CONF=$T/led.conf
mkdir -p "$MU300_SYSROOT/run/mu300/led" "$MU300_SYSROOT/sys/class/leds" "$MU300_BIN" "$T/stub"
for l in sc27xx:red sc27xx:green sc27xx:blue keyboard-backlight; do
    mkdir -p "$MU300_SYSROOT/sys/class/leds/$l"
    echo 255 > "$MU300_SYSROOT/sys/class/leds/$l/max_brightness"
    echo 0 > "$MU300_SYSROOT/sys/class/leds/$l/brightness"
done
printf '#!/bin/sh\necho f50\n' > "$MU300_BIN/mu300-device"
printf '#!/bin/sh\n[ -n "$CH" ] && { echo "	channel $CH"; exit 0; }\necho "Interface wlan0"\n' > "$T/stub/iw"
chmod +x "$MU300_BIN/mu300-device" "$T/stub/iw"
PATH="$T/stub:$PATH"; export PATH

fail=0
leds() {   # leds: every channel as it is now, red:brightness green:brightness blue:brightness backlight:brightness
    for l in sc27xx:red sc27xx:green sc27xx:blue keyboard-backlight; do
        printf '%s ' "$(cat "$MU300_SYSROOT/sys/class/leds/$l/brightness")"
    done
}
want() {   # want DESCRIPTION RED GREEN BLUE BACKLIGHT [CHANNEL]
    _d=$1; _ch=$5; shift
    _w="$1 $2 $3 $4 "
    CH=$_ch
    _g=$(leds)
    if [ "$_g" = "$_w" ]; then
        printf '  ok   %s\n' "$_d"
    else
        printf '  FAIL %s\n       want %s       got  %s\n' "$_d" "$_w" "$_g"
        fail=$((fail + 1))
    fi
}
color() { cat "$MU300_SYSROOT/run/mu300/led/.color" 2>/dev/null; }
net() { cat "$MU300_SYSROOT/run/mu300/led/.net" 2>/dev/null; }

printf '# the V50 scheme\nLED_SCHEME=v50\n' > "$MU300_LED_CONF"
rm -f "$MU300_SYSROOT/run/mu300/led"/* "$MU300_SYSROOT/run/mu300/led"/.[!.]* 2>/dev/null

echo 'scheme v50, 5 GHz:'
CH=36 "$LED" wifi on   # the hotspot is up; the network has not said anything yet, and that counts as none
want 'nothing known yet is red' 255 0 0 48 36
CH=36 "$LED" data on
[ "$(color)" = sc27xx:green ] && printf '  ok   colour remembered as green\n' || { printf '  FAIL colour=%s\n' "$(color)"; fail=$((fail+1)); }
[ "$(net)" = up ] && printf '  ok   network state kept\n' || { printf '  FAIL net=%s\n' "$(net)"; fail=$((fail+1)); }
want 'data on over 5 GHz is white' 0 255 0 48 36

CH=6 "$LED" wifi on
want '5 GHz -> 2.4 GHz is blue'  0 0 255 48 6

CH=36 "$LED" wifi on
want '2.4 GHz -> 5 GHz is white' 0 255 0 48 36

echo 'the network wins over the band:'
CH=6 "$LED" data error
want 'no service on 2.4 GHz is red' 255 0 0 48 6
CH=6 "$LED" data off
want 'data off on 2.4 GHz is red'   255 0 0 48 6
CH=6 "$LED" data on
want 'back on 2.4 GHz is blue'     0 0 255 48 6

echo 'while the LEDs are dark, and on the next wake:'
CH=36 "$LED" idle on
want 'idle is dark' 0 0 0 0 36
CH=36 "$LED" data on
want 'a change while dark writes no LED' 0 0 0 0 36
[ "$(net)" = up ] || { printf '  FAIL the dark change was not remembered\n'; fail=$((fail+1)); }
CH=36 "$LED" idle off
want 'idle off shows it again' 0 255 0 48 36

echo 'the scheme is off by default (the F50 keeps its colours):'
printf '# nothing here\n' > "$MU300_LED_CONF"
CH=36 "$LED" data 5g
want 'data 5g is the classic green' 0 255 0 48 36
CH=6 "$LED" data on
want 'data on is the classic blue' 0 0 255 48 6
CH=36 "$LED" data error
want 'data error is the classic red' 255 0 0 48 36

echo 'LED_LEVEL turns a colour down without touching the rest:'
printf 'LED_SCHEME=v50\nLED_LEVEL=50\n' > "$MU300_LED_CONF"
CH=36 "$LED" data on
want 'half of max_brightness (255*50/100)' 0 127 0 48 36

echo 'flash leaves the colour it found:'
printf 'LED_SCHEME=v50\n' > "$MU300_LED_CONF"
CH=36 "$LED" data on
CH=36 "$LED" flash
want 'flash settles back' 0 255 0 48 36

[ "$fail" = 0 ] && echo 'all good' || echo "$fail failed"
exit $((fail > 0))
