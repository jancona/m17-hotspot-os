# shellcheck shell=sh
# bootslot.sh - per-slot boot files on the boot partition, and slot.conf
# Part of m17-hotspot-os. Based on Pi-Star OS by Andy Taylor, MW0MWZ
# (https://github.com/MW0MWZ/Pi-Star_OS), GPL-2.0.
#
# Sourced by m17os-upgrade, m17os-rollback, m17os-slot-info, the boot
# watchdog and health check, and the image build.
#
# Each root slot has its own directory on the boot partition holding its
# kernels, device trees, overlays and cmdline.txt:
#
#   /boot/firmware/slotA/   root=/dev/mmcblk0p2
#   /boot/firmware/slotB/   root=/dev/mmcblk0p3
#
# The firmware picks one through os_prefix in config.txt, so switching
# slots is a single small write and an upgrade never touches the running
# slot's boot files. GPU firmware (start*.elf, fixup*.dat, bootcode.bin)
# stays shared at the root: it is loaded before config.txt is read.

BOOTSLOT_FW_DIR="${M17OS_FW_DIR:-/boot/firmware}"
BOOTSLOT_DISK="${M17OS_DISK:-/dev/mmcblk0}"
SLOT_CONF="${M17OS_SLOT_CONF:-$BOOTSLOT_FW_DIR/slot.conf}"

# slot_part SLOT - partition number for slot A or B
slot_part() {
	case "$1" in
		A) echo 2 ;;
		B) echo 3 ;;
		*) return 1 ;;
	esac
}

# slot_dev SLOT - block device for slot A or B
slot_dev() {
	part=$(slot_part "$1") || return 1
	echo "${BOOTSLOT_DISK}p$part"
}

# other_slot SLOT - the other slot
other_slot() {
	case "$1" in
		A) echo B ;;
		B) echo A ;;
		*) return 1 ;;
	esac
}

# boot_prefix - os_prefix currently set in config.txt ("" if none)
boot_prefix() {
	sed -n 's/^[[:space:]]*os_prefix[[:space:]]*=[[:space:]]*//p' \
		"$BOOTSLOT_FW_DIR/config.txt" 2>/dev/null | tail -1 | tr -d '\r' | sed 's/[[:space:]]*$//'
}

# active_slot - slot selected by config.txt (A or B), or "" if none
active_slot() {
	case "$(boot_prefix)" in
		slotA/) echo A ;;
		slotB/) echo B ;;
		*) echo "" ;;
	esac
}

# make_cmdline TEMPLATE SLOT - print TEMPLATE's kernel command line with
# root= pointing at SLOT, plus panic=10 (a panicking kernel reboots rather
# than hangs) and fsck.repair=yes. Any serial console is removed: the UART
# on GPIO 14/15 belongs to the radio HAT.
make_cmdline() {
	line=$(head -1 "$1" | tr -d '\r')
	dev=$(slot_dev "$2")
	case "$line" in
		*root=*) line=$(echo "$line" | sed "s|root=[^ ]*|root=$dev|") ;;
		*) line="$line root=$dev" ;;
	esac
	line=$(echo "$line" | sed -E 's/(^| )console=(serial[0-9]|ttyAMA[0-9]|ttyS[0-9])(,[0-9]+)?( |$)/ /g')
	case " $line " in *" panic="*) ;; *) line="$line panic=10" ;; esac
	case " $line " in *" fsck.repair="*) ;; *) line="$line fsck.repair=yes" ;; esac
	echo "$line" | sed 's/^ *//; s/  */ /g'
}

# install_slot_boot SRC SLOT CMDLINE_TEMPLATE - (re)build SLOT's boot
# directory from the kernels, device trees and overlays in SRC (a
# /boot/firmware tree). Built as slotX.new and renamed into place, so an
# interruption leaves the previous copy intact.
install_slot_boot() {
	src="$1"
	slot="$2"
	template="$3"
	dest="$BOOTSLOT_FW_DIR/slot$slot"
	new="$dest.new"

	rm -rf "$new"
	mkdir -p "$new"
	found=0
	for f in "$src"/kernel*.img; do
		[ -f "$f" ] || continue
		cp "$f" "$new/"
		found=1
	done
	if [ "$found" -eq 0 ]; then
		rm -rf "$new"
		echo "bootslot: no kernel*.img in $src" >&2
		return 1
	fi
	for f in "$src"/*.dtb; do
		[ -f "$f" ] && cp "$f" "$new/"
	done
	if [ -d "$src/overlays" ]; then
		cp -r "$src/overlays" "$new/overlays"
	fi
	make_cmdline "$template" "$slot" > "$new/cmdline.txt"
	sync

	rm -rf "$dest.old"
	[ -d "$dest" ] && mv "$dest" "$dest.old"
	mv "$new" "$dest"
	rm -rf "$dest.old"
	sync
}

# set_active_slot SLOT - point config.txt's os_prefix at SLOT. The managed
# block is replaced by writing a temp file and renaming it over config.txt.
set_active_slot() {
	slot="$1"
	cfg="$BOOTSLOT_FW_DIR/config.txt"
	tmp="$cfg.tmp"
	[ -d "$BOOTSLOT_FW_DIR/slot$slot" ] || {
		echo "bootslot: $BOOTSLOT_FW_DIR/slot$slot does not exist" >&2
		return 1
	}
	# Drop any previous managed block and stray os_prefix lines
	awk '
		/^# >>> m17-hotspot-os boot slot/ { skip = 1; next }
		/^# <<< m17-hotspot-os boot slot/ { skip = 0; next }
		skip { next }
		/^[[:space:]]*os_prefix[[:space:]]*=/ { next }
		{ print }
	' "$cfg" > "$tmp"
	# os_prefix must apply to every model, so it needs an [all] filter -
	# unless the section in force at the end of the file already is one.
	filter=""
	last=$(sed -n 's/^[[:space:]]*\(\[[^]]*\]\).*/\1/p' "$tmp" | tail -1)
	if [ -n "$last" ] && [ "$last" != "[all]" ]; then
		filter="[all]
"
	fi
	cat >> "$tmp" <<EOF
# >>> m17-hotspot-os boot slot (managed by m17os-upgrade / m17os-rollback)
# The active slot's kernels, device trees, overlays and cmdline.txt live
# under os_prefix. If this slot won't boot, edit this file on a PC and
# change slot$slot/ to slot$(other_slot "$slot")/.
${filter}os_prefix=slot$slot/
# <<< m17-hotspot-os boot slot
EOF
	sync
	mv "$tmp" "$cfg"
	sync
}

# slot_event MESSAGE - record MESSAGE in syslog and in a log on /data.
# /var/log is a tmpfs, and the events that matter most (a failed health
# check, a rollback) end in a reboot, so they are kept where they survive.
# The log is kept to its last 200 lines, and is readable by everyone so
# m17os-slot-info can show it without doas.
SLOT_EVENT_LOG="${M17OS_EVENT_LOG:-/data/log/m17os-events.log}"
slot_event() {
	logger -t m17os -p daemon.notice "$*" 2>/dev/null || true
	dir="${SLOT_EVENT_LOG%/*}"
	[ -d "$dir" ] || mkdir -m 0755 "$dir" 2>/dev/null || return 0
	echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$SLOT_EVENT_LOG" 2>/dev/null || return 0
	if [ "$(wc -l < "$SLOT_EVENT_LOG")" -gt 250 ]; then
		tail -n 200 "$SLOT_EVENT_LOG" > "$SLOT_EVENT_LOG.tmp" && mv "$SLOT_EVENT_LOG.tmp" "$SLOT_EVENT_LOG"
	fi
}

# read_slot_conf - load slot.conf into ACTIVE_SLOT, PREVIOUS_SLOT, PENDING,
# BOOT_TRIES, SLOT_A_VERSION and SLOT_B_VERSION. Parsed, not sourced: the
# file lives on a FAT partition anyone can edit from a PC.
read_slot_conf() {
	ACTIVE_SLOT=""
	PREVIOUS_SLOT=""
	PENDING=false
	BOOT_TRIES=0
	SLOT_A_VERSION=""
	SLOT_B_VERSION=""
	[ -f "$SLOT_CONF" ] || return 1
	while IFS='=' read -r key value; do
		value=$(echo "$value" | tr -d '"\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		case "$key" in
			ACTIVE_SLOT|PREVIOUS_SLOT)
				case "$value" in A|B|"") ;; *) value="" ;; esac
				eval "$key=\$value" ;;
			PENDING)
				[ "$value" = "true" ] && PENDING=true || PENDING=false ;;
			BOOT_TRIES)
				case "$value" in ""|*[!0-9]*) value=0 ;; esac
				BOOT_TRIES=$value ;;
			SLOT_A_VERSION|SLOT_B_VERSION)
				case "$value" in *[!0-9A-Za-z.+-]*) value="" ;; esac
				eval "$key=\$value" ;;
		esac
	done < "$SLOT_CONF"
	return 0
}

# write_slot_conf - write the current values back to slot.conf atomically
write_slot_conf() {
	cat > "$SLOT_CONF.tmp" <<EOF
ACTIVE_SLOT=$ACTIVE_SLOT
PREVIOUS_SLOT=$PREVIOUS_SLOT
PENDING=$PENDING
BOOT_TRIES=$BOOT_TRIES
SLOT_A_VERSION="$SLOT_A_VERSION"
SLOT_B_VERSION="$SLOT_B_VERSION"
EOF
	sync
	mv "$SLOT_CONF.tmp" "$SLOT_CONF"
	sync
}
