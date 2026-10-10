#!/bin/sh
# How many mu300-keys readers are running, and how old each is. Two of them means every key press is handled
# twice - a band switch twice in a row is no switch at all - so this has to be exactly one.
printf 'uptime now: %s s\n' "$(cut -d' ' -f1 /proc/uptime)"
printf 'HZ: %s\n' "$(getconf CLK_TCK 2>/dev/null)"
echo '--- mu300-keys / mu300-buttons processes ---'
for d in /proc/[0-9]*; do
    p=${d#/proc/}
    c=$(cat "$d/cmdline" 2>/dev/null | tr '\0' ' ')
    case $c in
        *mu300-keys*|*mu300-buttons*)
            ticks=$(cut -d' ' -f22 "$d/stat" 2>/dev/null)
            started=$(( ticks * 100 / $(getconf CLK_TCK 2>/dev/null || echo 100) ))
            printf 'pid=%-6s started=%-6ss ppid=%-6s cmd=%s\n' \
                "$p" "$started" "$(cut -d' ' -f4 "$d/stat" 2>/dev/null)" "$c"
            ;;
    esac
done
echo '--- what starts it ---'
grep -rl 'mu300-buttons' /etc/init.d/ 2>/dev/null
echo '--- input devices mu300-keys could open ---'
for e in /proc/bus/input/devices; do
    [ -r "$e" ] && grep -E '^(N|Name|H)' "$e" 2>/dev/null | head -40
done
