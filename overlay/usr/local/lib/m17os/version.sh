# shellcheck shell=sh
# version.sh - release version comparison
# Part of m17-hotspot-os. Based on Pi-Star OS (MW0MWZ), GPL-2.0.

# version_gt A B - true if version A is newer than version B. Versions are
# dot-separated numbers (YYYY.MM.DD.N) compared field by field. Missing or
# non-numeric fields count as 0.
version_gt() {
	a="$1"
	b="$2"
	while [ -n "$a" ] || [ -n "$b" ]; do
		fa="${a%%.*}"
		fb="${b%%.*}"
		case "$a" in *.*) a="${a#*.}" ;; *) a="" ;; esac
		case "$b" in *.*) b="${b#*.}" ;; *) b="" ;; esac
		case "$fa" in ""|*[!0-9]*) fa=0 ;; esac
		case "$fb" in ""|*[!0-9]*) fb=0 ;; esac
		[ "$fa" -gt "$fb" ] && return 0
		[ "$fa" -lt "$fb" ] && return 1
	done
	return 1
}
