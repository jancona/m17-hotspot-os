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
