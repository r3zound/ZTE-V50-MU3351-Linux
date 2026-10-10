# Re-apply the V50 port patches to a fresh checkout of dikeckaan/mu300-linux.
# Run once, after `git clone`, before running install.ps1.
#
# Eighteen steps, all idempotent (each one checks for its own marker first). Steps 1-15 patch
# upstream files, 17 writes the apk feed, 18 is an encoding gate over everything that ships.
# The three headline problems each early step fixes are listed here; every step carries its own
# longer note explaining why the naive fix does not work.
#
#   1. Device detection (install.sh + install.ps1). V50 reports "V50 / MU3351", which matches none of the
#      project's patterns, so the installer treats it as "not an F50" and stops. install.ps1 carries THREE
#      independent regexes and does not share install.sh's, so patching only the shell script is not enough -
#      that was the first failure seen here.
#   2. MU300_USBNET on the kernel command line. Windows 10 IoT LTSC 21H2 ships an usbncm.inf that matches the
#      device's compatible ID but has no catalog file (UsbNcmFn.cat), so pnputil refuses it ("third-party INF
#      contains no digital signature"). RNDIS needs no INF at all: rndis.sys is inbox. This patch lets the
#      image be built with MU300_USBNET=rndis when the env var is set.
#   3. Bounded Wi-Fi bring-up on OpenWrt (etc/init.d/mu300-hw). That script runs before netifd, and anything
#      slow or hanging in it costs the device its network and its login. On the V50 the Marlin3 stack blocked
#      there: the hotspot associated and dnsmasq answered DHCP, but dropbear and uhttpd never started, so the
#      device was unreachable with no symptom on screen. Each step now runs under a deadline.
param([string]$Repo = "D:\OneDrive\User\Network\CPE\V50\tools\mu300-linux")
$ErrorActionPreference = 'Stop'
$patched = 0

function Patch([string]$file, [string]$find, [string]$replace, [string]$what) {
    if (-not (Test-Path $file)) { Write-Host "  SKIP $what : $file not found"; return }
    # Normalise every newline to LF before comparing.
    #
    # The upstream tree is LF everywhere. A PowerShell here-string inherits the line endings of THIS script,
    # which is CRLF on Windows, so a multi-line $find never matches even though it looks identical - the
    # anchor simply was not there as far as -contains was concerned. Normalising both sides makes the
    # anchors work no matter which editor or platform wrote either file.
    $t = ([IO.File]::ReadAllText($file)) -replace "`r`n", "`n"
    $f = $find    -replace "`r`n", "`n"
    $r = $replace -replace "`r`n", "`n"
    if ($t.Contains($r)) { Write-Host "  already: $what"; return }
    if (-not $t.Contains($f)) { Write-Host "  MISS  $what : pattern not found in $file"; return }
    # write back with the LF the rest of the tree uses, and with UTF-8 and NO BOM, explicitly.
    #
    # The BOM matters (V50, 2026-10-10): upstream commits openwrt/overlay/etc/init.d/mu300-hw as UTF-16LE,
    # which ReadAllText decodes correctly but leaves every byte of the file wider. Written back as-is the
    # kernel cannot parse the shebang, busybox init fails the script without a word, and the whole hardware
    # bring-up - including the Marlin3 Wi-Fi insmod - never happens: no wlan0, no AP, no DHCP, yet dropbear
    # and uhttpd are up so nothing anywhere says the script did not run. Spelled out rather than left to the
    # default so the next edit cannot quietly change it.
    [IO.File]::WriteAllText($file, $t.Replace($f, $r), (New-Object Text.UTF8Encoding($false)))
    Write-Host "  patched: $what"
    $script:patched++
}

Write-Host "=== 1. device detection ==="
Patch "$Repo\install.sh" `
    '    *MU300*|*F50*|*mu300*) DEVICE=f50 ;;' `
    '    *MU300*|*F50*|*mu300*|*V50*|*MU3351*) DEVICE=f50 ;;' `
    'install.sh: model -> DEVICE=f50'

Patch "$Repo\install.ps1" `
    "} elseif (`$model -notmatch 'MU300|F50|mu300') {" `
    "} elseif (`$model -notmatch 'MU300|F50|mu300|V50|MU3351') {" `
    'install.ps1:416 model check'

Patch "$Repo\install.ps1" `
    "`$f50 = @(`$all | Where-Object { `$_ -match 'model:F50|product:MU300|device:MU300|device:U30Air' })" `
    "`$f50 = @(`$all | Where-Object { `$_ -match 'model:F50|product:MU300|device:MU300|device:U30Air|model:V50|device:MU3351' })" `
    'install.ps1:219 SelectDevice filter'

# :372 has to be matched with enough context on its own: the bare tail above also occurs in :219,
# which would be patched twice or not at all depending on the order.
$oldT = "`$target = @((Quiet { adb devices -l }) | Where-Object { `$_ -match '^\S+\s+device\b' -and `$_ -match 'model:F50|product:MU300|device:MU300|device:U30Air' })"
$newT = "`$target = @((Quiet { adb devices -l }) | Where-Object { `$_ -match '^\S+\s+device\b' -and `$_ -match 'model:F50|product:MU300|device:MU300|device:U30Air|model:V50|device:MU3351' })"
Patch "$Repo\install.ps1" $oldT $newT 'install.ps1:372 target filter'
Write-Host ""
Write-Host "=== 2. keep the boot image's kernel command line exactly 'loglevel=5' ==="
# This was a MU300_USBNET patch, and it was reverted on 2026-10-10: two reasons, both learned the hard way.
#
# It did not work. The V50 enumerated as CDC NCM anyway - see docs/FINDINGS.md, which marks the RNDIS path
# "not measured, no Windows host". Nothing came of it.
#
# And it broke the only way into Linux. The Android side recognises a Linux boot image by reading 11 bytes
# at offset 44 of the image and comparing them with "loglevel=5\0"
# (android/magisk/mu300-linux-switch/switch.sh, and customize.sh when the Magisk module is installed).
# Appending " MU300_USBNET=rndis" changes the 11th byte to a space, so switch.sh then says
# "boot_b a boot image that is not Linux (the Android from before an update?)" and refuses to arm the
# slot: the device could not be switched into Linux from Android at all, with an error that points at the
# wrong thing entirely.
#
# So this is now a guard, not a feature: it undoes the patch if it is there and states why.
$rndisBlock = @'
# MU300_USBNET picks the USB network functions (see boot/init setup_usb_gadget). Empty keeps the
# project's own default (NCM, ECM as fallback). Set it to `rndis` for hosts whose Windows has no usable
# UsbNcm.inf: rndis.sys is inbox, so no INF and no driver package is needed.
_boot_cmdline = b'loglevel=5'
for _key in ('MU300_USBNET',):
    _val = os.environ.get(_key, '').strip()
    if _val:
        _boot_cmdline += b' ' + _key.encode() + b'=' + _val.encode()
BOOT_CMDLINE = _boot_cmdline
'@
$guardBlock = @'
# The boot image's kernel command line is also how the Android side recognises a Linux boot image:
# android/magisk/mu300-linux-switch/switch.sh reads 11 bytes at offset 44 and compares them with
# "loglevel=5\0" (android/magisk/mu300-linux-switch/customize.sh does the same when the module is
# installed). So this string must stay exactly that - appending to it (an extra MU300_USBNET=rndis was
# tried here and reverted) makes switch.sh report boot_b as "a boot image that is not Linux" and the
# device can no longer be switched into Linux from Android at all.
BOOT_CMDLINE = b'loglevel=5'
'@
Patch "$Repo\boot\build-boot-image.py" $rndisBlock.Trim() $guardBlock.Trim() 'build-boot-image.py: undo the MU300_USBNET kernel command line'
Patch "$Repo\boot\build-boot-image.py" "BOOT_CMDLINE = b'loglevel=5'" $guardBlock.Trim() 'build-boot-image.py: document why the command line must not grow'

Write-Host ""
Write-Host "=== 2b. switch.sh: recognise the Linux boot image without depending on its tail ==="
# Belt and braces for the same trap. Upstream compares the full 11 bytes including the NUL, so anything
# appended to the command line makes an installed Linux look like a stale Android slot. Comparing the
# 10-byte prefix still tells the two apart - Android's boot images have nothing at offset 44 at all - and
# cannot be broken by a future command-line change.
$swOld = @'
    cmdline_target=$(hex_of "$linux_boot" 44 11)
'@
$swNew = @'
    # the first 10 bytes of the command line, not all 11: "loglevel=5" identifies the image, the byte after
    # it does not. Android's boot images have nothing at offset 44, so the two are still told apart, and a
    # command line that grows (as one that adds MU300_USBNET=rndis did) no longer hides an installed Linux.
    cmdline_target=$(hex_of "$linux_boot" 44 10)
'@
$swOld = ($swOld -replace "^[\r\n]+", '' -replace "[\r\n]+$", '')
$swNew = ($swNew -replace "^[\r\n]+", '' -replace "[\r\n]+$", '')
Patch "$Repo\android\magisk\mu300-linux-switch\switch.sh" $swOld $swNew 'switch.sh: compare the command line prefix'
Patch "$Repo\android\magisk\mu300-linux-switch\switch.sh" 'LINUX_CMDLINE=6c6f676c6576656c3d3500    # "loglevel=5\0"' 'LINUX_CMDLINE=6c6f676c6576656c3d35      # "loglevel=5"' 'switch.sh: matching marker without the NUL'

Write-Host ""
Write-Host "=== 3. bounded Wi-Fi bring-up (OpenWrt) ==="
$oldBoot = @'
boot() {
	/opt/mu300/bin/mu300-led power on
'@
$newBoot = @'
# Run a bring-up step under a deadline, killing the whole process tree if it overruns.
#
# Why this exists (V50, 2026-10-09): this script runs before netifd, and a hanging step here costs the
# device its network and its login - busybox init only spawns the consoles after sysinit returns. The
# SC2355/Marlin3 stack (wcn_bsp, sprd_wlan_combo) is the known offender: insmod of sprd_wlan_combo can
# block for good on a board whose WLAN firmware differs from the tested one, and `wifi up` waits on the
# same driver. When that happened the hotspot still associated and dnsmasq even answered DHCP, but
# dropbear and uhttpd never came up, so the device was unreachable with nothing on screen saying why.
# Every step is therefore bounded: whatever fails, the rest of the boot continues and the SSH console
# stays available to look at it.
bringup_step() {  # bringup_step DEADLINE_SECONDS NAME COMMAND...
	_bg_deadline=$1; _bg_name=$2; shift 2
	_bg_pid=
	( "$@" ) >>/tmp/mu300-$_bg_name.log 2>&1 &
	_bg_pid=$!
	_bg_n=0
	while kill -0 "$_bg_pid" 2>/dev/null; do
		if [ "$_bg_n" -ge "$_bg_deadline" ]; then
			echo "$_bg_name: exceeded ${_bg_deadline}s, killed (continuing the boot)" >>/tmp/mu300-$_bg_name.log 2>&1
			# the step may have children (modprobe -> insmod, wifi -> hostapd): kill the group
			kill -TERM -"$_bg_pid" 2>/dev/null || kill -TERM "$_bg_pid" 2>/dev/null
			sleep 2
			kill -KILL -"$_bg_pid" 2>/dev/null || kill -KILL "$_bg_pid" 2>/dev/null
			break
		fi
		sleep 1
		_bg_n=$((_bg_n + 1))
	done
	wait "$_bg_pid" 2>/dev/null
	return 0
}

boot() {
	/opt/mu300/bin/mu300-led power on
'@

# the helper itself, once: check by its own definition rather than by the anchor around it, so a rerun on
# an already-patched tree does not add a second copy
$hwFile = "$Repo\openwrt\overlay\etc\init.d\mu300-hw"
if ((Test-Path $hwFile) -and (Select-String -Path $hwFile -Pattern '^bringup_step\(\)' -Quiet)) {
    Write-Host "  already: mu300-hw: bringup_step helper"
} else {
    Patch $hwFile $oldBoot $newBoot.Trim() 'mu300-hw: bringup_step helper'
}

$T = "`t"
$old1 = $T + "/opt/mu300/bin/extra-modules >/tmp/mu300-extra-modules.log 2>&1" + "`n" + $T + "/opt/mu300/bin/zram-start >/dev/null 2>&1" + "`n" + $T + "/opt/mu300/bin/wifi-start >/tmp/mu300-wifi-start.log 2>&1"
$new1 = $T + "bringup_step 60 extra-modules /opt/mu300/bin/extra-modules" + "`n" +
        $T + "bringup_step 30 zram-start /opt/mu300/bin/zram-start" + "`n" +
        $T + "# the Marlin3 stack: insmod of sprd_wlan_combo can block for good, so this is the bounded one that matters" + "`n" +
        $T + "bringup_step 90 wifi-start /opt/mu300/bin/wifi-start"
Patch "$Repo\openwrt\overlay\etc\init.d\mu300-hw" $old1 $new1 'mu300-hw: bounded extra-modules / zram-start / wifi-start'

$old2 = $T + "/opt/mu300/bin/regdb-load >>/tmp/mu300-wifi-start.log 2>&1" + "`n" + $T + "/opt/mu300/bin/openwrt-wifi-config >>/tmp/mu300-wifi-start.log 2>&1"
$new2 = $T + "bringup_step 20 regdb-load /opt/mu300/bin/regdb-load" + "`n" +
        $T + "bringup_step 45 openwrt-wifi-config /opt/mu300/bin/openwrt-wifi-config"
Patch "$Repo\openwrt\overlay\etc\init.d\mu300-hw" $old2 $new2 'mu300-hw: bounded regdb-load / openwrt-wifi-config'

$old3 = $T + '[ "$(/opt/mu300/bin/mu300-device)" = u30air ] && /opt/mu300/bin/mu300-nfc sync >/tmp/mu300-nfc.log 2>&1'
$new3 = $T + '[ "$(/opt/mu300/bin/mu300-device)" = u30air ] && bringup_step 20 mu300-nfc /opt/mu300/bin/mu300-nfc sync'
Patch "$Repo\openwrt\overlay\etc\init.d\mu300-hw" $old3 $new3 'mu300-hw: bounded mu300-nfc'

$old4 = $T + "wifi down >>/tmp/mu300-wifi-start.log 2>&1" + "`n" + $T + "wifi up >>/tmp/mu300-wifi-start.log 2>&1"
$new4 = $T + "bringup_step 60 wifi-down wifi down" + "`n" + $T + "bringup_step 60 wifi-up wifi up"
Patch "$Repo\openwrt\overlay\etc\init.d\mu300-hw" $old4 $new4 'mu300-hw: bounded wifi down / up'


Write-Host ""
Write-Host "=== 4. only re-arm the Linux slot when the boot is actually usable ==="
# Upstream mu300-post marks every boot successful 30 s after the service starts, without checking anything.
# On a boot where OpenWrt comes up but its services do not - V50, 2026-10-09: the hotspot associated, DHCP
# was there, but dropbear and uhttpd never started - that marks a broken boot as good. It is worse than
# cosmetic: mu300-next-boot --rearm also clears the initramfs counter (.mu300/boot-tries), so BOTH of the
# device's fallback counters are reset on every boot and the device can never return to Android by itself.
# No number of power cycles helps, because each one is undone. Ubuntu's mu300-boot-ok waits for the USB
# network and SSH; this makes OpenWrt behave the same way.
$oldPost = $T + 'procd_open_instance bootok' + "`n" +
           $T + 'procd_set_param command /bin/sh -c "sleep 30; exec /opt/mu300/bin/mu300-next-boot --rearm"' + "`n" +
           $T + 'procd_set_param env PATH="$PATH"' + "`n" +
           $T + 'procd_close_instance'
$newPost = @'
	# Re-arm the Linux slot only once the device is actually reachable.
	#
	# Upstream does this unconditionally 30 s after the service starts, which marks a boot "good" even when
	# OpenWrt came up but dropbear and uhttpd never did (V50, 2026-10-09). mu300-next-boot --rearm also
	# clears the initramfs counter .mu300/boot-tries, so an unconditional re-arm resets BOTH fallback
	# counters on every boot and the device can never return to Android on its own - power cycling stops
	# helping entirely. Ubuntu's mu300-boot-ok waits for the USB network and SSH first; do the same here.
	# ':0016 .* 0A' is a listening socket on port 22 in /proc/net/tcp.
	procd_open_instance bootok
	procd_set_param command /bin/sh -c "for i in $(seq 1 10); do grep -q ':0016 .* 0A ' /proc/net/tcp && { exec /opt/mu300/bin/mu300-next-boot --rearm; }; sleep 30; done; logger -t mu300-post 'no SSH after 5 min: not re-arming (the next boot returns to Android)'"
	procd_set_param env PATH="$PATH"
	procd_close_instance
'@
Patch "$Repo\openwrt\overlay\etc\init.d\mu300-post" $oldPost $newPost.Trim() 'mu300-post: re-arm only when SSH is listening'

Write-Host ""
Write-Host "=== 5. prove (and repair) the LAN path every boot ==="
$lancheck = @'
#!/bin/sh
# Report - and if needed repair - the LAN path a client depends on, once per boot.
#
# Why this exists (V50, 2026-10-09): a client could associate with the hotspot and then get nothing at all.
# Every part that decides whether it gets an address looked right afterwards - wlan0 a port of br-lan,
# br-lan at 192.168.77.1/24, dhcp.lan a dhcpv4 server, dnsmasq running - but nothing recorded the state
# AT BOOT, so a broken boot could not be told from a working one. The kernel log only showed the port
# reaching forwarding state, and the userspace log had been flooded out of the ring buffer by the
# sprd-wlan driver before anything could read it.
#
# The one thing this originally got wrong is the thing that actually broke the device: "the lan zone
# accepting input" was read out of /etc/config/firewall, where it is an option that was set. In the
# RENDERED ruleset the lan zone owned no interface at all, so fw4's input chain had no jump for
# br-lan and its policy dropped everything a client sent. UCI said ACCEPT; nothing on the device
# said otherwise. Hence fw-jump below, which reads the ruleset rather than the configuration.
#
# So: one line per boot with those facts, written to a file and to syslog. The next boot either proves the
# path works or names the one part that does not.
LOG=/tmp/mu300-lancheck.log
say() { echo "$(cut -d' ' -f1 /proc/uptime) $*" >>$LOG 2>/dev/null; logger -t mu300-lancheck "$*" 2>/dev/null; }

# netifd runs after mu300-post in the boot order; wait for the LAN to get its address (up to 2 minutes)
i=0
while [ $i -lt 24 ]; do
    ip -4 addr show br-lan 2>/dev/null | grep -q 'inet ' && break
    sleep 5
    i=$((i + 1))
done

# The hotspot has to exist, be a port of the LAN bridge, AND be carrying traffic. All three are needed,
# and the last two are why this was rewritten (V50, mainline kernel 6.18, 2026-10-10):
#
#   * wlan0 sat in the bridge with NO CARRIER and hostapd already given up. The original test asked only
#     "is wlan0 missing from brif", so it never fired and the device booted with no hotspot, no DHCP
#     server (udp67=0) and nothing on the device looking wrong.
#   * on the mainline kernel the FIRST bring-up always fails and a retry always succeeds:
#         at boot           hostapd: UNINITIALIZED->COUNTRY_UPDATE->DISABLED->AP-DISABLED
#         wifi down; wifi up  hostapd: COUNTRY_UPDATE->HT_SCAN->ENABLED->AP-ENABLED
#     `wifi up` alone does not clear it - the interface has to go down first - so every attempt does both.
#   * and when this runs the interface may not exist yet at all: br-lan gets its address from the lan
#     interface, which comes up before the wireless one. Guarding the whole block with `[ -d .../wlan0 ]`
#     (the first version of this fix did) skipped the repair in exactly the case it was written for, and
#     the log looked like a pass. Wait for wlan0 first, then repair.
# The regulatory database FIRST, and before the Wi-Fi is restarted below so hostapd picks the country
# up. cfg80211 asks for regulatory.db long before the rootfs is mounted and that first load always
# fails ("cfg80211: failed to load regulatory.db"); without it cfg80211 is stuck on the world domain,
# where EVERY 5 GHz channel is NO-IR, and hostapd refuses to start an AP:
#
#     Frequency 5180 (primary) not allowed for AP mode, flags: 0x40853 NO-IR
#     Could not select hw_mode and channel. (-3)   ->   AP-DISABLED
#
# Verified on the device: after this runs, `iw reg set US` reports "country US: DFS-FCC" and the same
# AP starts on channel 36; before it, `iw reg set` does nothing and the channel is refused. opt/mu300/bin/
# regdb-load feeds the database through /sys/class/firmware for the pending request and reloads; running
# it here, after netifd, is what makes the country in 90-mu300 mean anything. (V50, mainline 6.18,
# 2026-10-10)
/opt/mu300/bin/regdb-load >/dev/null 2>&1

_wi=0
while [ $_wi -lt 12 ] && [ ! -d /sys/class/net/wlan0 ]; do
    sleep 5
    _wi=$((_wi + 1))
done
_repair=0
while [ $_repair -lt 3 ]; do
    _st=$(cat /sys/class/net/wlan0/operstate 2>/dev/null)
    _port=$(ls /sys/class/net/br-lan/brif 2>/dev/null | grep -c '^wlan0$')
    _has=$( [ -d /sys/class/net/wlan0 ] && echo yes || echo no )
    [ "$_has" = yes ] && [ "$_st" = up ] && [ "$_port" = 1 ] && break
    _repair=$((_repair + 1))
    say "wlan0 not serving (exists=$_has operstate=$_st bridge-port=$_port): wifi down; wifi up (attempt $_repair)"
    wifi down 2>/dev/null
    sleep 3
    wifi up 2>/dev/null
    sleep 20
done

br=$(ip -4 addr show br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\/[0-9]*\).*/\1/p' | tr '\n' ' ')
ports=$(ls /sys/class/net/br-lan/brif 2>/dev/null | tr '\n' ' ')
wst=$(cat /sys/class/net/wlan0/operstate 2>/dev/null)
dm=$(pgrep dnsmasq 2>/dev/null | tr '\n' ' ')
# Listening sockets, hex ports. 0016 = 22 ssh and 0050 = 80 http are TCP and live in /proc/net/tcp;
# 0043 = 67 dhcp is UDP and lives in /proc/net/udp. Reading 67 out of /proc/net/tcp (as this did until
# 2026-10-10) can only ever answer "nothing is listening", however healthy the DHCP server is.
l22=$(grep -c ':0016 .* 0A ' /proc/net/tcp 2>/dev/null)
l80=$(grep -c ':0050 .* 0A ' /proc/net/tcp 2>/dev/null)
l67=$(grep -c ':0043 .* 0A ' /proc/net/udp 2>/dev/null)
# The range dnsmasq was actually started with, not the one /etc/config/dhcp asks for. The generated file
# has no fixed name (netifd writes /var/etc/dnsmasq.conf.cfg<hash>), so glob it without demanding a suffix.
rng=$(grep -h '^dhcp-range' /var/etc/dnsmasq.conf* 2>/dev/null | tr '\n' ';')
# Does fw4's input chain even hand br-lan to the lan zone? This is the one that decides everything:
# fw4 works out a zone's devices from the ports of its bridge, and br-lan is declared bridge_empty with
# wlan0 joining only when netifd brings the AP up. When that moment came too late the lan zone owned
# nothing, the input policy dropped every packet, and a client that had associated got no lease, no DNS,
# no LuCI and no SSH - while dnsmasq sat on 0.0.0.0:67 with a correct dhcp-range and never saw a
# DISCOVER. Nothing else on the device looks wrong when that happens, which is why it is reported here.
lanif=$(uci -q get network.lan.device 2>/dev/null)
fwlan=$(nft list chain inet fw4 input 2>/dev/null | grep -c "\"${lanif:-br-lan}\" jump")
say "br-lan=[$br] ports=[$ports] wlan0=$wst dnsmasq=[$dm] tcp22=$l22 tcp80=$l80 udp67=$l67 fw-jump=$fwlan range=[$rng]"
'@
$lancheckPath = "$Repo\openwrt\overlay\opt\mu300\bin\mu300-lancheck"
New-Item -ItemType Directory -Force -Path (Split-Path $lancheckPath) | Out-Null
# LF only: the device runs /bin/sh, and a CRLF shebang line fails there
[IO.File]::WriteAllText($lancheckPath, ($lancheck -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
Write-Host "  wrote: opt/mu300/bin/mu300-lancheck"

$oldLan = $T + 'procd_set_param command /bin/sh -c "for i in $(seq 1 10); do grep -q '':0016 .* 0A '' /proc/net/tcp && { exec /opt/mu300/bin/mu300-next-boot --rearm; }; sleep 30; done; logger -t mu300-post ''no SSH after 5 min: not re-arming (the next boot returns to Android)''"' + "`n" +
           $T + 'procd_set_param env PATH="$PATH"' + "`n" +
           $T + 'procd_close_instance' + "`n" +
           '}'
$newLan = $T + 'procd_set_param command /bin/sh -c "for i in $(seq 1 10); do grep -q '':0016 .* 0A '' /proc/net/tcp && { exec /opt/mu300/bin/mu300-next-boot --rearm; }; sleep 30; done; logger -t mu300-post ''no SSH after 5 min: not re-arming (the next boot returns to Android)''"' + "`n" +
           $T + 'procd_set_param env PATH="$PATH"' + "`n" +
           $T + 'procd_close_instance' + "`n" +
           $T + '# Once per boot: record (and if needed repair) what decides whether a Wi-Fi client gets an address.' + "`n" +
           $T + '# See opt/mu300/bin/mu300-lancheck - without it a boot that serves nobody looks identical to a good one.' + "`n" +
           $T + 'procd_open_instance lancheck' + "`n" +
           $T + 'procd_set_param command /opt/mu300/bin/mu300-lancheck' + "`n" +
           $T + 'procd_set_param env PATH="$PATH"' + "`n" +
           $T + 'procd_close_instance' + "`n" +
           '}'
Patch "$Repo\openwrt\overlay\etc\init.d\mu300-post" $oldLan $newLan 'mu300-post: run mu300-lancheck once per boot'

Write-Host ""
Write-Host "=== 6. teach tools/vendor-overlay.py to carry an overlay ==="
# Needed for the mirroring below to reach the device at all: the vendor tarball is built by this script,
# and it has to know how to pack a rootfs overlay (paths relative to the system root, executable bits kept).
$voFunc = @'
def add_overlay_tree(tar, src: Path, seen: set):
    """Pack a rootfs overlay: every path in src is relative to the system root (etc/init.d/..., opt/...).

    This is how a change to the OpenWrt image reaches a machine installed from a PREBUILT release. The
    release's rootfs tarball is downloaded as-is and openwrt/overlay/ is only read by openwrt/build-rootfs.sh
    when the image is built from source - so editing that tree alone has no effect on an install. The vendor
    overlay, however, is built here on the host and android-install.sh unpacks it OVER the system (after the
    rootfs), so what it carries wins.

    Modes: Windows cannot store them, and add_tree would write 0644 for every file - which strips the
    executable bit off an init script and leaves the boot broken. Paths that are executed on the device
    therefore get 0755 explicitly.
    """
    exe_dirs = ('etc/init.d/', 'etc/uci-defaults/', 'etc/hotplug.d/', 'etc/rc.d/',
                'opt/mu300/bin/', 'opt/mu300/busybox-bin/', 'lib/', 'usr/')
    for root, dirs, files in os.walk(src, followlinks=False):
        dirs.sort()
        rel_root = Path(root).relative_to(src)
        for name in dirs:
            arc = (rel_root / name).as_posix()
            if arc in seen:
                continue
            seen.add(arc)
            info = tarfile.TarInfo(arc)
            info.type, info.mode, info.uid, info.gid = tarfile.DIRTYPE, 0o755, 0, 0
            info.uname = info.gname = 'root'
            tar.addfile(info)
        for name in sorted(files):
            path = Path(root) / name
            arc = (rel_root / name).as_posix()
            if arc in seen:
                continue
            seen.add(arc)
            data = path.read_bytes()
            mode = 0o755 if arc.startswith(exe_dirs) else 0o644
            info = tarfile.TarInfo(arc)
            info.size, info.mode, info.uid, info.gid = len(data), mode, 0, 0
            info.uname = info.gname = 'root'
            tar.addfile(info, io.BytesIO(data))


def main():
'@
# the replacement must end with a newline: the anchor consumed the one that followed "def main():"
Patch "$Repo\tools\vendor-overlay.py" "def main():`n" ($voFunc.Trim() + "`n") 'vendor-overlay.py: add add_overlay_tree()'

$voOld = "            print(f'{a.out}: {n} modules for {krel}')" + "`n" + "    print(f'{a.out}: {len(seen)} entries')"
$voNew = "            print(f'{a.out}: {n} modules for {krel}')" + "`n" +
         "        # The fork's own changes to the OpenWrt image (see add_overlay_tree). Auto-detected next to this" + "`n" +
         "        # script so that no installer change is needed: openwrt/vendor-extra/ is populated by" + "`n" +
         "        # tools/apply-v50-patches.ps1, which mirrors every file it patches into that tree." + "`n" +
         "        extra = Path(__file__).resolve().parent.parent / 'openwrt' / 'vendor-extra'" + "`n" +
         "        if a.os.startswith('openwrt') and extra.is_dir():" + "`n" +
         "            n = len(seen)" + "`n" +
         "            add_overlay_tree(tar, extra, seen)" + "`n" +
         "            print(f'{a.out}: {len(seen) - n} entries from {extra}')" + "`n" +
         "    print(f'{a.out}: {len(seen)} entries')"
Patch "$Repo\tools\vendor-overlay.py" $voOld $voNew 'vendor-overlay.py: pack openwrt/vendor-extra/'

Write-Host ""
Write-Host "=== 7. mirror every patched OpenWrt file into the vendor overlay (list; runs at the end) ==="# The important half. A machine installed from a PREBUILT release downloads that release's rootfs tarball
# and never reads openwrt/overlay/ - so patches 3, 4 and 5 would silently do nothing. tools/vendor-overlay.py
# packs openwrt/vendor-extra/ into mu300-vendor-<os>.tar.gz, and android-install.sh unpacks that OVER the
# system, after the rootfs. Mirroring the patched files there is what makes them take effect.
$mirror = @(
    'etc\init.d\mu300-hw',
    'etc\init.d\mu300-post',
    'etc\hotplug.d\iface\10-mu300-usb',
    'etc\uci-defaults\90-mu300',
    'opt\mu300\bin\mu300-lancheck',
    # mu300-buttons lives in rootfs/overlay/, which build-rootfs.sh mounts at /in/opt-mu300 and copies
    # to /opt/mu300 - but a PREBUILT install never runs build-rootfs.sh, so this has to come through
    # vendor-extra as well or the V50's key keeps doing nothing on such a device.
    'opt\mu300\bin\mu300-buttons=rootfs\overlay\opt\mu300\bin\mu300-buttons',
    # apk's package feed. Overwrites the download root baked into the rootfs tarball, so a device
    # installed from a prebuilt release fetches packages from a mirror instead (see step 16).
    'etc\apk\repositories.d\distfeeds.list',
    # "dest=source" when the file does not live under openwrt/overlay/: the dashboard backend is a
    # package file (openwrt/luci-app-mu300/root/), so it is named explicitly here.
    'usr\libexec\unisoc-modem\dashboard-info=openwrt\luci-app-mu300\root\usr\libexec\unisoc-modem\dashboard-info',
    # the dashboard page itself. htdocs/ is copied to /www by openwrt/build-rootfs.sh, so a
    # prebuilt install needs its own copy of it or the page keeps running the unpatched script.
    'www\luci-static\resources\view\mu300\home.js=openwrt\luci-app-mu300\htdocs\luci-static\resources\view\mu300\home.js'
)
function Mirror-VendorExtras {
$dst = "$Repo\openwrt\vendor-extra"
foreach ($entry in $mirror) {
    $parts = $entry -split '=', 2
    $rel = $parts[0]
    $src = if ($parts.Count -eq 2) { "$Repo\$($parts[1])" } else { "$Repo\openwrt\overlay\$rel" }
    $out = Join-Path $dst $rel
    if (-not (Test-Path $src)) { Write-Host "  SKIP (missing): $rel"; continue }
    New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
    Copy-Item $src $out -Force
    Write-Host ("  mirrored: {0}" -f $rel)
}
}

Write-Host ""
Write-Host "=== 8. find the su that actually works (V50: Magisk's su is not on PATH) ==="
# On this device `su` is not on PATH at all: Magisk's root is only reachable through /debug_ramdisk/su, so the
# installer died with "su does not work on the device" even though root works. A plain `su` stays the first
# choice, so a device where that is fine is unaffected.
$suOld = @'
function SuDo($cmd) {
    (Quiet { adb shell "su -c '$cmd'" }) -join "`n" -replace "`r", ''
}
'@
$suNew = @'
# The binary used to run as root. Not every device has `su` on PATH (this V50: Magisk's root lives in
# /debug_ramdisk/su only), and the stock installer then reports "su does not work on the device" while
# root is in fact available. Resolved below, after the device is pinned; 'su' stays the first choice.
$script:Su = 'su'
function SuDo($cmd) {
    (Quiet { adb shell "$script:Su -c '$cmd'" }) -join "`n" -replace "`r", ''
}
'@
# strip only the newline PowerShell puts after @' and the trailing whitespace: Trim() would eat the leading
# indentation of the first line and the anchor would never match
$suOld = $suOld -replace "^[\r\n]+", '' -replace "[\r\n]+$", ''
$suNew = $suNew -replace "^[\r\n]+", '' -replace "[\r\n]+$", ''
Patch "$Repo\install.ps1" $suOld $suNew 'install.ps1: SuDo uses the resolved su'

Patch "$Repo\install.ps1" "& adb shell `"su -c '`$cmd > `$dev'`" | Out-Null" "& adb shell `"`$script:Su -c '`$cmd > `$dev'`" | Out-Null" 'install.ps1: SuDoToFile uses the resolved su'
Patch "$Repo\install.ps1" "& adb shell `"su -c 'rm -f `$dev'`" | Out-Null" "& adb shell `"`$script:Su -c 'rm -f `$dev'`" | Out-Null" 'install.ps1: SuDoToFile cleanup uses the resolved su'

$suCheck = "if ((SuDo 'id -u') -ne '0') { Die (T 'su does not work on the device') }"
$suProbe = @'
# Resolve root before anything depends on it: try the plain name, then the places Magisk keeps it when it is
# not on PATH. Reported, so the log says which one was used.
if (((Quiet { adb shell "$script:Su -c 'id -u'" }) -join ' ').Trim() -ne '0') {
    foreach ($cand in @('/debug_ramdisk/su', '/sbin/su', '/system/xbin/su', '/system/bin/su')) {
        if (((Quiet { adb shell "$cand -c 'id -u'" }) -join ' ').Trim() -eq '0') {
            $script:Su = $cand
            Write-Host ('  ' + (T 'root through {1}' $cand))
            break
        }
    }
}
if ((SuDo 'id -u') -ne '0') { Die (T 'su does not work on the device') }
'@
Patch "$Repo\install.ps1" $suCheck ($suProbe.Trim()) 'install.ps1: probe for a working su'

Write-Host ""
Write-Host "=== 10. put the LAN bridge itself into the lan firewall zone ==="
# This is what stopped a client getting an address, and nothing on the device ever said so.
#
# fw4 works out which interfaces a zone covers from the PORTS of the network's bridge device. br-lan is
# declared bridge_empty (the wired LAN has to come up before a member exists - see the K-code above in the
# same file) and wlan0 only joins it later, when netifd brings the AP up. So when fw4 rendered its ruleset
# the lan zone owned no interface at all: `nft list chain inet fw4 input` contained no jump for br-lan,
# its policy is drop, and every packet a Wi-Fi client sent was discarded.
#
# The failure looks healthy from the inside. The hotspot is up, wlan0 is a port of br-lan, br-lan holds
# 192.168.77.1/24, dnsmasq listens on 0.0.0.0:67 with a correct dhcp-range, dropbear and uhttpd are
# listening on 22 and 80 - and /etc/config/firewall says `input='ACCEPT'` for the lan zone, because the
# OPTION is set. Only the rendered ruleset shows that the zone has nothing to accept. A client associates,
# sends a DISCOVER, and it never arrives: the PC reports "unable to contact your DHCP server" with no
# cause, and dnsmasq's own log shows no DISCOVER ever reaching it.
#
# Naming the bridge in the zone costs nothing and cannot be undone by a port appearing later.
$defaultsOld = $T + "uci set firewall.`$early.forward='REJECT'" + "`n" + "fi" + "`n"
$defaultsNew = $T + "uci set firewall.`$early.forward='REJECT'" + "`n" + "fi" + "`n" + (@'
# K28 (V50, 2026-10-10): the lan zone has to own the bridge itself, not only its ports.
#
# fw4 derives a zone's interfaces from the ports of the network's bridge device. br-lan is declared
# bridge_empty, and wlan0 only joins it when netifd brings the AP up - after fw4 has rendered the
# ruleset. The lan zone then owns nothing: no jump for br-lan in the input chain, policy drop, and
# every packet a client sends is discarded. Nothing reports it - /etc/config/firewall says
# input='ACCEPT' either way, the AP is up and dnsmasq is listening - so a client that associates simply
# never gets a lease. Naming the bridge costs nothing and a later port cannot undo it.
lan_dev=$(uci -q get network.lan.device)
if [ -n "$lan_dev" ]; then
	for z in $(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)\.name='lan'$/\1/p"); do
		uci -q get "firewall.$z.device" | grep -qx "$lan_dev" || uci add_list "firewall.$z.device=$lan_dev"
	done
fi
'@) -replace "`r`n", "`n" -replace '(?m)^    ', "`t"
# the here-string carries no trailing newline of its own: without this the next block's first line
# ends up appended to the closing "fi"
$defaultsNew = $defaultsNew.TrimEnd("`n") + "`n"
Patch "$Repo\openwrt\overlay\etc\uci-defaults\90-mu300" $defaultsOld $defaultsNew '90-mu300: the lan zone owns br-lan'

Write-Host ""
Write-Host "=== 11. take the early server's address off rndis0 as well ==="
# The hook already has this cleanup (K9), but it runs in the wrong order for rndis0.
#
# Its loop only looks at netdevs that are ALREADY ports of br-lan, and rndis0 is put into br-lan a few
# lines LATER in the same script. So on a system whose gadget is RNDIS (usb0 does not exist), rndis0
# becomes a bridge port still holding the address preinit's early DHCP server gave it - and the LAN
# subnet then has two equal routes:
#
#   192.168.77.0/24 dev rndis0 proto kernel scope link src 192.168.77.1
#   192.168.77.0/24 dev br-lan proto kernel scope link src 192.168.77.1
#
# The first one wins, so replies leave through the USB gadget. A Wi-Fi client can associate, get a
# DHCP lease (that traffic is answered over the gadget), and then not even ping br-lan: its ICMP
# replies go out of rndis0. Measured on the V50, 2026-10-10: PC on Wi-Fi 192.168.77.232, 100% loss to
# 192.168.77.1, while `ip addr del 192.168.77.1/24 dev rndis0` fixed it instantly.
#
# Re-running the same cleanup after the enslavement costs nothing and cannot misfire: it only ever
# removes an address equal to the bridge's own.
$hook = "$Repo\openwrt\overlay\etc\hotplug.d\iface\10-mu300-usb"
$hookOld = $T + "ip link set rndis0 up 2>/dev/null" + "`n" + "fi" + "`n"
$hookNew = $T + "ip link set rndis0 up 2>/dev/null" + "`n" + "fi" + "`n" + (@'
# ... and the same address check once more, now that rndis0 is a port.
#
# The loop above only looks at netdevs that are already ports of br-lan, and rndis0 was put into
# br-lan on the line before this one - so on a system whose gadget is RNDIS it was never checked.
# Left holding the early server's address, the LAN subnet gets two equal routes and replies leave
# through rndis0: a Wi-Fi client that has associated cannot even ping br-lan. (V50, 2026-10-10)
if [ -n "$bridge_ip" ]; then
@@for nic in usb0 rndis0; do
@@@@ip -o link show dev "$nic" 2>/dev/null | grep -q 'master br-lan' || continue
@@@@nic_ip=$(ip -4 -o addr show dev "$nic" 2>/dev/null |
@@@@@@awk -v a="${bridge_ip%/*}" '{ split($4, p, "/"); if (p[1] == a) { print $4; exit } }')
@@@@[ -n "$nic_ip" ] || continue
@@@@ip addr del "$nic_ip" dev "$nic" 2>/dev/null || true
@@done
fi
'@) -replace "`r`n", "`n"
# @@ marks a tab: written out with spaces here for readability, turned into real tabs below
$hookNew = $hookNew.TrimEnd("`n") + "`n"
$hookNew = $hookNew.Replace('@@@@', "`t`t").Replace('@@', "`t")
Patch $hook $hookOld $hookNew '10-mu300-usb: strip the early address from rndis0 too'

Write-Host ""
Write-Host "=== 12. leave fw4's software flow offload OFF (or the firewall can never re-render) ==="
# The fourth member of the same family, and the one that looks least like a firewall problem.
#
# The WAN here is a custom netifd proto (mu300cell) whose l3_device (sipa_eth0) only appears once the
# modem has dialled - well after fw4 rendered its ruleset at boot. fw4 builds a zone's rules from its
# interfaces' devices, so `accept_to_wan` comes out EMPTY: LAN -> WAN forwarding has no accept rule,
# and the forward chain falls through to handle_reject, which RSTs every TCP connection. The device's
# own DNS and traffic keep working, so it presents as "the hotspot has no DNS".
#
# OpenWrt already has the repair: /etc/hotplug.d/iface/20-firewall runs `fw4 -q reload` on wan ifup.
# It silently fails, because flow offloading is on: `flowtable ft` cannot be replaced while flows are
# in it, so nft aborts the whole transaction with "Resource busy" - and `-q` swallows the message.
# `fw4 reload`/`/etc/init.d/firewall reload` fail the same way from a shell; only stop+start works.
#
# With offloading off there is no flowtable, the reload succeeds, and the existing hotplug heals the
# zone by itself on every WAN up - including after a flap. Verified on the V50, 2026-10-10: with
# offloading on, every forwarded TCP connection was RST (curl 000) and accept_to_wan was empty; with
# it off, the hook logs "Reloading firewall due to ifup of wan ()" and HTTPS returns 200.
# Cost: no software offload for forwarded flows. SIPA and SC2355 have no hardware offload anyway, and
# a router whose firewall cannot be reloaded is worse than one without flow offload.
$flowOld = $T + "uci -q set firewall.@defaults[0].flow_offloading='1'" + "`n" +
           $T + "uci -q set firewall.@defaults[0].flow_offloading_hw='0'"
$flowNew = $T + "# Flow offload stays OFF (V50, 2026-10-10)." + "`n" +
           $T + "# It was on, and it broke forwarding: the WAN's device appears only after the modem" + "`n" +
           $T + "# dials, so fw4 renders accept_to_wan empty at boot, and the hotplug that would fix it" + "`n" +
           $T + "# (hotplug.d/iface/20-firewall, which runs 'fw4 -q reload') cannot: replacing the" + "`n" +
           $T + "# flowtable while flows are in it fails with Resource busy, and -q hides the error." + "`n" +
           $T + "# Every forwarded TCP was then RST by handle_reject, while the router's own DNS kept" + "`n" +
           $T + "# working - so it reads as 'the hotspot has no DNS'. See docs/04-WiFi与DHCP根因分析.md." + "`n" +
           $T + "# SIPA and SC2355 have no hardware offload anyway, so little is lost." + "`n" +
           $T + "uci -q set firewall.@defaults[0].flow_offloading='0'" + "`n" +
           $T + "uci -q set firewall.@defaults[0].flow_offloading_hw='0'"
Patch "$Repo\openwrt\overlay\etc\uci-defaults\90-mu300" $flowOld $flowNew '90-mu300: keep flow offloading off'

Write-Host ""
Write-Host "=== 13. board.json: name the LAN device this board actually has ==="
# /etc/board.json ships from the armsr/armv8 generic target and declares the LAN device as "eth0".
# This board has no eth0 at all - its LAN is a bridge carrying the USB gadget and the AP. LuCI's
# status page reads exactly this field (`luci getBuiltinEthernetPorts`, rendered by
# view/status/include/29_ports.js), so it listed a port that can never come up and reported it as
# "disconnected" for ever, next to the real LAN.
#
# config_generate writes board.json only when the image is built, so the stale value survives every
# install AND every update - nothing else would ever correct it. The UCI side is already right
# (network.lan.device is the bridge), so the fix is to copy that value across.
#
# Measured on the V50, 2026-10-10:
#   before: luci getBuiltinEthernetPorts -> [{"role":"lan","device":"eth0"}]
#   after : luci getBuiltinEthernetPorts -> [{"role":"lan","device":"br-lan"}]   (up, carrier: true)
$boardOld = "# the wired LAN does not wait for a member that is not there yet (Wi-Fi, a gadget netdev)" + "`n" +
            "[ -z `"`$dev`" ] || uci set network.`$dev.bridge_empty='1'"
$boardNew = $boardOld + "`n" + (@'
# board.json names the LAN device "eth0" - a leftover from the armsr target, on a board that has no
# eth0. LuCI's status page reads it as the builtin ethernet ports, so it listed a port that can never
# come up and reported it as disconnected for ever. config_generate writes this file only when the
# image is built, so the stale value survives every install and every update; nothing else fixes it.
# The UCI side is already right, so copy that across. (V50, 2026-10-10)
mu300_board_dev=$(uci -q get network.lan.device)
if [ -n "$mu300_board_dev" ] && [ -f /etc/board.json ]; then
	sed -i "s/\"device\": \"eth0\"/\"device\": \"$mu300_board_dev\"/" /etc/board.json 2>/dev/null || true
fi
'@) -replace "`r`n", "`n"
$boardNew = $boardNew.TrimEnd("`n")
Patch "$Repo\openwrt\overlay\etc\uci-defaults\90-mu300" $boardOld $boardNew '90-mu300: board.json names the real LAN device'

Write-Host ""
Write-Host "=== 14. the dashboard's USB indicator must find the gadget, whatever it is called ==="
# The status dashboard (admin/home) shows a USB network indicator by reading status.net.usb0.up:
#
#   M.set('wusb', (i.net && i.net.usb0 && i.net.usb0.up) ? _('Connected') : _('Disconnected'));
#
# and dashboard-info fills that field from net_obj on a device name it picks like this:
#
#   USB_DEVICE=$(safe_iface "$(cfg usb_device)" usb0)
#
# With no uci setting that is the literal "usb0" - but the gadget netdev is usb0 only in NCM/ECM
# mode. In RNDIS mode boot/init builds rndis0 (and rndis0 is what joins br-lan), so net_obj found no
# such device, returned null, and the dashboard reported the USB network as "Disconnected" for ever
# while the link was up and carrying traffic. Same root cause as the lan-zone and rndis0-address
# bugs: code that names usb0 where the gadget may be rndis0.
#
# The JSON key stays "usb0" - that is what the page reads - only the device it is measured from
# becomes whichever gadget netdev exists.
$dashFile = "$Repo\openwrt\luci-app-mu300\root\usr\libexec\unisoc-modem\dashboard-info"
$dashOld = 'USB_DEVICE=$(safe_iface "$(cfg usb_device)" usb0)'
$dashNew = $dashOld + "`n" + (@'
# The gadget netdev is usb0 in NCM/ECM mode and rndis0 in RNDIS mode (see boot/init
# setup_usb_gadget). Neither the uci option nor the fallback above names that, so with RNDIS
# selected this read a device that does not exist, net_obj returned null, and the status
# dashboard reported the USB network as "Disconnected" while the link was up. (V50, 2026-10-10)
if [ ! -d "/sys/class/net/$USB_DEVICE" ]; then
	for _c in usb0 rndis0; do
		[ -d "/sys/class/net/$_c" ] && { USB_DEVICE=$_c; break; }
	done
fi
'@).TrimEnd("`n") -replace "`r`n", "`n"
Patch $dashFile $dashOld $dashNew 'dashboard-info: find the USB gadget netdev by name, not by usb0'

Write-Host ""
Write-Host "=== 15. the dashboard's DNS row: a sed pattern that can never match ==="
# The status dashboard shows the WAN resolvers on one row (home.js: M.set('dns', w.dns || '--')),
# and dashboard-info filled that field with a line-oriented sed:
#
#   jarr_dns() { printf '%s' "$1" | sed -n 's/.*"dns-server": *\[\([^]]*\)\].*/\1/p' | tr -d '"'; }
#
# Two independent reasons that can never produce a value, both confirmed on the V50 where the WAN
# had two resolvers the whole time and the page said "DNS --":
#
#   1. `ubus call network.interface.wan status` pretty-prints over several lines:
#
#        "dns-server": [
#            "218.104.111.122",
#            "218.106.127.114"
#        ],
#
#      so the `[` and the `]` are on different lines and no single line matches. jval(), right above,
#      survives this only because the fields it reads ("up", "uptime", "proto", "address") are
#      scalars that ubus keeps on one line.
#
#   2. The leading `.*` is greedy, so even on one line it would settle on the LAST "dns-server" in
#      the document - the empty array that "inactive" carries, not the real one. jarr_dns was the
#      only reader in the file with this shape, which is why nothing else broke.
#
# jsonfilter is the tool for this and ships with the image (luci-base depends on it, and this
# script only ever runs behind LuCI). The field stays a plain string: servers space separated, and
# home.js breaks them onto separate lines the way the address above them is laid out.
$dashDnsOld = 'jarr_dns() { printf ''%s'' "$1" | sed -n ''s/.*"dns-server": *\[\([^]]*\)\].*/\1/p'' | tr -d ''"'' ; }'
$dashDnsNew = @'
# jsonfilter, not sed. Two independent reasons, both live on this device (V50, 2026-10-10):
#   * `ubus call ... status` pretty-prints across several lines, so `"dns-server": [ ... ]` never
#     matches inside ONE line and a line-oriented sed finds nothing at all - jarr_dns returned
#     the empty string and the dashboard said "DNS --";
#   * the leading `.*` in such a pattern is greedy, so even on a single line it would settle on
#     the EMPTY "dns-server" array that "inactive" carries: the last one in the document, not the
#     real one.
# The interface had two servers configured the whole time. The field is a plain string here, so
# the servers are space separated and home.js breaks them onto separate lines.
jarr_dns() { t3 jsonfilter -s "$1" -e '@["dns-server"][*]' 2>/dev/null | tr '\n' ' ' | sed 's/  *$//'; }
'@
$dashDnsNew = $dashDnsNew.TrimEnd("`n") -replace "`r`n", "`n"
Patch $dashFile $dashDnsOld $dashDnsNew 'dashboard-info: read dns-server with jsonfilter'

# ...and the page has to be able to show more than one of them. M.set() assigns textContent, so the
# servers arrive as one line unless the row is filled the same way as the address above it.
$homeFile = "$Repo\openwrt\luci-app-mu300\htdocs\luci-static\resources\view\mu300\home.js"
$homeDnsOld = "`t`tM.set('dns', w.dns || '--');"
$homeDnsNew = (@'
		/* one resolver per line, laid out like the address above it. M.set() writes textContent and
		   cannot do that, and the backend sends the servers space separated (see jarr_dns). */
		var dnsList = (w.dns ? String(w.dns).split(/\s+/) : []).filter(function(s) { return s; });
		var dnsEl = M.v('dns');
		if (dnsEl) dnsEl.innerHTML = dnsList.length ? dnsList.map(M.esc).join('<br>') : '--';
'@).TrimEnd("`n") -replace "`r`n", "`n"
Patch $homeFile $homeDnsOld $homeDnsNew 'home.js: one resolver per line'

Write-Host ""
Write-Host "=== 16. what a person reads: hostname, time zone, and the wireless country ==="
# LAYER 3 of the V50 identity work, and deliberately the ONLY thing renamed anywhere.
#
# The question this settles: should the whole project be re-badged from MU300/F50 to V50/MU3351?
# No. The names inside are not labels, they are the ABI and the recovery path:
#   * /opt/mu300, /etc/mu300        - absolute paths the Android-side installer also uses
#   * mu300-* commands (46 scripts) - called by name from /etc/init.d, inittab, hotplug, cron
#   * MU300_* keys                  - the upstream's own settings contract
#   * mu300cell netifd proto        - in UCI as network.wan.proto, so renaming it breaks an
#                                     already-installed device's config; miss one of the three
#                                     files and the WAN never comes up
#   * mu300dash ubus object         - LuCI front end and rpcd back end must change together
#   * the mu300root ext4 label      - android-mount-mu300root.sh VALIDATES this label before it
#                                     mounts, and that script is the only way to repair the Linux
#                                     partition from Android. Rename it and the last-resort
#                                     recovery path refuses to work.
# On top of that, V50 is the same board as the F50 (ums9620_2h10_feima), so DEVICE=f50 is the
# correct and tested path - layer 1. Renaming buys no function and guarantees permanent drift from
# upstream. See the project README, "Naming and device identity".
#
# What IS worth renaming is what a person reads. The hostname is the whole of it: it shows up in
# the shell prompt and the page title. It has no functional dependents (mu300-toolkit reads it only
# to display it, and offers to change it), and OpenWrt's own uci call sets it, so this is one value
# with a one-line rollback:  uci set system.@system[0].hostname='mu300'; uci commit system
#
# The 2 user-visible "F50 has no battery" strings in view/mu300/device.js are NOT touched: changing
# an English msgid orphans its zh-cn/tr entry in the compiled .lmo catalogs, which would put mixed
# languages on a page that is otherwise fully translated. That is worse than the status quo, and the
# statement itself is true of the V50 as well.
# The rest of what a person reads, and the one setting that decides whether the hotspot can exist at
# all. Rewritten by regex rather than with Patch() because this patch used to write 'V50' as the
# hostname: a plain find/replace against the upstream value would MISS on a tree this patch has
# already touched, which is exactly the case a re-run has to handle.
#
# timezone: upstream ships Europe/Istanbul (the project's origin). Asia/Shanghai is UTC+8 with no DST,
# so '<+03>-3' (a fixed offset) becomes 'CST-8'.
#
# country: with no country set, cfg80211 stays on the world domain ('country 00'), and on that domain
# EVERY 5 GHz channel carries NO-IR - no initiating radiation - so hostapd cannot start an AP there:
#
#   Frequency 5180 (primary) not allowed for AP mode, flags: 0x40853 NO-IR
#   Could not select hw_mode and channel. (-3)
#   wlan0: interface state COUNTRY_UPDATE->DISABLED / AP-DISABLED
#
# and the device comes up with no hotspot and no DHCP server, with nothing on the device looking wrong.
# That is what the V50 did on the mainline kernel until this line existed.
#
# Which country: the one that allows the most power. Measured with iw reg get on this device:
#
#   2.4 GHz    US 30 dBm   |  BO 20  |  CN 20  |  TR/DE 20   <- US is double the next best
#   5 GHz low  US 23 dBm (no NO-IR, so an AP is allowed)  |  BO/CN/JP 20-23 with restrictions
#   5 GHz high US 30 dBm   |  BO 30  |  CN 33 (5.8 GHz band only)
#
# US it is: it caps 2.4 GHz - the band that works in every regulatory state - at 30 dBm, and unlike BO
# it allows an AP on the low 5 GHz channels as well. The hardware caps what it can actually radiate;
# this only removes the regulatory ceiling. Changeable at any time:
#   uci set wireless.radio0.country='DE'; uci commit wireless; wifi reload
#
# The database that gives these numbers has to be loaded for the country to mean anything: cfg80211
# asks for regulatory.db before the rootfs is mounted and that first load always fails
# ("cfg80211: failed to load regulatory.db"). mu300-lancheck feeds it again every boot - see step 5.
$identityFile = "$Repo\openwrt\overlay\etc\uci-defaults\90-mu300"
$identityText = [IO.File]::ReadAllText($identityFile) -replace "`r`n", "`n"
$identityBefore = $identityText
$identityText = [regex]::Replace($identityText, "set system\.@system\[0\]\.hostname='(?:mu300|V50)'", "set system.@system[0].hostname='ZTE-V50'")
$identityText = [regex]::Replace($identityText, "set system\.@system\[0\]\.zonename='[^']*'", "set system.@system[0].zonename='Asia/Shanghai'")
$identityText = [regex]::Replace($identityText, "set system\.@system\[0\]\.timezone='[^']*'", "set system.@system[0].timezone='CST-8'")
if (-not $identityText.Contains("set wireless.radio0.country='US'")) {
    $tzLine = "set system.@system[0].timezone='CST-8'"
    $countryBlock = @'
# The regulatory domain decides which channels may radiate at all (see the note above step 16):
# with none set, cfg80211 stays on the world domain, every 5 GHz channel is NO-IR, and hostapd refuses
# to start the AP - the device boots with no hotspot and says nothing. US allows the most power of the
# countries measured here on 2.4 GHz (30 dBm; BO and CN allow 20) and permits an AP on the low 5 GHz
# channels too.  Change it with:  uci set wireless.radio0.country='DE'; uci commit wireless; wifi reload
set wireless.radio0.country='US'
'@
    $countryBlock = $countryBlock.TrimEnd("`n") -replace "`r`n", "`n"
    $identityText = $identityText.Replace($tzLine, $tzLine + "`n" + $countryBlock)
}
if ($identityText -ne $identityBefore) {
    [IO.File]::WriteAllText($identityFile, $identityText, (New-Object Text.UTF8Encoding($false)))
    Write-Host "  patched: 90-mu300 hostname/timezone/country"
    $patched++
} else {
    Write-Host "  already: 90-mu300 hostname/timezone/country"
}

Write-Host ""
Write-Host "=== 17. point apk at a mirror that actually carries this release ==="
# OpenWrt 25.12 uses apk, and /etc/apk/repositories.d/distfeeds.list ships pointing at
# downloads.openwrt.org. This device reaches the internet over 4G, where that host is slow -
# measured here: the same 8 indexes take 18 s against upstream and 8 s against the Tsinghua
# mirror, and `apk update` takes 7 s versus 4 s.
#
# The mirror is not a free choice, and the obvious one is the wrong one:
# mirrors.aliyun.com/openwrt does NOT carry 25.12.5 (its releases/ tree stops at 25.12.0-rc2,
# the release this image is built from - openwrt/build-rootfs.sh, MU300_WRT_VER). All 8 index
# URLs 404 there, `apk update` exits 8, and only 226 packages stay visible instead of 11178.
# Nothing else on the device reports a problem: the mirror is "configured", apk runs, and the
# failure only shows up at the moment something is actually installed.
#
# Conversely repo.huaweicloud.com/openwrt answers 200 with an HTML page for paths that do not
# exist, so a HEAD probe calls it available. Do not add it on the strength of a 200.
#
# Two copies of this file matter, and step 7 mirrors the first into the second:
#   openwrt/overlay/etc/apk/repositories.d/distfeeds.list  - for images built from this tree
#                                                             (build-rootfs.sh: cp -a /in/overlay/. $R/)
#   openwrt/vendor-extra/etc/apk/...                      - for a PREBUILT release install,
#                                                             which unpacks the vendor tarball
#                                                             over the system instead
$feed = @'
# apk package feeds - pinned to the Tsinghua (TUNA) mirror of downloads.openwrt.org.
#
# This file REPLACES the one baked into the rootfs tarball: openwrt/build-rootfs.sh does
# `cp -a /in/overlay/. $R/` after unpacking the image, so this copy is the one that survives.
# A device installed from a PREBUILT release never reads openwrt/overlay/, which is why step 7
# of apply-v50-patches.ps1 mirrors this file into openwrt/vendor-extra/ as well.
#
# Measured on the V50 over 4G (2026-10-10), the same 8 indexes, same device, same minute:
#   downloads.openwrt.org            8/8 reachable, 1.54 MB in 18 s, apk update 7 s
#   mirrors.tuna.tsinghua.edu.cn     8/8 reachable, 1.54 MB in  8 s, apk update 4 s
#   mirrors.aliyun.com/openwrt       0/8 reachable (all 404),         apk update FAILS (rc=8)
# The TUNA copy is byte-identical to the official index (sha256 of
# packages/aarch64_generic/base/packages.adb matches downloads.openwrt.org exactly), and
# `apk update` reports the same 11178 packages from either.
#
# WHY NOT ALIYUN, since mirrors.aliyun.com/openwrt is the obvious first guess:
# that mirror's releases/ tree stops at 25.12.0-rc2 and does not carry 25.12.5, the release
# this image is built from (openwrt/build-rootfs.sh: MU300_WRT_VER defaults to 25.12.5).
# Every one of the 8 index URLs 404s there, so `apk update` exits 8 and only 226 packages
# remain visible instead of 11178 - the device looks like it has a working package manager
# right up until something is actually installed. Verified on the device, not inferred.
#
# Other mirrors measured to carry the same 8 indexes with identical bytes (all 8/8, all
# 20/20 on repeated requests), should TUNA ever be unreachable:
#   https://mirrors.ustc.edu.cn/openwrt/
#   https://mirror.sjtu.edu.cn/openwrt/
#   https://mirror.nju.edu.cn/openwrt/
#   https://mirrors.bfsu.edu.cn/openwrt/
#   https://mirrors.cloud.tencent.com/openwrt/
# Do NOT use https://repo.huaweicloud.com/openwrt/ : it answers 200 with an HTML page for
# paths that do not exist, so a HEAD probe reports "available" for a feed that is not there.
#
# To go back to upstream, replace the host below with https://downloads.openwrt.org - the
# paths do not change. The kernel version in the kmods path (6.12.94-1-ba5ca7f...) is part
# of the path and must match the running kernel: an index for another kernel is not a
# fallback, it is a wrong answer.
#
# Contents are comments and 8 URLs; this file is read by apk, not by a shell.

https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/25.12.5/targets/armsr/armv8/packages/packages.adb
https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/25.12.5/packages/aarch64_generic/base/packages.adb
https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/25.12.5/targets/armsr/armv8/kmods/6.12.94-1-ba5ca7f3e73618aeece9cc1c14e512c2/packages.adb
https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/25.12.5/packages/aarch64_generic/luci/packages.adb
https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/25.12.5/packages/aarch64_generic/packages/packages.adb
https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/25.12.5/packages/aarch64_generic/routing/packages.adb
https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/25.12.5/packages/aarch64_generic/telephony/packages.adb
https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/25.12.5/packages/aarch64_generic/video/packages.adb
'@
$feedPath = "$Repo\openwrt\overlay\etc\apk\repositories.d\distfeeds.list"
if ((Test-Path $feedPath) -and ([IO.File]::ReadAllText($feedPath)).Contains('mirrors.tuna.tsinghua.edu.cn')) {
    Write-Host "  already: apk feed -> mirrors.tuna.tsinghua.edu.cn"
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path $feedPath) | Out-Null
    # LF and no BOM, for the same reason every other file here is: apk reads it, but the encoding
    # gate below has to be able to tell a clean file from a corrupted one, and this whole tree
    # ships as a patch that git apply takes byte for byte.
    [IO.File]::WriteAllText($feedPath, (($feed -replace "`r`n", "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    Write-Host "  wrote: openwrt/overlay/etc/apk/repositories.d/distfeeds.list"
    $patched++
}

# Validate whatever ended up in the file, not just the content this step would have written: a
# hand-edited feed that silently lost a line still leaves the device without a package manager.
$feedText = [IO.File]::ReadAllText($feedPath)
$urls = @($feedText -split "`n" | Where-Object { $_ -match '^\s*https://' })
$hosts = @($urls | ForEach-Object { ([uri]$_.Trim()).Host } | Sort-Object -Unique)
if ($urls.Count -ne 8) { throw "apk feed: expected 8 index URLs, found $($urls.Count) in $feedPath" }
if ($hosts.Count -ne 1) { throw "apk feed: all 8 URLs must share one mirror host, found: $($hosts -join ', ')" }
if ($hosts[0] -eq 'repo.huaweicloud.com') {
    throw "apk feed: repo.huaweicloud.com answers 200 with an HTML page for missing paths - it will pass a HEAD probe and still be unusable"
}
Write-Host "  ok: 8 index URLs, mirror $($hosts[0])"

Write-Host ""
Write-Host "=== 17b. mirror the patched files into the vendor overlay (defined in step 7) ==="
# It has to run HERE, after every content edit above, and it used to run at step 7. Steps 10-16 edit
# openwrt/overlay/ and openwrt/luci-app-mu300/ AFTER that point, so a single clean run copied the
# pre-edit files and left the vendor tarball one run behind: a device installed from a prebuilt
# release - which unpacks vendor-extra and never reads openwrt/overlay/ - got the previous version of
# 90-mu300, 10-mu300-usb and dashboard-info, while the tree here looked fully patched. Repeated runs
# hid it, because each run copied the previous run's finished files.
Mirror-VendorExtras

Write-Host ""
Write-Host "=== 18. gate: nothing we ship may be UTF-16, BOM'd or CRLF ==="
# Everything in openwrt/vendor-extra/ is unpacked straight onto the running system's / and executed there,
# and openwrt/overlay/ is unpacked the same way by openwrt/build-rootfs.sh. A file in either tree that is not
# plain UTF-8 with LF endings fails in the worst possible way: the kernel cannot read the shebang, so
# /etc/init.d/<script> is silently skipped. There is no error on the console and nothing in the logs - the
# only symptom is the hardware that script was supposed to bring up never coming up.
#
# This is not hypothetical. Upstream ships openwrt/overlay/etc/init.d/mu300-hw as UTF-16LE, which is how the
# V50 spent a boot with no Wi-Fi at all: mu300-hw never ran, so wcn_bsp/sprd_wlan_combo were never insmod'ed,
# wlan0 never existed, and lancheck dutifully recorded "wlan0=" empty while dropbear answered on port 22.
# Fail here, where the file can still be fixed, instead of on the device.
$bad = @()
foreach ($tree in @("$Repo\openwrt\vendor-extra", "$Repo\openwrt\overlay", "$Repo\openwrt\luci-app-mu300", "$Repo\rootfs\overlay", "$Repo\boot")) {
    if (-not (Test-Path $tree)) { continue }
    Get-ChildItem -Recurse -File -Path "$tree\*" | Where-Object {
        $_.Length -gt 3 -and $_.Length -lt 2MB -and $_.Extension -notmatch '^\.(ko|img|bin|png|jpg|jpeg|gz|xz|bz2|zip|tar|so|elf|o|pyc|woff2?|ttf|pdf|deb)$'
    } | ForEach-Object {
        $b = [IO.File]::ReadAllBytes($_.FullName)
        $why = @()
        if     ($b[0] -eq 0xFF -and $b[1] -eq 0xFE) { $why += 'UTF-16LE' }
        elseif ($b[0] -eq 0xFE -and $b[1] -eq 0xFF) { $why += 'UTF-16BE' }
        elseif ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $why += 'UTF-8 BOM' }
        if (-not $why) {
            for ($i = 0; $i -lt [Math]::Min(512, $b.Length); $i++) {
                if ($b[$i] -eq 0) { $why += 'NUL in the first 512 bytes'; break }
            }
        }
        if (-not $why -and [Text.Encoding]::ASCII.GetString($b) -match "`r`n") { $why += 'CRLF' }
        if ($why) { $bad += ('  ' + $_.FullName.Substring($Repo.Length + 1) + '  ->  ' + ($why -join ', ')) }
    }
}
if ($bad.Count) {
    Write-Host "  FAIL: $($bad.Count) file(s) cannot run on the device as they stand:"
    $bad | ForEach-Object { Write-Host $_ }
    throw 'encoding gate: fix the files above (re-encode as UTF-8 without BOM and LF) and run this again'
}
Write-Host '  ok: every file that ships to the device is plain UTF-8 with LF endings'

Write-Host ""
if ($patched) { Write-Host "$patched patch(es) applied." }
else { Write-Host "nothing to do - all patches already present." }

Write-Host ""
Write-Host "next:"
Write-Host "  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Lang zh -NoSelfUpdate -Answers <file>"
Write-Host "  (do NOT set MU300_USBNET: see step 2 - it changes the boot image in a way that hides the Linux"
Write-Host "   install from Android, and on this device it never took effect anyway)"
