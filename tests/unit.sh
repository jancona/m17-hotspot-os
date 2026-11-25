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
clk() { PATH="$CK/bin:$PATH" M17OS_CLOCK_FILE="$CK/data/clock" M17OS_BUILD_STAMP="$CK/built" sh "$REPO_DIR/overlay/usr/local/libexec/m17os/clock" "$@" >/dev/null; }
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
# A new card: no saved time, but the build time is a floor
rm -f "$CK/data/clock"; : > "$CK/set"
echo 1000000000 > "$CK/now"
touch -d @1800000000 "$CK/built"
clk restore; check "new card: clock set to the build time" "@1800000000" "$(cat "$CK/set")"
: > "$CK/set"
touch -d @1850000000 "$CK/data/clock"
clk restore; check "a saved time later than the build wins" "@1850000000" "$(cat "$CK/set")"
rm -f "$CK/built"
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
		[ -f "$AU/admin-available" ] && echo "(1/2) Upgrading m17-web (0_git1-r0 -> 0_git1-r1)" && echo "(2/2) Upgrading m17-web-openrc (0_git1-r0 -> 0_git1-r1)"
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
	check "m17-web restarted after its update" "m17-web status;m17-web restart;" "$(calls rc)"
	# Several at once (one per line from apk): each one restarted
	touch "$AU/pkg-available"
	au --now >/dev/null
	check "gateway and m17-web both restarted" "m17-gateway status;m17-gateway restart;m17-web status;m17-web restart;" "$(calls rc)"
	rm -f "$AU/admin-available" "$AU/pkg-available"
	check "nothing to do" 0 "$(au --now)"
	check "nothing result" current "$(result)"

	# --check (the admin pages' Check for updates): both, installing and
	# recording nothing
	touch "$AU/os-available" "$AU/pkg-available"
	cp "$AU/state/autoupdate.status" "$AU/status.before"
	check "--check" 0 "$(au --check)"
	grep -qx 'OS_AVAILABLE=2099.1.1.1' "$AU/out" && ok || fail "--check: no OS line: $(cat "$AU/out")"
	grep -qx 'PACKAGES_AVAILABLE=m17-gateway 0.9.4-r0' "$AU/out" && ok || fail "--check: no packages line: $(cat "$AU/out")"
	check "--check: OS checked only" "--check;" "$(calls upgrade)"
	case "$(calls apk)" in *"upgrade -q"*) fail "--check installed packages" ;; *) ok ;; esac
	check "--check: no reboot" "" "$(calls reboot)"
	cmp -s "$AU/status.before" "$AU/state/autoupdate.status" && ok || fail "--check changed the last automatic run's status"
	rm -f "$AU/os-available" "$AU/pkg-available"
	au --check >/dev/null
	grep -qx 'OS_CURRENT=true' "$AU/out" && grep -qx 'PACKAGES_CURRENT=true' "$AU/out" && ok || fail "--check, nothing new: $(cat "$AU/out")"

	# --packages (the admin pages' Update now): packages only, never an OS
	# release, even when one is available, so never a reboot
	touch "$AU/os-available" "$AU/pkg-available"
	check "--packages" 0 "$(au --packages)"
	check "--packages: no OS check" "" "$(calls upgrade)"
	check "--packages: no reboot" "" "$(calls reboot)"
	case "$(calls apk)" in *"upgrade -q m17-gateway"*) ok ;; *) fail "--packages didn't upgrade: $(calls apk)" ;; esac
	check "--packages result" updated "$(result)"
	rm -f "$AU/pkg-available"
	au --packages >/dev/null
	grep -qx 'The M17 packages are up to date' "$AU/out" && ok || fail "--packages up to date: $(cat "$AU/out")"
	grep -q 'Everything is up to date' "$AU/out" && fail "--packages claims the OS is up to date" || ok
	rm -f "$AU/os-available"

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

# ── Gateway health hook ───────────────────────────────────────────────
# Stand-ins for OpenRC and pidof, a fake /proc and the gateway's log
GH="$T/gh"
mkdir -p "$GH/bin" "$GH/proc/4242"
printf '#!/bin/sh\necho " m17-gateway | default"\n' > "$GH/bin/rc-update"
printf '#!/bin/sh\nexit 0\n' > "$GH/bin/rc-service"
printf '#!/bin/sh\necho 4242\n' > "$GH/bin/pidof"
chmod +x "$GH/bin/"*
printf '[General]\nCallsign=N1ADJ R\n' > "$GH/gw.ini"
gh_proc() { # gh_proc UPTIME STARTTICKS - the system's uptime, the process's start
	echo "$1 0.00" > "$GH/proc/uptime"
	echo "4242 (m17-gateway) S 1 4242 4242 0 -1 0 0 0 0 0 0 0 0 0 20 0 9 0 $2 0 0" > "$GH/proc/4242/stat"
}
gh_hook() { # prints the hook's exit code, then its output
	out=$(PATH="$GH/bin:$PATH" M17OS_PROC="$GH/proc" M17OS_GATEWAY_LOG="$GH/gw.log" M17OS_GATEWAY_INI="$GH/gw.ini" \
		sh "$REPO_DIR/overlay/etc/m17os/health.d/50-m17-gateway" 2>&1)
	echo "$? $out"
}
cat > "$GH/gw.log" <<'EOF'
2026/11/24 12:52:53 [INFO] Loading settings from '/etc/m17-gateway.ini'
2026/11/24 12:52:55.136323 [ERROR] Received a NAK from the modem: 02 04
2026/11/24 12:52:55.136343 Error creating MMDVM modem: modem returned NAK
2026/11/24 12:53:05 [INFO] Loading settings from '/etc/m17-gateway.ini'
EOF
gh_proc 100 9800   # started 2 s ago
case "$(gh_hook)" in "1 running for 2s"*) ok ;; *) fail "a gateway just started passed: $(gh_hook)" ;; esac
gh_proc 100 1000   # running 90 s, but no modem since its last start
case "$(gh_hook)" in "1 modem not connected: "*"modem returned NAK"*) ok ;; *) fail "a gateway without its modem: $(gh_hook)" ;; esac
echo "2026/11/24 12:53:07.049458 [INFO] Connected to MMDVM modem on /dev/ttyAMA0" >> "$GH/gw.log"
check "gateway running with its modem" "0 " "$(gh_hook)"
# Connected before a restart doesn't count
echo "2026/11/24 13:00:00 [INFO] Loading settings from '/etc/m17-gateway.ini'" >> "$GH/gw.log"
case "$(gh_hook)" in "1 modem not connected"*) ok ;; *) fail "a connection from before the last start counted: $(gh_hook)" ;; esac
# Not configured yet: nothing to check
printf '[General]\nCallsign=CALLSIGN_PLACEHOLDER\n' > "$GH/gw.ini"
check "unconfigured gateway passes" "0 " "$(gh_hook)"

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
HEV="$T/hat-events.log"
hat() { M17OS_LIB="$LIB" M17OS_FW_DIR="$HFW" M17OS_GATEWAY_INI="$HINI" M17OS_EVENT_LOG="$HEV" sh "$BIN/m17os-hat" "$@" >/dev/null 2>&1; echo $?; }
hat_events() { grep -c 'HAT changed' "$HEV" 2>/dev/null || echo 0; }
if [ "$(id -u)" -eq 0 ]; then
	check "hat cc1200 no change" 0 "$(hat set cc1200)"
	check "cc1200 variant kept" cc1200v2 "$(ini_get "$HINI" Modem Type)"
	check "speed kept when type unchanged" 230400 "$(ini_get "$HINI" Modem Speed)"
	check "no event when the HAT is unchanged" 0 "$(hat_events)"
	check "hat sx1255 reboot" 3 "$(hat set sx1255)"
	grep -q 'HAT changed from cc1200v2 to sx1255' "$HEV" && ok || fail "HAT change not in the event log"
	check "sx1255 type" sx1255 "$(ini_get "$HINI" Modem Type)"
	check "i2s overlay" 1 "$(grep -c '^dtoverlay=genericstereoaudiocodec' "$HFW/config.txt")"
	# HAT block must come before the slot block, so os_prefix stays last
	last=$(grep -v '^#' "$HFW/config.txt" | grep -v '^$' | tail -1)
	check "os_prefix last" "os_prefix=slotA/" "$last"
	check "hat sx1255 again" 0 "$(hat set sx1255)"
	check "setting the same HAT again logs nothing" 1 "$(hat_events)"
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

# ── m17os-firmware ──────────────────────────────────────────────────
FWD="$T/firmware"
mkdir -p "$FWD/mmdvm_hs" "$FWD/cc1200" "$FWD/mmdvm"
echo hs > "$FWD/mmdvm_hs/MMDVM_HS_Hat.bin"
echo cc > "$FWD/cc1200/CC1200_HAT-fw.bin"
echo elf > "$FWD/mmdvm/F446RE.elf"
fwt() { M17OS_LIB="$LIB" M17OS_FIRMWARE_DIR="$FWD" sh "$BIN/m17os-firmware" "$@"; }
check "firmware list" "cc1200/CC1200_HAT-fw.bin mmdvm_hs/MMDVM_HS_Hat.bin" "$(fwt list | tr '\n' ' ' | sed 's/ $//')"
fwt check mmdvm_hs/MMDVM_HS_Hat.bin && ok || fail "firmware check: a listed file"
for bad in ../etc/passwd /etc/passwd mmdvm/F446RE.elf mmdvm_hs/missing.bin 'mmdvm_hs/a b.bin' "mmdvm_hs/../cc1200/CC1200_HAT-fw.bin" ""; do
	fwt check "$bad" && fail "firmware check accepted '$bad'" || ok
done
if [ "$(id -u)" -eq 0 ]; then
	GS="$T/gpio"
	mkdir -p "$GS/gpiochip512" "$GS/gpiochip570" "$GS/gpio532" "$GS/gpio533"
	echo raspberrypi-exp-gpio > "$GS/gpiochip570/label"; echo 570 > "$GS/gpiochip570/base"
	echo pinctrl-bcm2835 > "$GS/gpiochip512/label"; echo 512 > "$GS/gpiochip512/base"
	: > "$GS/export"; : > "$GS/unexport"
	FINI="$T/fw.ini"
	printf '[Modem]\nType=mmdvm\nPort=/dev/null\n' > "$FINI"
	cat > "$T/stm32flash" <<'EOS'
#!/bin/sh
echo "$*" > "$FW_TEST/stm32-args"
exit "${STM32_RC:-0}"
EOS
	cat > "$T/rc-service" <<'EOS'
#!/bin/sh
echo "$2" >> "$FW_TEST/rc"
[ "$2" = status ] && exit "${GW_STATUS:-0}"
exit 0
EOS
	chmod +x "$T/stm32flash" "$T/rc-service"
	flashit() {
		rm -f "$T/stm32-args" "$T/rc"
		FW_TEST="$T" M17OS_LIB="$LIB" M17OS_FIRMWARE_DIR="$FWD" M17OS_GATEWAY_INI="$FINI" \
			M17OS_GPIO_SYSFS="$GS" M17OS_STM32FLASH="$T/stm32flash" M17OS_RC_SERVICE="$T/rc-service" \
			sh "$BIN/m17os-firmware" flash "$@" >/dev/null 2>&1
		echo $?
	}
	check "flash ok" 0 "$(flashit mmdvm_hs/MMDVM_HS_Hat.bin)"
	check "stm32flash arguments" "-v -R -i -532&-533&532,533,:-532,-533,533 -w $FWD/mmdvm_hs/MMDVM_HS_Hat.bin /dev/null" "$(cat "$T/stm32-args")"
	check "gateway stopped and started" "status stop start" "$(tr '\n' ' ' < "$T/rc" | sed 's/ $//')"
	# A gateway that wasn't running stays stopped
	check "flash, gateway stopped" 0 "$(GW_STATUS=3 flashit mmdvm_hs/MMDVM_HS_Hat.bin)"
	check "gateway left stopped" "status" "$(tr '\n' ' ' < "$T/rc" | sed 's/ $//')"
	# Pins from the configuration
	printf '[Modem]\nType=cc1200\nPort=/dev/null\nBoot0Pin=5\nNRSTPin=6\n' > "$FINI"
	flashit cc1200/CC1200_HAT-fw.bin >/dev/null
	check "configured pins" "-v -R -i -517&-518&517,518,:-517,-518,518" "$(cut -d' ' -f1-4 < "$T/stm32-args")"
	# A failed flash resets the HAT out of its bootloader and restarts the gateway
	printf '[Modem]\nType=mmdvm\nPort=/dev/null\n' > "$FINI"
	check "flash failure" 1 "$(STM32_RC=1 flashit mmdvm_hs/MMDVM_HS_Hat.bin)"
	check "BOOT0 low after failure" 0 "$(cat "$GS/gpio532/value")"
	check "NRST released after failure" 1 "$(cat "$GS/gpio533/value")"
	check "gateway restarted after failure" "status stop start" "$(tr '\n' ' ' < "$T/rc" | sed 's/ $//')"
	# Refusals
	printf '[Modem]\nType=sx1255\nPort=/dev/null\n' > "$FINI"
	check "no flashing for the SX1255" 1 "$(flashit mmdvm_hs/MMDVM_HS_Hat.bin)"
	printf '[Modem]\nType=mmdvm\nPort=/dev/null\nBoot0Pin=x\n' > "$FINI"
	check "bad pin" 1 "$(flashit mmdvm_hs/MMDVM_HS_Hat.bin)"
	[ -f "$T/stm32-args" ] && fail "stm32flash ran with a bad pin" || ok
	printf '[Modem]\nType=mmdvm\nPort=/dev/null\n' > "$FINI"
	check "unknown file" 1 "$(flashit mmdvm/F446RE.elf)"
	rm -rf "$GS/gpiochip512"
	check "no GPIO chip" 1 "$(flashit mmdvm_hs/MMDVM_HS_Hat.bin)"
else
	echo "skip: m17os-firmware flash tests need root"
fi

# ── admin-helper firmware-flash / firmware-status (stand-in tool) ─────
HR="$T/helper-run"
mkdir -p "$HR"
cat > "$T/fwstub" <<'EOS'
#!/bin/sh
case "$1" in
	check) [ "$2" = good.bin ] || [ "$2" = bad.bin ] ;;
	flash) printf 'Flashing %s\nWrote 10%%\rWrote 100%%\n' "$2"; sleep 1; [ "$2" = good.bin ] ;;
esac
EOS
chmod +x "$T/fwstub"
helper() { M17OS_RUN="$HR" M17OS_FIRMWARE="$T/fwstub" sh "$REPO_DIR/overlay/usr/local/libexec/m17os/admin-helper" "$@"; }
check "no flash yet" "" "$(helper firmware-status)"
helper firmware-flash nope.bin >/dev/null 2>&1; check "unknown firmware refused" 2 "$?"
helper firmware-flash good.bin | grep -q '^started=[0-9]' && ok || fail "firmware-flash didn't start"
helper firmware-status | grep -qx 'state=running' && ok || fail "flash not shown running"
helper firmware-flash good.bin >/dev/null 2>&1; check "second flash refused" 2 "$?"
(
	. "$LIB/idle.sh"
	M17OS_RUN="$HR"
	firmware_flashing && ok || fail "a flash doesn't count as busy"
	gateway_busy "$T/no-such-log" && ok || fail "gateway not busy while flashing"
)
i=0; while helper firmware-status | grep -qx 'state=running' && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
st=$(helper firmware-status)
echo "$st" | grep -qx 'state=ok' && ok || fail "flash not ok: $st"
echo "$st" | grep -qx 'file=good.bin' && ok || fail "flash file: $st"
echo "$st" | grep -qx 'log: Wrote 100%' && ok || fail "progress lines split: $st"
( . "$LIB/idle.sh"; M17OS_RUN="$HR"; firmware_flashing && fail "finished flash still busy" || ok )
helper firmware-flash bad.bin >/dev/null
i=0; while helper firmware-status | grep -qx 'state=running' && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
helper firmware-status | grep -qx 'state=failed' && ok || fail "failed flash not reported"
# A job that died without finishing
printf 'state=running\nfile=x.bin\nstarted=1\n' > "$HR/firmware.status"
echo 999999 > "$HR/firmware.pid"
helper firmware-status | grep -qx 'state=failed' && ok || fail "dead flash job shown running"

# ── boot watchdog: counting and the rollback message ─────────────────
wd() { # wd TRIES MAX: run the watchdog's start() for a pending slot; prints its log
	(
		tries=$1 max=$2
		# The library from the repo, no m17os.conf, and the rollback (which
		# reboots) a no-op
		sed -e "s|/usr/local/lib/m17os/bootslot.sh|$LIB/bootslot.sh|" \
			-e "s|^\[ -f /etc/m17os/m17os.conf \].*||" \
			-e "s|/usr/local/bin/m17os-rollback --force|true|" \
			"$REPO_DIR/overlay/etc/init.d/m17os-boot-watchdog" > "$T/wd.sh"
		M17OS_EVENT_LOG="$T/wd-events.log"
		: > "$M17OS_EVENT_LOG"
		. "$T/wd.sh"
		MAX_BOOT_TRIES=$max
		ebegin() { :; }; eend() { :; }; ewarn() { :; }
		read_slot_conf() { ACTIVE_SLOT=A PREVIOUS_SLOT=B PENDING=true BOOT_TRIES=$tries; }
		write_slot_conf() { :; }
		booted_slot() { echo A; }
		start >/dev/null 2>&1
		cat "$M17OS_EVENT_LOG"
	)
}
out=$(wd 0 3)
echo "$out" | grep -q 'boot try 1 of 3' && ok || fail "watchdog first try: $out"
out=$(wd 2 3)
echo "$out" | grep -q 'boot try 3 of 3' && ok || fail "watchdog last try: $out"
out=$(wd 3 3)
echo "$out" | grep -q 'failed 3 boots - rolling back to slot B' && ok || fail "watchdog rollback: $out"
echo "$out" | grep -q 'try 4 of 3' && fail "watchdog says try 4 of 3: $out" || ok

# ── init order: syslog after the clock, hostname and time zone ───────
dep() { sed -n '/^depend()/,/^}/p' "$REPO_DIR/overlay/etc/init.d/$1" | grep -E "^\s*before" ; }
dep m17os-config | grep -qw syslog && dep m17os-config | grep -qw hostname && ok || fail "m17os-config not before syslog and hostname"
dep m17os-clock | grep -qw syslog && ok || fail "m17os-clock not before syslog"

# ── m17os-config: callsigns m17-gateway accepts ──────────────────────
eval "$(sed -n '/^valid_callsign() {/,/^}/p' "$REPO_DIR/overlay/usr/local/bin/m17os-config")"
for c in N1ADJ "N1ADJ G" N1ADJ-1 N1ADJ/P EA/N1ADJ 2E0ABC 4U1ITU K1A W100AW "VE3ABCD M"; do
	valid_callsign "$c" && ok || fail "callsign '$c' refused"
done
for c in "" NADJ N1 1234 "BAD*CALL" N1ADJ_1 "N1ADJ  ABCD"; do
	valid_callsign "$c" && fail "callsign '$c' accepted" || ok
done

PASS=$(wc -l < "$T/pass" | tr -d ' ')
FAIL=$(wc -l < "$T/fail" | tr -d ' ')
echo "unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
