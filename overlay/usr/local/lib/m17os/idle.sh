# shellcheck shell=sh
# idle.sh - is the gateway in the middle of a transmission?
# Part of m17-hotspot-os.

# gateway_busy LOG [NOW] - true if the dashboard log LOG shows the gateway
# busy at NOW (seconds since the epoch; default: now): a voice stream
# (RF or Internet) has started and not ended, or anything was logged in the
# last 60 seconds. A start older than 5 minutes with no end is taken to be
# a lost end, not a 5-minute transmission. A firmware flash in progress
# (m17os-firmware through the setup wizard) counts as busy too.
gateway_busy() {
	log="$1"
	now="${2:-$(date +%s)}"
	firmware_flashing && return 0
	[ -f "$log" ] || return 1
	tail -n 200 "$log" | awk -v now="$now" '
		# RFC 3339 time -> seconds since the epoch (UTC; the offset applied)
		function epoch(t,    d, y, mo, dd, h, mi, s, off, sign, days, i) {
			if (!match(t, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}/)) return -1
			y = substr(t, 1, 4) + 0; mo = substr(t, 6, 2) + 0; dd = substr(t, 9, 2) + 0
			h = substr(t, 12, 2) + 0; mi = substr(t, 15, 2) + 0; s = substr(t, 18, 2) + 0
			off = 0
			if (match(t, /[+-][0-9]{2}:[0-9]{2}$/)) {
				sign = substr(t, RSTART, 1) == "-" ? -1 : 1
				off = sign * (substr(t, RSTART + 1, 2) * 3600 + substr(t, RSTART + 4, 2) * 60)
			}
			# days from 1970-01-01 to y-mo-dd
			if (mo <= 2) { y--; mo += 12 }
			days = 365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (mo - 3) + 2) / 5) + dd - 719469
			return days * 86400 + h * 3600 + mi * 60 + s - off
		}
		{
			if (!match($0, /"time":"[^"]*"/)) next
			t = epoch(substr($0, RSTART + 8, RLENGTH - 9))
			if (t < 0) next
			last = t
			if ($0 ~ /"subtype":"Voice Start"/) open = t
			else if ($0 ~ /"subtype":"Voice End"/) open = 0
		}
		END {
			if (last != "" && now - last < 60) exit 0          # recent activity
			if (open > 0 && now - open < 300) exit 0          # stream in progress
			exit 1
		}
	'
}

# firmware_flashing - the admin helper is writing firmware to the HAT
firmware_flashing() {
	_run="${M17OS_RUN:-/run/m17os}"
	grep -qx 'state=running' "$_run/firmware.status" 2>/dev/null || return 1
	_pid=$(cat "$_run/firmware.pid" 2>/dev/null)
	[ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null
}
