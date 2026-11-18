# shellcheck shell=sh
# netwatch.sh - decides between normal networking and the setup access
# point, and switches between them
# Part of m17-hotspot-os. Used by m17os-netwatch (the service) and
# m17os-setup-ap (by hand); tests replace the nw_* actions.
#
# Modes (in $NW_RUN/mode):
#   client  normal: wpa_supplicant and dhcpcd, Ethernet if plugged in
#   ap      the open "M17-Setup-XXXX" access point on wlan0, at
#           $NW_AP_ADDR, with DHCP and DNS (every name -> this hotspot)
#           from dnsmasq, so phones open the setup wizard
#
# Requests (files in $NW_RUN, made by m17os-setup-ap and the admin helper):
#   request-ap    start the access point now
#   request-join  leave it and join the configured WiFi

: "${NW_RUN:=/run/m17os}"
: "${NW_IFACE:=wlan0}"
: "${NW_AP_ADDR:=192.168.4.1}"
: "${NW_WPA_CONF:=/etc/wpa_supplicant/wpa_supplicant.conf}"
: "${NW_BOOT_GRACE:=90}"   # no network this long after start -> AP
: "${NW_LOST_GRACE:=300}"  # network lost this long -> AP
: "${NW_JOIN_WAIT:=60}"    # how long to wait for WiFi after leaving the AP
: "${NW_RETRY:=600}"       # with the AP idle, try the saved WiFi this often
: "${NW_POLL:=5}"

nw_log() {
	logger -t m17os-netwatch -p daemon.notice "$*" 2>/dev/null || true
	slot_event "netwatch: $*" 2>/dev/null || true
}

# ── Actions (tests replace these) ─────────────────────────────────────

nw_now() { date +%s; }
nw_sleep() { sleep "$1"; }

# nw_online - some interface has a usable IPv4 address (not the AP's)
nw_online() {
	ip -4 -o addr show scope global 2>/dev/null | grep ' inet ' |
		grep -v " inet 169\.254\." | grep -qv " inet $NW_AP_ADDR/"
}

# nw_have_saved - WiFi networks are configured
nw_have_saved() {
	grep -q '^[[:space:]]*network[[:space:]]*=' "$NW_WPA_CONF" 2>/dev/null
}

# nw_ap_clients - number of devices connected to the access point: the
# MAC addresses hostapd lists (its error messages contain ':' too)
nw_ap_clients() {
	hostapd_cli -p "$NW_RUN/hostapd" -i "$NW_IFACE" list_sta 2>/dev/null |
		grep -ciE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
}

# nw_service ACTION NAME - start or stop one service without its
# dependents. dhcpcd provides OpenRC's "net": stopping it the usual way
# also stops everything that needs the network (nginx, dropbear, ntpd),
# which would take the setup wizard down with it.
nw_service() {
	rc-service --nodeps "$2" "$1" >/dev/null 2>&1
}

# nw_country - the WiFi country, for the access point
nw_country() {
	c=$(sed -n 's/^country=\([A-Z][A-Z]\).*/\1/p' "$NW_WPA_CONF" 2>/dev/null | head -1)
	echo "${c:-US}"
}

# nw_ssid - M17-Setup-XXXX, from the end of wlan0's MAC address
nw_ssid() {
	mac=$(cat "/sys/class/net/$NW_IFACE/address" 2>/dev/null | tr -d ':' | tr '[:lower:]' '[:upper:]')
	echo "M17-Setup-$(echo "${mac:-0000}" | tail -c 5)"
}

# nw_scan - save the networks in range for the wizard (the radio can't
# scan while it's an access point), in the admin helper's format
nw_scan() {
	mkdir -p "$NW_RUN"
	if wpa_cli -i "$NW_IFACE" scan >/dev/null 2>&1; then
		sleep 4
		wpa_cli -i "$NW_IFACE" scan_results 2>/dev/null |
			awk -F '\t' 'NR > 1 && NF >= 5 { print $3 "\t" $2 "\t" $4 "\t" $5 }' > "$NW_RUN/wifi-scan.tmp" &&
			mv "$NW_RUN/wifi-scan.tmp" "$NW_RUN/wifi-scan"
	fi
}

# nw_write_configs - hostapd's and dnsmasq's configuration for the AP
nw_write_configs() {
	mkdir -p "$NW_RUN/hostapd"
	cat > "$NW_RUN/hostapd.conf" <<EOF
interface=$NW_IFACE
driver=nl80211
ctrl_interface=$NW_RUN/hostapd
ssid=$(nw_ssid)
country_code=$(nw_country)
ieee80211d=1
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
EOF
	cat > "$NW_RUN/dnsmasq.conf" <<EOF
interface=$NW_IFACE
bind-interfaces
listen-address=$NW_AP_ADDR
dhcp-range=${NW_AP_ADDR%.*}.10,${NW_AP_ADDR%.*}.100,255.255.255.0,10m
dhcp-option=option:router,$NW_AP_ADDR
dhcp-option=option:dns-server,$NW_AP_ADDR
# RFC 8910: tells newer phones where the captive portal is
dhcp-option=114,http://$NW_AP_ADDR/setup/
dhcp-leasefile=$NW_RUN/dnsmasq.leases
# Every name is this hotspot, so any page a phone opens leads to setup
address=/#/$NW_AP_ADDR
no-resolv
no-hosts
EOF
}

nw_ap_start() {
	nw_scan
	nw_write_configs
	nw_service stop wpa_supplicant
	nw_service stop dhcpcd
	ip addr flush dev "$NW_IFACE" 2>/dev/null
	ip link set "$NW_IFACE" up
	ip addr add "$NW_AP_ADDR/24" dev "$NW_IFACE"
	hostapd -B -P "$NW_RUN/hostapd.pid" "$NW_RUN/hostapd.conf" >/dev/null 2>&1 || return 1
	dnsmasq --conf-file="$NW_RUN/dnsmasq.conf" --pid-file="$NW_RUN/dnsmasq.pid" || return 1
}

nw_ap_stop() {
	for p in hostapd dnsmasq; do
		[ -f "$NW_RUN/$p.pid" ] && kill "$(cat "$NW_RUN/$p.pid")" 2>/dev/null
		rm -f "$NW_RUN/$p.pid"
	done
	ip addr flush dev "$NW_IFACE" 2>/dev/null
}

nw_client_start() {
	nw_service start wpa_supplicant
	nw_service start dhcpcd
	# Anything in the default runlevel that isn't running (stopped by an
	# older version, or crashed while the network was away): start it
	openrc default >/dev/null 2>&1
}

# ── The state machine ─────────────────────────────────────────────────

nw_mode() { cat "$NW_RUN/mode" 2>/dev/null || echo client; }
nw_set_mode() { mkdir -p "$NW_RUN"; echo "$1" > "$NW_RUN/mode"; }

# nw_to_ap REASON
nw_to_ap() {
	nw_log "starting the setup access point $(nw_ssid): $1"
	if nw_ap_start; then
		nw_set_mode ap
		NW_AP_SINCE=$(nw_now)
	else
		nw_log "the setup access point failed to start"
		nw_ap_stop
		nw_client_start
		nw_set_mode client
	fi
}

# nw_try_join REASON - leave the AP and wait for the WiFi; back to the AP
# if it doesn't connect. Returns 0 if online.
nw_try_join() {
	nw_log "leaving the setup access point to join the WiFi: $1"
	nw_ap_stop
	nw_client_start
	nw_set_mode client
	waited=0
	while [ "$waited" -lt "$NW_JOIN_WAIT" ]; do
		if nw_online; then
			nw_log "connected"
			rm -f "$NW_RUN/join-failed"
			return 0
		fi
		nw_sleep "$NW_POLL"
		waited=$((waited + NW_POLL))
	done
	nw_log "couldn't connect within ${NW_JOIN_WAIT}s"
	date '+%Y-%m-%d %H:%M:%S' > "$NW_RUN/join-failed"
	nw_to_ap "the WiFi didn't connect"
	return 1
}

# nw_loop [ITERATIONS] - watch forever (or ITERATIONS polls, for tests)
nw_loop() {
	max="${1:-0}"
	i=0
	start=$(nw_now)
	ever_online=false
	offline_since=""
	NW_AP_SINCE=$(nw_now)
	# A restarted watcher starts again from normal networking
	if [ "$(nw_mode)" = ap ]; then
		nw_ap_stop
		nw_client_start
	fi
	nw_set_mode client
	while [ "$max" -eq 0 ] || [ "$i" -lt "$max" ]; do
		i=$((i + 1))
		now=$(nw_now)
		if [ "$(nw_mode)" = ap ]; then
			if [ -f "$NW_RUN/request-join" ]; then
				rm -f "$NW_RUN/request-join"
				nw_try_join "new WiFi settings" && { ever_online=true; offline_since=""; }
			elif nw_have_saved && [ $((now - NW_AP_SINCE)) -ge "$NW_RETRY" ] && [ "$(nw_ap_clients)" -eq 0 ]; then
				nw_try_join "retrying the saved WiFi" && { ever_online=true; offline_since=""; }
				NW_AP_SINCE=$(nw_now)
			fi
		else
			rm -f "$NW_RUN/request-join"
			if [ -f "$NW_RUN/request-ap" ]; then
				rm -f "$NW_RUN/request-ap"
				nw_to_ap "requested"
			elif nw_online; then
				ever_online=true
				offline_since=""
			else
				[ -n "$offline_since" ] || offline_since=$now
				if ! $ever_online && [ $((now - start)) -ge "$NW_BOOT_GRACE" ]; then
					nw_to_ap "no network ${NW_BOOT_GRACE}s after boot"
				elif $ever_online && [ $((now - offline_since)) -ge "$NW_LOST_GRACE" ]; then
					nw_to_ap "the network was lost ${NW_LOST_GRACE}s ago"
					offline_since=""
				fi
			fi
		fi
		nw_sleep "$NW_POLL"
	done
}
