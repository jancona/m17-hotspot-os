#!/bin/sh
# unit.sh - tests for the m17-hotspot-os shell libraries and tools
# Runs anywhere with a POSIX shell and busybox/coreutils (CI runs it in an
# Alpine container). Everything works on temporary files; nothing on the
# host is changed.
#
# Usage: tests/unit.sh

set -u

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$REPO_DIR/overlay/usr/local/lib/m17os"
BIN="$REPO_DIR/overlay/usr/local/bin"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# Results go to files so checks inside subshells count too
: > "$T/pass"
: > "$T/fail"
ok()   { echo . >> "$T/pass"; }
fail() { echo . >> "$T/fail"; echo "FAIL: $*"; }
check() { # check DESCRIPTION EXPECTED ACTUAL
	if [ "$2" = "$3" ]; then ok; else fail "$1: expected '$2', got '$3'"; fi
}

# ── overlay: executables must be executable ──────────────────────────
for f in "$REPO_DIR"/overlay/etc/init.d/* "$REPO_DIR"/overlay/usr/local/bin/* \
	"$REPO_DIR"/overlay/usr/local/libexec/m17os/* "$REPO_DIR"/overlay/etc/periodic/*/* \
	"$REPO_DIR"/overlay/etc/m17os/health.d/* "$REPO_DIR"/scripts/*.sh; do
	[ -x "$f" ] && ok || fail "not executable: ${f#"$REPO_DIR"/}"
done

# ── version.sh ───────────────────────────────────────────────────────
. "$LIB/version.sh"
vt() { if version_gt "$1" "$2"; then echo yes; else echo no; fi; }
check "newer day"       yes "$(vt 2026.11.18.1 2026.11.17.3)"
check "newer release"   yes "$(vt 2026.11.17.10 2026.11.17.9)"
check "same"            no  "$(vt 2026.11.17.1 2026.11.17.1)"
check "older"           no  "$(vt 2026.11.16.1 2026.11.17.1)"
check "extra field"     yes "$(vt 2026.11.17.1 2026.11.17)"
check "garbage is zero" no  "$(vt abc 2026.1.1.1)"

# ── bootslot.sh ──────────────────────────────────────────────────────
FW="$T/fw"
mkdir -p "$FW/overlays"
echo "console=serial0,115200 console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 rootwait" > "$FW/cmdline.txt"
: > "$FW/kernel8.img"
: > "$FW/kernel_2712.img"
: > "$FW/bcm2710-rpi-zero-2-w.dtb"
: > "$FW/overlays/miniuart-bt.dtbo"
cp "$REPO_DIR/boot/config.txt" "$FW/config.txt"
cp "$REPO_DIR/boot/slot.conf" "$FW/slot.conf"
(
	M17OS_FW_DIR="$FW"
	. "$LIB/bootslot.sh"
	check "slot_dev A" /dev/mmcblk0p2 "$(slot_dev A)"
	check "slot_dev B" /dev/mmcblk0p3 "$(slot_dev B)"
	check "other_slot" B "$(other_slot A)"
	check "no prefix yet" "" "$(active_slot)"

	install_slot_boot "$FW" A "$FW/cmdline.txt" || fail "install_slot_boot A"
	[ -f "$FW/slotA/kernel8.img" ] && [ -f "$FW/slotA/overlays/miniuart-bt.dtbo" ] && ok || fail "slotA contents"
	cmd=$(cat "$FW/slotA/cmdline.txt")
	check "cmdline" "console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 rootwait panic=10 fsck.repair=yes" "$cmd"

	set_active_slot A || fail "set_active_slot A"
	check "active A" A "$(active_slot)"
	check "one os_prefix" 1 "$(grep -c '^os_prefix=' "$FW/config.txt")"

	install_slot_boot "$FW" B "$FW/slotA/cmdline.txt" || fail "install_slot_boot B"
	check "slotB root" "console=tty1 root=/dev/mmcblk0p3 rootfstype=ext4 rootwait panic=10 fsck.repair=yes" "$(cat "$FW/slotB/cmdline.txt")"
	set_active_slot B
	check "active B" B "$(active_slot)"
	check "still one os_prefix" 1 "$(grep -c '^os_prefix=' "$FW/config.txt")"
	check "one slot block" 1 "$(grep -c '^# >>> m17-hotspot-os boot slot' "$FW/config.txt")"
	# The last section before os_prefix is [all] in our config.txt, so no
	# extra filter is needed
	check "no extra [all]" 1 "$(grep -c '^\[all\]' "$FW/config.txt")"

	M17OS_EVENT_LOG="$T/events/m17os-events.log"
	SLOT_EVENT_LOG="$M17OS_EVENT_LOG"
	slot_event "first event"
	i=0; while [ $i -lt 260 ]; do slot_event "event $i"; i=$((i + 1)); done
	grep -q 'event 259$' "$SLOT_EVENT_LOG" && ok || fail "slot_event did not write"
	n=$(wc -l < "$SLOT_EVENT_LOG")
	[ "$n" -le 250 ] && [ "$n" -ge 200 ] && ok || fail "event log not trimmed ($n lines)"

	set_active_slot C 2>/dev/null && fail "set_active_slot C should fail" || ok

	# slot.conf round trip, and hostile content is ignored
	read_slot_conf || fail "read_slot_conf"
	check "slot.conf active" A "$ACTIVE_SLOT"
	ACTIVE_SLOT=B; PREVIOUS_SLOT=A; PENDING=true; BOOT_TRIES=2; SLOT_B_VERSION=2026.11.17.1
	write_slot_conf
	read_slot_conf
	check "rt active" B "$ACTIVE_SLOT"
	check "rt pending" true "$PENDING"
	check "rt tries" 2 "$BOOT_TRIES"
	check "rt version" 2026.11.17.1 "$SLOT_B_VERSION"
	printf 'ACTIVE_SLOT=$(touch %s/pwned)\nBOOT_TRIES=1;reboot\nSLOT_A_VERSION="1.2 && x"\n' "$T" > "$FW/slot.conf"
	read_slot_conf
	[ -e "$T/pwned" ] && fail "slot.conf was executed" || ok
	check "bad slot ignored" "" "$ACTIVE_SLOT"
	check "bad tries ignored" 0 "$BOOT_TRIES"
	check "bad version ignored" "" "$SLOT_A_VERSION"
)

# ── clock (saved time) ───────────────────────────────────────────────
CK="$T/clock"
mkdir -p "$CK/bin" "$CK/data"
# A stand-in for date(1): "now" comes from $CK/now, and setting the clock
# is recorded instead of done
cat > "$CK/bin/date" <<EOF
#!/bin/sh
case "\$*" in
	+%s) cat "$CK/now" ;;
	"-u -s "*) echo "\$3" >> "$CK/set" ;;
	*) echo "fake date" ;;
esac
EOF
chmod +x "$CK/bin/date"
clk() { PATH="$CK/bin:$PATH" M17OS_CLOCK_FILE="$CK/data/clock" sh "$REPO_DIR/overlay/usr/local/libexec/m17os/clock" "$@" >/dev/null; }
: > "$CK/set"
echo 2000000000 > "$CK/now"
clk restore; check "restore without a saved time" "" "$(cat "$CK/set")"
touch -d @1900000000 "$CK/data/clock"
clk restore; check "older saved time is ignored" "" "$(cat "$CK/set")"
touch -d @2100000000 "$CK/data/clock"
clk restore; check "newer saved time is restored" "@2100000000" "$(cat "$CK/set")"
clk save; check "save keeps a newer saved time" 2100000000 "$(stat -c %Y "$CK/data/clock")"
echo 1000000000 > "$CK/now"
touch -d @900000000 "$CK/data/clock"
clk save
[ "$(stat -c %Y "$CK/data/clock")" -gt 900000000 ] && ok || fail "save did not update an older saved time"
rm -rf "$CK/data"
clk save; [ -e "$CK/data/clock" ] && fail "save created a missing /data directory" || ok

# ── idle.sh (is the gateway busy?) ───────────────────────────────────
. "$LIB/idle.sh"
IL="$T/dash.log"
now=$(date -u -d '2026-11-18 14:00:00' +%s)
busy() { if gateway_busy "$IL" "$now"; then echo busy; else echo idle; fi; }
rm -f "$IL"
check "no log is idle" idle "$(busy)"
printf '%s\n' '{"time":"2026-11-18T13:50:00Z","type":"Gateway","subtype":"Start"}' > "$IL"
check "old event is idle" idle "$(busy)"
printf '%s\n' '{"time":"2026-11-18T13:59:30.123Z","type":"Reflector","subtype":"Connect"}' >> "$IL"
check "event 30s ago is busy" busy "$(busy)"
printf '%s\n' '{"time":"2026-11-18T09:58:00-04:00","type":"RF","subtype":"Voice Start","src":"N1ADJ"}' > "$IL"
check "voice started 2 min ago (with -04:00 offset), no end" busy "$(busy)"
printf '%s\n' '{"time":"2026-11-18T13:58:30.5Z","type":"RF","subtype":"Voice End","src":"N1ADJ"}' >> "$IL"
check "voice ended 90s ago" idle "$(busy)"
printf '%s\n' '{"time":"2026-11-18T13:52:00Z","type":"Internet","subtype":"Voice Start","src":"AA5RL"}' > "$IL"
check "start 8 min ago without end (lost end)" idle "$(busy)"
printf '%s\n' '{"time":"2026-11-18T15:57:00+01:00","type":"Internet","subtype":"Voice Start","src":"AA5RL"}' > "$IL"
check "network voice 3 min ago (+01:00), no end" busy "$(busy)"

# ── m17os-autoupdate (with stand-ins for upgrade, apk, reboot) ─────────
AU="$T/au"
mkdir -p "$AU/bin" "$AU/state"
cat > "$AU/upgrade" <<EOF
#!/bin/sh
echo "\$*" >> "$AU/upgrade.calls"
case "\$1" in
	--check) if [ -f "$AU/os-available" ]; then echo "Available:  2099.1.1.1 (2099-01-01)"; exit 0; fi; exit 1 ;;
	--install) exit 0 ;;
esac
EOF
cat > "$AU/bin/reboot" <<EOF
#!/bin/sh
echo reboot >> "$AU/reboot.calls"
EOF
cat > "$AU/bin/rc-service" <<EOF
#!/bin/sh
echo "\$*" >> "$AU/rc.calls"
EOF
cat > "$AU/bin/apk" <<EOF
#!/bin/sh
echo "\$*" >> "$AU/apk.calls"
case "\$*" in
	"info -e "*) exit 0 ;;
	"update -q") exit 0 ;;
	"upgrade --simulate "*)
		[ -f "$AU/pkg-available" ] && echo "(1/1) Upgrading m17-gateway (0.9.3-r0 -> 0.9.4-r0)"
		[ -f "$AU/admin-available" ] && echo "(1/2) Upgrading m17-admin (0_git1-r0 -> 0_git1-r1)" && echo "(2/2) Upgrading m17-admin-openrc (0_git1-r0 -> 0_git1-r1)"
		exit 0 ;;
	"upgrade -q "*) exit 0 ;;
esac
exit 1
EOF
chmod +x "$AU/upgrade" "$AU/bin/"*
printf 'm17-hotspot-os\nVersion: 2026.11.18.1\nBuild Date: 2026-01-01\n' > "$AU/release"
au() { # au ARGS - run m17os-autoupdate in the sandbox; prints its exit code
	rm -f "$AU"/*.calls
	PATH="$AU/bin:$PATH" M17OS_LIB="$LIB" M17OS_STATE_DIR="$AU/state" M17OS_UPGRADE="$AU/upgrade" \
		M17OS_RELEASE="$AU/release" M17OS_DASHBOARD_LOG="$AU/dash.log" M17OS_EVENT_LOG="$AU/events.log" \
		M17OS_IDLE_WAIT=2 M17OS_IDLE_POLL=1 M17OS_MAX_DELAY=0 \
		sh "$BIN/m17os-autoupdate" "$@" > "$AU/out" 2>&1
	echo $?
}
calls() { cat "$AU/$1.calls" 2>/dev/null | tr '\n' ';'; }
result() { sed -n 's/^RESULT=//p' "$AU/state/autoupdate.status"; }
if [ "$(id -u)" -eq 0 ]; then
	rm -f "$AU/dash.log"
	touch "$AU/os-available"
	check "dry run with an OS update" 0 "$(au --dry-run)"
	check "dry run: checked only" "--check;" "$(calls upgrade)"
	check "dry run result" available "$(result)"

	check "--now installs the OS update" 0 "$(au --now)"
	check "--now: check then install" "--check;--install;" "$(calls upgrade)"
	check "--now reboots" "reboot;" "$(calls reboot)"
	check "install result" installed "$(result)"
	grep -q 'installed OS release 2099.1.1.1' "$AU/events.log" && ok || fail "install not in the event log"

	printf '%s\n' "{\"time\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"RF\",\"subtype\":\"Voice Start\"}" > "$AU/dash.log"
	check "busy gateway: no install" 0 "$(au --now)"
	check "busy: check only" "--check;" "$(calls upgrade)"
	check "busy: no reboot" "" "$(calls reboot)"
	check "busy result" busy "$(result)"
	rm -f "$AU/dash.log"

	# Cron mode: only in the update hour, once a day
	hour=$(date +%H | sed 's/^0//')
	other=$(( (hour + 1) % 24 ))
	echo "UPDATE_HOUR=$other" > "$AU/state/autoupdate.conf"
	check "cron outside the hour" 0 "$(au)"
	check "cron outside the hour: nothing" "" "$(calls upgrade)"
	printf 'AUTO_UPDATE=notify\nUPDATE_HOUR=%s\n' "$hour" > "$AU/state/autoupdate.conf"
	rm -f "$AU/state/autoupdate.day"
	check "cron notify" 0 "$(au)"
	check "notify: check only" "--check;" "$(calls upgrade)"
	check "notify result" available "$(result)"
	check "cron runs once a day" 0 "$(au)"
	check "second run: nothing" "" "$(calls upgrade)"
	printf 'AUTO_UPDATE=off\nUPDATE_HOUR=%s\n' "$hour" > "$AU/state/autoupdate.conf"
	rm -f "$AU/state/autoupdate.day"
	au >/dev/null
	check "off: nothing" "" "$(calls upgrade)"
	rm -f "$AU/state/autoupdate.conf"

	# Packages, when there's no OS update
	rm -f "$AU/os-available"
	touch "$AU/pkg-available"
	check "package update" 0 "$(au --now)"
	case "$(calls apk)" in *"upgrade -q m17-gateway"*) ok ;; *) fail "packages not upgraded: $(calls apk)" ;; esac
	check "gateway restarted" "m17-gateway status;m17-gateway restart;" "$(calls rc)"
	check "package result" updated "$(result)"
	grep -q 'updated packages: m17-gateway 0.9.4-r0' "$AU/events.log" && ok || fail "package update not in the event log: $(tail -1 "$AU/events.log")"
	au --dry-run >/dev/null
	case "$(calls apk)" in *"upgrade -q"*) fail "dry run installed packages" ;; *) ok ;; esac
	rm -f "$AU/pkg-available"
	touch "$AU/admin-available"
	au --now >/dev/null
	check "m17-admin restarted after its update" "m17-admin status;m17-admin restart;" "$(calls rc)"
	# Several at once (one per line from apk): each one restarted
	touch "$AU/pkg-available"
	au --now >/dev/null
	check "gateway and m17-admin both restarted" "m17-gateway status;m17-gateway restart;m17-admin status;m17-admin restart;" "$(calls rc)"
	rm -f "$AU/admin-available" "$AU/pkg-available"
	check "nothing to do" 0 "$(au --now)"
	check "nothing result" current "$(result)"

	# A clock before the build date: skip
	printf 'Build Date: 2999-01-01\n' > "$AU/release"
	check "clock wrong" 0 "$(au --now)"
	check "clock wrong: nothing" "" "$(calls upgrade)"
	check "clock result" skipped "$(result)"
	# Built today in UTC, still yesterday here: the clock is fine
	printf 'Build Date: %s\n' "$(date -u +%Y-%m-%d)" > "$AU/release"
	TZ=XYZ12 au --now >/dev/null
	[ "$(result)" = skipped ] && fail "a UTC build date ahead of the local date skips updates" || ok
else
	echo "skip: m17os-autoupdate tests need root"
fi

# ── netwatch.sh (setup access point decisions) ───────────────────────
# Each scenario runs the real loop with stand-ins: a fake clock, a
# scripted "online" answer, and actions recorded in $NW/actions.
NW="$T/nw"
nw_scenario() { # nw_scenario ONLINE_FROM ONLINE_UNTIL ITERATIONS [SETUP]
	rm -rf "$NW" && mkdir -p "$NW/run"
	(
		NW_RUN="$NW/run" NW_POLL=5 NW_BOOT_GRACE=90 NW_LOST_GRACE=300 NW_JOIN_WAIT=60 NW_RETRY=600
		. "$LIB/netwatch.sh"
		slot_event() { :; }
		logger() { :; }
		CLOCK=1000
		nw_now() { echo "$CLOCK"; }
		# shellcheck disable=SC1090  # the scenario's scripted events
		nw_sleep() { CLOCK=$((CLOCK + $1)); [ -f "$NW/at-$CLOCK" ] && . "$NW/at-$CLOCK"; }
		# online between ONLINE_FROM and ONLINE_UNTIL seconds after start ("" = never)
		ON_FROM="$1" ON_UNTIL="$2"
		nw_online() {
			[ -n "$ON_FROM" ] || return 1
			t=$((CLOCK - 1000))
			[ "$t" -ge "$ON_FROM" ] && { [ -z "$ON_UNTIL" ] || [ "$t" -lt "$ON_UNTIL" ]; }
		}
		nw_have_saved() { [ -f "$NW/saved" ]; }
		nw_ap_clients() { if [ -f "$NW/clients" ]; then echo 1; else echo 0; fi; }
		nw_ap_start() { echo "ap_start@$((CLOCK - 1000))" >> "$NW/actions"; }
		nw_ap_stop() { echo "ap_stop@$((CLOCK - 1000))" >> "$NW/actions"; }
		nw_client_start() { echo "client@$((CLOCK - 1000))" >> "$NW/actions"; }
		[ -n "${4:-}" ] && eval "$4"
		nw_loop "$3"
	)
}
actions() { [ -f "$NW/actions" ] && tr '\n' ' ' < "$NW/actions" | sed 's/ $//'; }

nw_scenario "" "" 30
check "no network at boot: AP after 90s" "ap_start@90" "$(actions)"
check "mode is ap" "ap" "$(cat "$NW/run/mode")"

nw_scenario 30 "" 40
check "network at 30s: never AP" "" "$(actions)"

nw_scenario 0 100 70
check "lost for under 5 min: no AP" "" "$(actions)"
nw_scenario 0 100 90
check "lost for 5 min: AP" "ap_start@400" "$(actions)"

# In AP mode, new settings: join, and it connects
nw_scenario "" "" 40 'echo "touch $NW/run/request-join; ON_FROM=200" > "$NW/at-1195"'
check "join after new settings" "ap_start@90 ap_stop@195 client@195" "$(actions)"
check "back to client mode" "client" "$(cat "$NW/run/mode")"

# ...and it doesn't connect: back to the AP, failure recorded
nw_scenario "" "" 40 'echo "touch $NW/run/request-join" > "$NW/at-1195"'
check "failed join: AP again" "ap_start@90 ap_stop@195 client@195 ap_start@255" "$(actions)"
[ -f "$NW/run/join-failed" ] && ok || fail "failed join not recorded"

# Saved WiFi and an idle AP: retry every 10 minutes (the router came up late)
nw_scenario "" "" 150 'touch "$NW/saved"; echo "ON_FROM=690" > "$NW/at-1690"'
check "retry the saved WiFi after 10 min" "ap_start@90 ap_stop@690 client@690" "$(actions)"
# ...but not while someone is using the AP
nw_scenario "" "" 150 'touch "$NW/saved" "$NW/clients"'
check "no retry with a phone on the AP" "ap_start@90" "$(actions)"
# ...and not without saved WiFi
nw_scenario "" "" 150
check "no retry without saved WiFi" "ap_start@90" "$(actions)"

# Started by hand
nw_scenario 0 "" 10 'echo "touch $NW/run/request-ap" > "$NW/at-1015"'
check "m17os-setup-ap start" "ap_start@15" "$(actions)"

# A restarted watcher clears an AP left running
nw_scenario 0 "" 2 'echo ap > "$NW/run/mode"'
check "restart with the AP up" "ap_stop@0 client@0" "$(actions)"

# Counting phones on the access point: only hostapd's MAC lines count
(
	. "$LIB/netwatch.sh"
	hostapd_cli() { printf 'Failed to connect to hostapd - wpa_ctrl_open: No such file or directory\n'; }
	check "hostapd_cli error is no clients" 0 "$(nw_ap_clients)"
	hostapd_cli() { printf 'Selected interface %s\n' "'wlan0'"; printf 'a4:83:e7:12:34:56\nDE:AD:BE:EF:00:01\n'; }
	check "two phones" 2 "$(nw_ap_clients)"
)
# Services are switched without OpenRC's dependents
grep -q 'rc-service --nodeps' "$LIB/netwatch.sh" && ok || fail "netwatch stops services with their dependents"
grep -E 'rc-service (wpa_supplicant|dhcpcd) (stop|start)' "$LIB/netwatch.sh" && fail "netwatch has a plain rc-service stop/start" || ok

# The access point's configuration
(
	NW_RUN="$NW/cfg" NW_WPA_CONF="$NW/wpa.conf"
	printf 'ctrl_interface=/var/run/wpa_supplicant\ncountry=GB\n' > "$NW/wpa.conf"
	. "$LIB/netwatch.sh"
	nw_ssid() { echo "M17-Setup-A1B2"; }
	nw_write_configs
)
grep -q '^ssid=M17-Setup-A1B2$' "$NW/cfg/hostapd.conf" && ok || fail "hostapd ssid"
grep -q '^country_code=GB$' "$NW/cfg/hostapd.conf" && ok || fail "hostapd country"
grep -q 'wpa' "$NW/cfg/hostapd.conf" && fail "the setup AP isn't open" || ok
grep -q '^address=/#/192.168.4.1$' "$NW/cfg/dnsmasq.conf" && ok || fail "dnsmasq doesn't answer every name"
grep -q '^dhcp-option=114,http://192.168.4.1/setup/$' "$NW/cfg/dnsmasq.conf" && ok || fail "no RFC 8910 captive portal option"
check "dhcp range" "dhcp-range=192.168.4.10,192.168.4.100,255.255.255.0,10m" "$(grep '^dhcp-range' "$NW/cfg/dnsmasq.conf")"

# ── ini.sh ───────────────────────────────────────────────────────────
. "$LIB/ini.sh"
INI="$T/gw.ini"
cat > "$INI" <<'EOF'
[General]
; comment
Callsign=CALLSIGN_PLACEHOLDER

[Radio]
RXFrequency = 439000000
TXFrequency=439000000

[Modem]
Type=cc1200
EOF
check "ini_get spaced" 439000000 "$(ini_get "$INI" Radio RXFrequency)"
ini_set "$INI" General Callsign "N1ADJ G"
check "ini_set existing" "N1ADJ G" "$(ini_get "$INI" General Callsign)"
ini_set "$INI" Radio RXFrequency 439500000
check "ini_set spaced key" 439500000 "$(ini_get "$INI" Radio RXFrequency)"
check "no duplicate key" 1 "$(grep -c 'RXFrequency' "$INI")"
ini_set "$INI" Radio Duplex true
check "ini_set new key" true "$(ini_get "$INI" Radio Duplex)"
check "new key in Radio" "Radio" "$(awk '/^\[/{s=$0} /^Duplex=/{gsub(/[][]/,"",s); print s}' "$INI")"
ini_set "$INI" Log Level INFO
check "ini_set new section" INFO "$(ini_get "$INI" Log Level)"
check "comment kept" 1 "$(grep -c '^; comment' "$INI")"
check "Modem untouched" cc1200 "$(ini_get "$INI" Modem Type)"
ln -s gw.ini "$T/link.ini"
ini_set "$T/link.ini" Modem Type mmdvm
[ -L "$T/link.ini" ] && ok || fail "ini_set replaced a symlink"
check "set through symlink" mmdvm "$(ini_get "$INI" Modem Type)"

# ── m17os-hat ────────────────────────────────────────────────────────
HFW="$T/hatfw"
mkdir -p "$HFW"
cp "$REPO_DIR/boot/config.txt" "$HFW/config.txt"
(
	M17OS_FW_DIR="$HFW"
	. "$LIB/bootslot.sh"
	mkdir -p "$HFW/slotA"
	set_active_slot A
)
HINI="$T/hat.ini"
printf '[Modem]\nType=cc1200v2\nSpeed=230400\n' > "$HINI"
hat() { M17OS_LIB="$LIB" M17OS_FW_DIR="$HFW" M17OS_GATEWAY_INI="$HINI" sh "$BIN/m17os-hat" "$@" >/dev/null 2>&1; echo $?; }
if [ "$(id -u)" -eq 0 ]; then
	check "hat cc1200 no change" 0 "$(hat set cc1200)"
	check "cc1200 variant kept" cc1200v2 "$(ini_get "$HINI" Modem Type)"
	check "speed kept when type unchanged" 230400 "$(ini_get "$HINI" Modem Speed)"
	check "hat sx1255 reboot" 3 "$(hat set sx1255)"
	check "sx1255 type" sx1255 "$(ini_get "$HINI" Modem Type)"
	check "i2s overlay" 1 "$(grep -c '^dtoverlay=genericstereoaudiocodec' "$HFW/config.txt")"
	# HAT block must come before the slot block, so os_prefix stays last
	last=$(grep -v '^#' "$HFW/config.txt" | grep -v '^$' | tail -1)
	check "os_prefix last" "os_prefix=slotA/" "$last"
	check "hat sx1255 again" 0 "$(hat set sx1255)"
	check "hat mmdvm reboot" 3 "$(hat set mmdvm)"
	check "mmdvm default speed" 115200 "$(ini_get "$HINI" Modem Speed)"
	ini_set "$HINI" Modem Speed 460800
	check "hat mmdvm again" 0 "$(hat set mmdvm)"
	check "hand-set mmdvm speed kept" 460800 "$(ini_get "$HINI" Modem Speed)"
	hat set cc1200 >/dev/null
	check "cc1200 default speed" 460800 "$(ini_get "$HINI" Modem Speed)"
	check "overlay removed" 0 "$(grep -c 'genericstereoaudiocodec' "$HFW/config.txt")"
	check "hat bad type" 1 "$(hat set bogus)"
	# The slot code still finds the active slot after HAT edits
	(
		M17OS_FW_DIR="$HFW"
		. "$LIB/bootslot.sh"
		check "slot after hat" A "$(active_slot)"
	)
else
	echo "skip: m17os-hat tests need root"
fi

PASS=$(wc -l < "$T/pass" | tr -d ' ')
FAIL=$(wc -l < "$T/fail" | tr -d ' ')
echo "unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
