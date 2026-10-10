#!/bin/sh
# What the v50 scheme does on the device, read back from the LEDs themselves.
#   led-probe.sh <what>
# where <what> is a list of steps: up5, up24, down, err, flash, show
L=/opt/mu300/bin/mu300-led
bright() {
    for c in sc27xx:red sc27xx:green sc27xx:blue keyboard-backlight; do
        printf '%s=%s ' "${c#sc27xx:}" "$(cat /sys/class/leds/$c/brightness 2>/dev/null)"
    done
}
show() {
    printf 'band=%-5s net=%-10s colour=%-13s  %s\n' \
        "$(/opt/mu300/bin/mu300-wifi-band 2>/dev/null | sed 's/hotspot: //')" \
        "$(cat /run/mu300/led/.net 2>/dev/null)" \
        "$(cat /run/mu300/led/.color 2>/dev/null)" \
        "$(bright)"
}
printf 'device=%s scheme=%s no_net=%s net5=%s net24=%s flash=%s level=%s timeout=%s\n' \
    "$(/opt/mu300/bin/mu300-device)" \
    "$(sed -n 's/^LED_SCHEME=//p' /etc/mu300/led.conf)" \
    "$(sed -n 's/^NO_NET_CHANNEL=//p' /etc/mu300/led.conf)" \
    "$(sed -n 's/^NET5_CHANNEL=//p' /etc/mu300/led.conf)" \
    "$(sed -n 's/^NET24_CHANNEL=//p' /etc/mu300/led.conf)" \
    "$(sed -n 's/^KEY_FLASH_COUNT=//p' /etc/mu300/led.conf)" \
    "$(sed -n 's/^#*LED_LEVEL=//p' /etc/mu300/led.conf)" \
    "$(sed -n 's/^LED_TIMEOUT=//p' /etc/mu300/led.conf)"
show
for step in "$@"; do
    case $step in
        up5)   $L data on ;;
        up24)  $L data 5g ;;
        down)  $L data off ;;
        err)   $L data error ;;
        wifi)  $L wifi sync ;;
        flash) printf -- '-- flash --\n'; $L flash ;;
        blink) # sample the lit colour while it flashes: the end state alone would look identical to no flash
            printf -- '-- flash, sampled every 0.15 s --\n'
            c=$(cat /run/mu300/led/.color 2>/dev/null)
            # this system's own sleep takes no fraction ("sleep: invalid number"); the release's does
            BB=/opt/mu300/bin/busybox
            ( $L flash ) & $BB sleep 0.05
            i=0
            while [ "$i" -lt 14 ]; do
                printf '%s ' "$(cat /sys/class/leds/$c/brightness 2>/dev/null)"
                i=$((i + 1))
                $BB sleep 0.15
            done
            wait
            printf '\n' ;;
        siren) # what a held key shows before the power goes: red, white, blue in turn (mu300-led alarm)
            BB=/opt/mu300/bin/busybox
            printf -- '-- alarm on, 12 samples of 0.2 s over red/green/blue --\n'
            $L alarm on
            $BB sleep 0.2
            i=0
            while [ "$i" -lt 12 ]; do
                printf '%s/%s/%s ' \
                    "$(cat /sys/class/leds/sc27xx:red/brightness 2>/dev/null)" \
                    "$(cat /sys/class/leds/sc27xx:green/brightness 2>/dev/null)" \
                    "$(cat /sys/class/leds/sc27xx:blue/brightness 2>/dev/null)"
                i=$((i + 1))
                $BB sleep 0.2
            done
            $L alarm off
            printf '\nalarm off -> %s\n' "$(show)" ;;
        show)  ;;
        *)      printf 'unknown step: %s\n' "$step" >&2; exit 2 ;;
    esac
    printf '%-6s -> %s\n' "$step" "$(show)"
done
