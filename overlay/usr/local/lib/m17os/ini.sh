# shellcheck shell=sh
# ini.sh - read and change keys in INI files such as /etc/m17-gateway.ini
# Part of m17-hotspot-os.

# ini_get FILE SECTION KEY - print KEY's value from [SECTION]
ini_get() {
	awk -v s="$2" -v k="$3" '
		/^[[:space:]]*\[/ { sec = $0; gsub(/[][[:space:]]/, "", sec); next }
		sec == s {
			line = $0
			sub(/^[[:space:]]*/, "", line)
			n = index(line, "=")
			if (n == 0) next
			key = substr(line, 1, n - 1); sub(/[[:space:]]*$/, "", key)
			if (key != k) next
			val = substr(line, n + 1); sub(/^[[:space:]]*/, "", val); sub(/[[:space:]]*$/, "", val)
			print val; exit
		}
	' "$1"
}

# ini_set FILE SECTION KEY VALUE - set KEY in [SECTION], adding the key (and
# the section) if missing. Comments and layout are kept. The file is
# rewritten in place, so its owner, mode and any symlink to it are kept.
ini_set() {
	case "$4" in
		*"
"*) echo "ini_set: value for $3 contains a newline" >&2; return 1 ;;
	esac
	tmp=$(mktemp) || return 1
	if ! awk -v s="$2" -v k="$3" -v v="$4" '
		function flush() { if (sec == s && !done) { print k "=" v; done = 1 } }
		/^[[:space:]]*\[/ {
			flush()
			sec = $0; gsub(/[][[:space:]]/, "", sec)
			if (sec == s) found = 1
			print; next
		}
		sec == s && !done {
			line = $0
			sub(/^[[:space:]]*/, "", line)
			n = index(line, "=")
			if (n > 0) {
				key = substr(line, 1, n - 1); sub(/[[:space:]]*$/, "", key)
				if (key == k) { print k "=" v; done = 1; next }
			}
		}
		{ print }
		END {
			flush()
			if (!found) { print ""; print "[" s "]"; print k "=" v }
		}
	' "$1" > "$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	cat "$tmp" > "$1"
	rm -f "$tmp"
}
