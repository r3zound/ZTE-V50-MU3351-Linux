#!/bin/sh
# The whole v50 lighting scheme end to end: the three colours, a key's flash, and the reboot siren.
#
# 5 GHz is faked with a stub iw on the PATH rather than by cutting the real band: mu300-led reads the band from
# `iw dev wlan0 info`, so a stub reporting channel 149 answers "5" without the Wi-Fi this script runs over ever
# dropping. Note $3, not $4, is "info" in that call, and the variable has to be exported - a stub that cannot see
# what it was told to report looks exactly like a device stuck on 2.4 GHz.
#
# Every state is held 12 s with a 3 s black gap between them, because the changes are silent: without the gap a
# fast eye sees one long colour and cannot tell whether anything happened at all.
BB=/opt/mu300/bin/busybox
LED=/opt/mu300/bin/mu300-led
STATE=/run/mu300/led

mkdir -p /tmp/fakebin
cat > /tmp/fakebin/iw <<'FAKEIW'
#!/bin/sh
[ "$3" = info ] || exit 0
echo "    interface wlan0"
echo "    ssid V50-fake"
echo "    type AP"
[ -n "$FAKE_CHANNEL" ] && echo "    channel $FAKE_CHANNEL"
FAKEIW
chmod +x /tmp/fakebin/iw

ts() { date +%H:%M:%S; }
color() { cat "$STATE/.color" 2>/dev/null; }
# set_band CHANNEL: a stub iw reporting that channel, so mu300-led's render() sees the band it should
set_band() { FAKE_CHANNEL=$1; export FAKE_CHANNEL; PATH=/tmp/fakebin:$PATH "$LED" data on >/dev/null 2>&1; }
dark() { "$LED" idle off >/dev/null 2>&1; :; }
pause() { "$BB" sleep "$1"; }

say() { printf '\n[%s] %s\n' "$(ts)" "$1"; }

restore() {
    rm -rf /tmp/fakebin
    FAKE_CHANNEL=6 "$LED" data on >/dev/null 2>&1
    printf '\n[%s] restored: %s (network up, 2.4 GHz)\n' "$(ts)" "$(color)"
}
trap restore EXIT INT TERM

printf '[%s] LED backend: %s / %s / i2c bus %s addr %s / GCR %s\n' "$(ts)" \
    "$(sed -n 's/^LED_SCHEME=//p' /etc/mu300/led.conf)" \
    "$(sed -n 's/^LED_BACKEND=//p' /etc/mu300/led.conf)" \
    "$(sed -n 's/^LED_I2C_BUS=//p' /etc/mu300/led.conf)" \
    "$(sed -n 's/^LED_I2C_ADDR=//p' /etc/mu300/led.conf)" \
    "$(sed -n 's/^LED_I2C_GCR=//p' /etc/mu300/led.conf)"

printf '\n================ PART 1: the three colours ================\n'

set_band 6
say "1/5  BLUE  - network up, 2.4 GHz      [$(color)]"
pause 12
dark; pause 3

"$LED" data off >/dev/null 2>&1
say "2/5  RED   - no network                [$(color)]"
pause 12
dark; pause 3

set_band 6
say "3/5  BLUE  - network back, 2.4 GHz     [$(color)]"
pause 12
dark; pause 3

set_band 149
say "4/5  WHITE - network up, 5 GHz         [$(color)]"
pause 12
dark; pause 3

set_band 6
say "5/5  BLUE  - back to 2.4 GHz           [$(color)]"
pause 12
dark; pause 3

printf '\n================ PART 2: a key'"'"'s flash ================\n'
set_band 6
n=1
while [ "$n" -le 3 ]; do
    say "flash $n/3: blue blinks twice (about 0.6 s)"
    "$LED" flash >/dev/null 2>&1
    pause 2
    n=$((n + 1))
done
set_band 6
pause 3

printf '\n================ PART 3: the reboot siren ================\n'
say "alarm on: red, green, blue in turn for 12 s"
"$LED" alarm on >/dev/null 2>&1
pause 12
"$LED" alarm off >/dev/null 2>&1
printf '[%s] alarm off\n' "$(ts)"
pause 3

printf '\n[%s] demonstration complete\n' "$(ts)"