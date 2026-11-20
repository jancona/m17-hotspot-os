#!/bin/sh
# smoke-rootfs.sh - set up the m17-hotspot-os root filesystem inside a
# throwaway Alpine container and check that it works as far as a container
# allows (no boot, kernel or hardware).
#
# Run with tests/run-smoke.sh, which starts the container. DO NOT run this
# on a real system: it rewrites /etc.

set -u

[ -f /.dockerenv ] || [ -n "${M17OS_SMOKE_OK:-}" ] || {
	echo "Refusing to run outside a container" >&2; exit 2; }

REPO=/repo
. "$REPO/build.conf"

: > /tmp/pass
: > /tmp/fail
ok()   { echo . >> /tmp/pass; }
fail() { echo . >> /tmp/fail; echo "FAIL: $*"; }
check() { if [ "$2" = "$3" ]; then ok; else fail "$1: expected '$2', got '$3'"; fi; }
section() { echo; echo "── $* ──"; }

section "Build tools"
apk add --no-cache curl rsync socat busybox-extras >/dev/null || { echo "apk add failed"; exit 1; }

section "Apply overlay and run setup-rootfs.sh"
rsync -a --chown=root:root "$REPO/overlay/" /
mkdir -p /boot/firmware/overlays
# As build-image.sh does: the M17 package repository's pinned key
install -m 0644 "$REPO/keys/m17-apk.rsa.pub" /etc/apk/keys/m17-apk.rsa.pub
env ALPINE_VERSION="$ALPINE_VERSION" RASPINE_REPO="$RASPINE_REPO" M17_APK_REPO="$M17_APK_REPO" \
	DEFAULT_HOSTNAME="$DEFAULT_HOSTNAME" DEFAULT_USER="$DEFAULT_USER" \
	DEFAULT_PASSWORD="$DEFAULT_PASSWORD" DEFAULT_WIFI_COUNTRY="$DEFAULT_WIFI_COUNTRY" \
	sh -e "$REPO/scripts/setup-rootfs.sh" > /tmp/setup.log 2>&1
rc=$?
tail -5 /tmp/setup.log
if [ "$rc" -ne 0 ]; then
	echo "setup-rootfs.sh failed ($rc):"; tail -40 /tmp/setup.log; exit 1
fi

section "Packages and boot files"
for p in raspios-kernel-v8 raspios-kernel-2712 raspios-firmware nginx php84-fpm doas minisign avahi stm32flash \
	m17-gateway m17-gateway-openrc rpi-dashboard m17-firmware-cc1200 m17-firmware-mmdvm-hs \
	m17-firmware-mmdvm m17-sx1255-overlay m17-admin m17-admin-openrc; do
	apk info -e "$p" >/dev/null && ok || fail "package $p not installed"
done
for f in kernel8.img kernel_2712.img cmdline.txt overlays/genericstereoaudiocodec.dtbo; do
	[ -e "/boot/firmware/$f" ] && ok || fail "/boot/firmware/$f missing"
done
ls /boot/firmware/start*.elf >/dev/null 2>&1 && ok || fail "GPU firmware (start*.elf) missing"
ls /boot/firmware/bcm2710-rpi-zero-2-w.dtb /boot/firmware/bcm2712-rpi-5-b.dtb >/dev/null 2>&1 && ok || \
	fail "device trees for Zero 2 W / Pi 5 missing"
[ -L /lib/modules ] && [ -n "$(ls -A /lib/modules/)" ] && ok || fail "/lib/modules not populated"

section "Services"
for s in m17os-data-resize m17os-varlog m17os-clock m17os-bindmounts m17os-config m17os-boot-watchdog wpa_supplicant dhcpcd; do
	[ -L "/etc/runlevels/boot/$s" ] && ok || fail "$s not in boot runlevel"
done
for s in dropbear crond ntpd avahi-daemon php-fpm84 nginx m17-gateway m17os-health-check; do
	[ -L "/etc/runlevels/default/$s" ] && ok || fail "$s not in default runlevel"
done

getent passwd ntp >/dev/null && ok || fail "no ntp user for the ntpd service"
[ -x /usr/lib/ssh/sftp-server ] && ok || fail "no sftp-server, so scp to the hotspot fails"
grep -q 'rc-service ntpd status' /usr/lib/dhcpcd/dhcpcd-hooks/30-time-sync && ok || fail "time-sync hook not updated"

section "Users and permissions"
id m17 | grep -q wheel && ok || fail "m17 not in wheel"
id m17-gateway | grep -q dialout && id m17-gateway | grep -q spi && id m17-gateway | grep -q gpio && ok || \
	fail "m17-gateway groups: $(id m17-gateway)"
id www-data | grep -q m17-gateway-control && ok || fail "www-data not in m17-gateway-control"
grep -q '^root:!' /etc/shadow && ok || fail "root not locked"
grep -q 'ttyAMA\[0-9\]\*.*root:dialout' /etc/mdev.conf && ok || fail "mdev rule for ttyAMA missing"

section "Gateway"
/opt/m17/m17-gateway/m17-gateway -h > /tmp/gw-help 2>&1
grep -qi 'config' /tmp/gw-help && ok || fail "m17-gateway -h: $(head -3 /tmp/gw-help)"
check "ini symlink" "m17-gateway/m17-gateway.ini" "$(readlink /etc/m17-gateway.ini)"
. /usr/local/lib/m17os/ini.sh
check "DashboardLog" /data/log/m17-gateway/dashboard.log "$(ini_get /etc/m17-gateway.ini General DashboardLog)"
check "dashboard log link" /data/log/m17-gateway/dashboard.log "$(readlink /var/lib/m17-dashboard/files/dashboard.log)"
check "HostFile" /var/lib/m17-gateway/M17Hosts.txt "$(ini_get /etc/m17-gateway.ini Reflector HostFile)"
grep -q "$M17_APK_REPO/v$ALPINE_VERSION/m17" /etc/apk/repositories && ok || fail "m17-apk repository not configured"
[ -f /usr/share/m17-firmware/mmdvm_hs/MMDVM_HS_Dual_Hat.bin ] && ok || fail "MMDVM_HS firmware missing"
su -s /bin/sh www-data -c 'test -w /var/lib/m17-gateway/M17Hosts.txt' && ok || fail "www-data cannot update the host file"
check "Log level" INFO "$(ini_get /etc/m17-gateway.ini Log Level)"
[ -s /opt/m17/rpi-dashboard/files/M17Hosts.txt ] && ok || fail "host file not reachable through the dashboard"
su -s /bin/sh www-data -c 'test -w /etc/m17-gateway.ini' && ok || fail "www-data cannot write the gateway ini"
su -s /bin/sh www-data -c 'test -w /opt/m17/rpi-dashboard/index.php' && fail "www-data can write dashboard code" || ok

section "Web dashboard (nginx + php-fpm)"
nginx -t 2>/tmp/nginx-t && ok || fail "nginx -t: $(cat /tmp/nginx-t)"
php-fpm84 -t 2>/tmp/fpm-t && ok || fail "php-fpm84 -t: $(cat /tmp/fpm-t)"
mkdir -p /var/log/m17-gateway /run/nginx
chown m17-gateway:m17-gateway /var/log/m17-gateway
php-fpm84 -D && nginx && sleep 1
wget -q -O /tmp/index.html http://127.0.0.1/index.php && ok || fail "dashboard index.php did not load"
grep -qi 'm17' /tmp/index.html && ok || fail "index.php does not look like the dashboard"
wget -q -O /dev/null http://127.0.0.1/files/M17Hosts.txt && fail "files/ is served" || ok
wget -q -O /dev/null http://127.0.0.1/config.php && fail "config.php is served" || ok
grep -q "admin_password_hash" /var/lib/m17-dashboard/config.php && ok || fail "dashboard did not write its config.php"
[ -L /opt/m17/rpi-dashboard/config.php ] && ok || fail "config.php symlink was replaced"
/etc/m17os/health.d/60-dashboard >/dev/null 2>&1; check "dashboard health hook" 0 "$?"

section "systemctl stand-in (as www-data, through doas)"
out=$(su -s /bin/sh www-data -c 'PATH=/usr/local/bin:/usr/bin:/bin; systemctl bogus 2>&1'); rc=$?
check "unsupported action fails" 1 "$rc"
out=$(su -s /bin/sh www-data -c 'PATH=/usr/local/bin:/usr/bin:/bin; systemctl restart nginx.service 2>&1'); rc=$?
check "other units refused" 1 "$rc"
out=$(su -s /bin/sh www-data -c 'doas -n /bin/sh -c id 2>&1'); rc=$?
[ "$rc" -ne 0 ] && ok || fail "www-data can run arbitrary commands through doas: $out"
out=$(su -s /bin/sh www-data -c 'doas -n /usr/local/libexec/m17os/service-control bogus 2>&1'); rc=$?
case "$out" in *"not allowed"*) ok ;; *) fail "doas rule for service-control: $out" ;; esac
check "doas.d permissions" 600 "$(stat -c %a /etc/doas.d/m17os.conf)"

section "m17os-config (boot configuration file)"
cat > /boot/firmware/m17-config.txt <<'EOF'
# test
hostname=test-hotspot
timezone=America/New_York
user_password=secret-pass
enable_ssh_password=true
ssh_key=ssh-ed25519 AAAATEST test@example
wifi_ssid=HomeNet
wifi_password=homepassword
wifi_ssid_2=Phone
wifi_password_2=phonepassword
wifi_country=GB
callsign=n0call b
hat=cc1200
frequency=439.5
tx_frequency=434750000
duplex=false
power=12
rf_level=40
reflector=M17-XOR
module=b
dashboard_password=dashpass123
EOF
printf 'hostname=test-hotspot\r\n' >> /boot/firmware/m17-config.txt
mkdir -p /data/m17os /etc/conf.d
echo 'DROPBEAR_OPTS="-B -s"' > /etc/conf.d/dropbear
cp "$REPO/boot/config.txt" /boot/firmware/config.txt
sh /usr/local/bin/m17os-config > /tmp/config.log 2>&1
check "m17os-config exit" 0 "$?"
[ -e /boot/firmware/m17-config.txt ] && fail "m17-config.txt not deleted" || ok
check "hostname" test-hotspot "$(cat /etc/hostname)"
check "timezone" America/New_York "$(cat /etc/timezone)"
grep -q 'DROPBEAR_OPTS="-B"' /etc/conf.d/dropbear && ok || fail "ssh password not enabled"
grep -q 'AAAATEST' /home/m17/.ssh/authorized_keys && ok || fail "ssh key not added"
check "wifi country" GB "$(sed -n 's/^country=//p' /etc/wpa_supplicant/wpa_supplicant.conf)"
check "wifi networks" 2 "$(grep -c 'ssid=' /etc/wpa_supplicant/wpa_supplicant.conf)"
grep -q 'priority=2' /etc/wpa_supplicant/wpa_supplicant.conf && ok || fail "wifi priority missing"
grep -q '#psk=' /etc/wpa_supplicant/wpa_supplicant.conf && fail "plaintext WiFi password kept" || ok
check "callsign" "N0CALL B" "$(ini_get /etc/m17-gateway.ini General Callsign)"
check "rx frequency" 439500000 "$(ini_get /etc/m17-gateway.ini Radio RXFrequency)"
check "tx frequency" 434750000 "$(ini_get /etc/m17-gateway.ini Radio TXFrequency)"
check "power" 12 "$(ini_get /etc/m17-gateway.ini Radio Power)"
check "rf level" 40 "$(ini_get /etc/m17-gateway.ini Modem RFLevel)"
check "reflector" M17-XOR "$(ini_get /etc/m17-gateway.ini Reflector Name)"
check "module" B "$(ini_get /etc/m17-gateway.ini Reflector Module)"
check "modem type" cc1200 "$(ini_get /etc/m17-gateway.ini Modem Type)"
check "ini still a symlink" "m17-gateway/m17-gateway.ini" "$(readlink /etc/m17-gateway.ini)"
check "ini owner" "m17-gateway:m17-gateway-control" "$(stat -c %U:%G /etc/m17-gateway/m17-gateway.ini)"
grep -q "admin_password_hash' => '[$]" /var/lib/m17-dashboard/config.php && ok || \
	fail "dashboard password not set: $(grep -i password /tmp/config.log)"
grep -q '^user_password_hash=\$' /data/m17os/user.conf && ok || fail "password hash not saved"
check "user.conf mode" 600 "$(stat -c %a /data/m17os/user.conf)"
grep -q 'secret-pass\|homepassword\|dashpass123' /data/m17os/user.conf /data/m17os/config.log && \
	fail "a plaintext password was saved or logged" || ok

section "m17os-config: problems are reported, passwords are not"
before=$(grep "admin_password_hash" /var/lib/m17-dashboard/config.php)
printf 'dashboard_password=short7\ndashbord_password=misspelled-secret\ncallsign=bad*call\nrf_level=150\n' > /boot/firmware/m17-config.txt
sh /usr/local/bin/m17os-config > /tmp/warn.log 2>&1
check "warnings exit" 0 "$?"
check "short password left the old one" "$before" "$(grep "admin_password_hash" /var/lib/m17-dashboard/config.php)"
grep -q 'config: dashboard_password not set: it must be at least 8 characters (it has 6)' /data/log/m17os-events.log && ok || \
	fail "short password not in the event log: $(tail -3 /data/log/m17os-events.log)"
grep -q "config: unknown setting 'dashbord_password'" /data/log/m17os-events.log && ok || fail "unknown key not reported"
grep -q "config: invalid callsign 'BAD\*CALL'" /data/log/m17os-events.log && ok || fail "bad callsign not reported"
grep -q "config: rf_level must be 0 to 100" /data/log/m17os-events.log && ok || fail "bad rf_level not reported"
check "bad rf_level left the old one" 40 "$(ini_get /etc/m17-gateway.ini Modem RFLevel)"
grep -q 'WARNING: dashboard_password not set' /data/m17os/config.log && ok || fail "short password not in config.log"
grep -q 'short7\|misspelled-secret' /data/log/m17os-events.log /data/m17os/config.log && fail "a password reached a log" || ok
[ -f /boot/firmware/slot.conf ] || cp "$REPO/boot/slot.conf" /boot/firmware/slot.conf
m17os_info=$(/usr/local/bin/m17os-slot-info)
case "$m17os_info" in *"unknown setting 'dashbord_password'"*) ok ;; *) fail "m17os-slot-info doesn't show config problems" ;; esac

section "m17os-config: HAT change needs a reboot"
printf 'hat=sx1255\n' > /boot/firmware/m17-config.txt
sh /usr/local/bin/m17os-config > /tmp/config2.log 2>&1
check "exit 3 for reboot" 3 "$?"
grep -q '^dtoverlay=genericstereoaudiocodec' /boot/firmware/config.txt && ok || fail "SX1255 overlay not enabled"

section "m17os-config: MMDVM speed, and modem_speed wins wherever it is"
printf 'hat=mmdvm\n' > /boot/firmware/m17-config.txt
sh /usr/local/bin/m17os-config > /tmp/config2b.log 2>&1
check "mmdvm type" mmdvm "$(ini_get /etc/m17-gateway.ini Modem Type)"
check "mmdvm default speed" 115200 "$(ini_get /etc/m17-gateway.ini Modem Speed)"
printf 'modem_speed=460800\nhat=cc1200\n' > /boot/firmware/m17-config.txt
sh /usr/local/bin/m17os-config > /tmp/config2c.log 2>&1
printf 'modem_speed=57600\nhat=mmdvm\n' > /boot/firmware/m17-config.txt
sh /usr/local/bin/m17os-config > /tmp/config2d.log 2>&1
check "modem_speed before hat wins" 57600 "$(ini_get /etc/m17-gateway.ini Modem Speed)"
check "ini owner after edits" "m17-gateway:m17-gateway-control" "$(stat -c %U:%G /etc/m17-gateway/m17-gateway.ini)"

section "m17os-config: saved settings restore the password on a new slot"
hash=$(sed -n 's/^user_password_hash=//p' /data/m17os/user.conf)
echo "m17:changed" | chpasswd
rm -f /etc/.m17os-password-restored
sh /usr/local/bin/m17os-config > /tmp/config3.log 2>&1
check "restored hash" "$hash" "$(sed -n 's/^m17:\([^:]*\):.*/\1/p' /etc/shadow)"
echo "m17:changed-again" | chpasswd
sh /usr/local/bin/m17os-config > /tmp/config4.log 2>&1
check "changed hash saved" "$(sed -n 's/^m17:\([^:]*\):.*/\1/p' /etc/shadow)" "$(sed -n 's/^user_password_hash=//p' /data/m17os/user.conf)"

section "Boot with an empty /var/log (it is a tmpfs on the Pi)"
grep -q ' /var/log/nginx$' /etc/m17os/var-log-dirs && ok || fail "var-log-dirs has no /var/log/nginx"
grep -q ' /var/log/php84$' /etc/m17os/var-log-dirs && ok || fail "var-log-dirs has no /var/log/php84"
[ -L /etc/runlevels/boot/m17os-varlog ] && ok || fail "m17os-varlog not in boot runlevel"
nginx -s stop 2>/dev/null; pkill php-fpm84 2>/dev/null; sleep 1
mv /var/log /var/log.saved && mkdir /var/log
nginx -t >/dev/null 2>&1 && fail "nginx -t passes without /var/log/nginx: the test can't show the fix" || ok
( ebegin() { :; }; eend() { return "${1:-0}"; }; . /etc/init.d/m17os-varlog; start ) \
	&& ok || fail "m17os-varlog start failed"
check "nginx log dir owner" "$(awk '$3 == "/var/log/nginx" { print $2 }' /etc/m17os/var-log-dirs)" "$(stat -c %U:%G /var/log/nginx)"
nginx -t 2>/tmp/nginx-t2 && ok || fail "nginx -t after m17os-varlog: $(cat /tmp/nginx-t2)"
php-fpm84 -t 2>/tmp/fpm-t2 && ok || fail "php-fpm84 -t after m17os-varlog: $(cat /tmp/fpm-t2)"
mkdir -p /run/nginx
php-fpm84 -D && nginx && sleep 1
wget -q -O /dev/null http://127.0.0.1/index.php && ok || fail "dashboard did not load after m17os-varlog"
rm -rf /var/log && mv /var/log.saved /var/log

section "Migration from the pre-package layout"
# Older images: real host files in the dashboard's files/, gateway pointed there
D=/var/lib/m17-dashboard/files
rm -f "$D/M17Hosts.txt" "$D/OverrideHosts.txt"
echo "M17-OLD 192.0.2.1 17000" > "$D/M17Hosts.txt"
echo "M17-MINE 192.0.2.2 17000" > "$D/OverrideHosts.txt"
chown www-data:www-data "$D"/*.txt
ini_set /etc/m17-gateway.ini Reflector HostFile /opt/m17/rpi-dashboard/files/M17Hosts.txt
ini_set /etc/m17-gateway.ini Reflector OverrideHostFile /opt/m17/rpi-dashboard/files/OverrideHosts.txt
rm -f /boot/firmware/m17-config.txt
sh /usr/local/bin/m17os-config > /tmp/migrate.log 2>&1
check "migration exit" 0 "$?"
[ -L "$D/OverrideHosts.txt" ] && [ -L "$D/M17Hosts.txt" ] && ok || fail "dashboard host files not replaced by symlinks"
grep -q 'M17-MINE' /var/lib/m17-gateway/OverrideHosts.txt && ok || fail "user's OverrideHosts.txt not kept"
grep -q 'M17-MINE' /opt/m17/rpi-dashboard/files/OverrideHosts.txt && ok || fail "dashboard doesn't see the override file"
check "HostFile migrated" /var/lib/m17-gateway/M17Hosts.txt "$(ini_get /etc/m17-gateway.ini Reflector HostFile)"
check "OverrideHostFile migrated" /var/lib/m17-gateway/OverrideHosts.txt "$(ini_get /etc/m17-gateway.ini Reflector OverrideHostFile)"
check "migrated owner" "m17-gateway:m17-gateway-control" "$(stat -c %U:%G /var/lib/m17-gateway/OverrideHosts.txt)"
sh /usr/local/bin/m17os-config > /tmp/migrate2.log 2>&1
grep -q 'Moved' /tmp/migrate2.log && fail "migration ran a second time" || ok

section "Dashboard log on /data, and moving older hotspots there"
# The first m17os-config runs above created the directory
check "dashboard log dir owner" m17-gateway:m17-gateway "$(stat -c %U:%G /data/log/m17-gateway)"
check "dashboard log owner" m17-gateway:m17-gateway "$(stat -c %U:%G /data/log/m17-gateway/dashboard.log)"
echo '{"time":"x","type":"Gateway","subtype":"Start"}' >> /data/log/m17-gateway/dashboard.log
# An older hotspot: log on the tmpfs, dashboard linked there
ini_set /etc/m17-gateway.ini General DashboardLog /var/log/m17-gateway/dashboard.log
ln -sfn /var/log/m17-gateway/dashboard.log /var/lib/m17-dashboard/files/dashboard.log
sh /usr/local/bin/m17os-config > /tmp/dashlog.log 2>&1
check "DashboardLog moved" /data/log/m17-gateway/dashboard.log "$(ini_get /etc/m17-gateway.ini General DashboardLog)"
check "dashboard link moved" /data/log/m17-gateway/dashboard.log "$(readlink /var/lib/m17-dashboard/files/dashboard.log)"
grep -q '"subtype":"Start"' /data/log/m17-gateway/dashboard.log && ok || fail "existing dashboard log content lost"
# A path the user chose is left alone
ini_set /etc/m17-gateway.ini General DashboardLog /home/m17/my-dashboard.log
sh /usr/local/bin/m17os-config > /tmp/dashlog2.log 2>&1
check "custom DashboardLog kept" /home/m17/my-dashboard.log "$(ini_get /etc/m17-gateway.ini General DashboardLog)"
ini_set /etc/m17-gateway.ini General DashboardLog /data/log/m17-gateway/dashboard.log

section "Running gateway is found (dashboard status, health hook)"
socat pty,link=/tmp/ttyV0,raw,mode=666 pty,link=/tmp/ttyV1,raw & SOCAT=$!
sleep 1
chmod 666 "$(readlink -f /tmp/ttyV0)"
sed -e 's/^Callsign=.*/Callsign=N0CALL/' -e 's|^Type=.*|Type=mmdvm|' -e 's|^Port=.*|Port=/tmp/ttyV0|' \
	/etc/m17-gateway.ini > /tmp/gw-test.ini
chmod 644 /tmp/gw-test.ini
su -s /bin/sh m17-gateway -c 'cd /opt/m17/m17-gateway && exec ./m17-gateway -config /tmp/gw-test.ini' >/tmp/gw-test.log 2>&1 &
GW=$!
sleep 2
kill -0 "$GW" 2>/dev/null && ok || fail "test gateway exited: $(tail -2 /tmp/gw-test.log)"
check "pgrep is procps" /usr/bin/pgrep "$(readlink -f "$(command -v pgrep)")"
su -s /bin/sh www-data -c 'pgrep -x m17-gateway' >/dev/null && ok || fail "pgrep -x (as the dashboard) does not find the gateway"
pidof m17-gateway >/dev/null && ok || fail "pidof does not find the gateway"
wget -q -O /tmp/status.json http://127.0.0.1/get_status.php && ok || fail "get_status.php failed"
grep -q '"gateway_status":"Running"' /tmp/status.json && ok || fail "dashboard status: $(head -c 200 /tmp/status.json)"
kill "$GW" "$SOCAT" 2>/dev/null

section "Signed releases (m17os-upgrade --check)"
REL=/tmp/release
mkdir -p "$REL" /tmp/keys /tmp/upg
(cd /tmp/keys && minisign -G -W -p good.pub -s good.key >/dev/null && minisign -G -W -p other.pub -s other.key >/dev/null)
echo "not really a rootfs" > "$REL/fake.rootfs.tar.xz"
cat > "$REL/manifest.txt" <<EOF
VERSION=2099.1.1.1
BUILD_DATE=2099-01-01
ARCH=$(apk --print-arch)
ROOTFS_FILENAME=fake.rootfs.tar.xz
ROOTFS_SHA256=$(sha256sum "$REL/fake.rootfs.tar.xz" | cut -d' ' -f1)
EOF
minisign -S -s /tmp/keys/good.key -m "$REL/manifest.txt" -x "$REL/manifest.txt.minisig" >/dev/null
busybox-extras httpd -p 127.0.0.1:8099 -h "$REL"
sleep 1
wget -q -O /dev/null http://127.0.0.1:8099/manifest.txt && ok || fail "test web server not answering"
printf 'ACTIVE_SLOT=A\nPREVIOUS_SLOT=\nPENDING=false\nBOOT_TRIES=0\nSLOT_A_VERSION="2026.1.1.1"\nSLOT_B_VERSION=\n' > /boot/firmware/slot.conf
upg() { # upg PUBKEY - run --check against the test release with PUBKEY ("" = none)
	sed -e 's|^UPDATE_URL=.*|UPDATE_URL="http://127.0.0.1:8099"|' \
	    -e "s|^RELEASE_PUBKEY=.*|RELEASE_PUBKEY=\"$1\"|" /etc/m17os/m17os.conf > /tmp/upg/m17os.conf
	M17OS_CONF=/tmp/upg/m17os.conf M17OS_TMP=/tmp/upg/dl M17OS_RELEASE=/nonexistent \
		sh /usr/local/bin/m17os-upgrade --check > /tmp/upg/out 2>&1
	echo $?
}
check "signed release accepted" 0 "$(upg /tmp/keys/good.pub)"
grep -q 'Signed:     true' /tmp/upg/out && ok || fail "signed release not reported as signed: $(cat /tmp/upg/out)"
check "no key: unsigned check still works" 0 "$(upg "")"
check "wrong key rejected" 2 "$(upg /tmp/keys/other.pub)"
grep -q 'signature is not valid' /tmp/upg/out && ok || fail "wrong key message: $(cat /tmp/upg/out)"
cp "$REL/manifest.txt" /tmp/upg/manifest.orig
sed -i 's/^ROOTFS_SHA256=.*/ROOTFS_SHA256=0000000000000000000000000000000000000000000000000000000000000000/' "$REL/manifest.txt"
check "tampered manifest rejected" 2 "$(upg /tmp/keys/good.pub)"
grep -q 'signature is not valid' /tmp/upg/out && ok || fail "tampered manifest message: $(cat /tmp/upg/out)"
cp /tmp/upg/manifest.orig "$REL/manifest.txt"
rm "$REL/manifest.txt.minisig"
check "missing signature rejected" 2 "$(upg /tmp/keys/good.pub)"
grep -q 'failed to fetch the manifest signature' /tmp/upg/out && ok || fail "missing signature message: $(cat /tmp/upg/out)"
pkill -f 'httpd -p 127.0.0.1:8099' 2>/dev/null

section "m17os-config --apply (for the setup wizard)"
echo test-hotspot-keep > /etc/hostname
rm -f /data/m17os/user.conf
out=$(printf 'callsign=n0call\nreflector=none\ncallsign=bad*call\nwifi_country=GB\nwifi_ssid=WizardNet\nwifi_password=wizardpass1\n' |
	sh /usr/local/bin/m17os-config --apply)
check "apply exit" 0 "$?"
case "$out" in *"warning: invalid callsign 'BAD*CALL'"*) ok ;; *) fail "apply warning: $out" ;; esac
case "$out" in *"network: true"*) ok ;; *) fail "apply network flag: $out" ;; esac
case "$out" in *"gateway: true"*) ok ;; *) fail "apply gateway flag: $out" ;; esac
case "$out" in *"reboot: false"*) ok ;; *) fail "apply reboot flag: $out" ;; esac
case "$out" in *"["*) fail "log lines leaked into the apply result: $out" ;; *) ok ;; esac
check "apply: reflector none" "" "$(ini_get /etc/m17-gateway.ini Reflector Name)"
check "apply: callsign" "N0CALL" "$(ini_get /etc/m17-gateway.ini General Callsign)"
grep -q 'ssid="WizardNet"' /etc/wpa_supplicant/wpa_supplicant.conf && ok || fail "apply: WiFi not written"
grep -q '^hostname=test-hotspot-keep$' /data/m17os/user.conf && ok || \
	fail "a partial update blanked the saved hostname: $(grep hostname /data/m17os/user.conf)"
# The same for m17-config.txt: a file without hostname keeps the saved one
printf 'callsign=N0CALL\n' > /boot/firmware/m17-config.txt
sh /usr/local/bin/m17os-config > /tmp/partial.log 2>&1
grep -q '^hostname=test-hotspot-keep$' /data/m17os/user.conf && ok || fail "m17-config.txt without hostname blanked it"
out=$(printf 'hat=sx1255\n' | sh /usr/local/bin/m17os-config --apply)
case "$out" in *"reboot: true"*) ok ;; *) fail "apply reboot flag for SX1255: $out" ;; esac
printf 'hat=cc1200\n' | sh /usr/local/bin/m17os-config --apply >/dev/null
ini_set /etc/m17-gateway.ini Reflector Name M17-M17

section "Admin helper, run by m17-admin through doas"
adduser -S -D -H -s /sbin/nologin m17-admin 2>/dev/null
helper=/usr/local/libexec/m17os/admin-helper
as_admin() { su -s /bin/sh m17-admin -c "$*"; }
out=$(as_admin "doas -n $helper wifi-configured" 2>&1)
check "helper: configured networks" "country=GB ssid=WizardNet" "$(echo $out)"
printf 'AUTO_UPDATE=notify\nUPDATE_HOUR=4\nevil=$(id)\n' > /var/lib/m17os/autoupdate.conf
out=$(as_admin "doas -n $helper update-policy" 2>&1)
check "helper: update policy" "AUTO_UPDATE=notify UPDATE_HOUR=4" "$(echo $out)"
rm -f /var/lib/m17os/autoupdate.conf
out=$(printf 'module=d\n' | as_admin "doas -n $helper apply" 2>&1); rc=$?
check "helper apply exit" 0 "$rc"
case "$out" in *"gateway: true"*) ok ;; *) fail "helper apply: $out" ;; esac
check "helper apply: module" "D" "$(ini_get /etc/m17-gateway.ini Reflector Module)"
# SSH: status, a key added once, password logins switched with a restart
# (earlier sections added a key and allowed passwords: start from keys only)
printf 'enable_ssh_password=false\n' | as_admin "doas -n $helper apply" >/dev/null 2>&1
keys=$(grep -cE '^(ssh-|ecdsa-|sk-)' /home/m17/.ssh/authorized_keys 2>/dev/null || true)
out=$(as_admin "doas -n $helper ssh-status" 2>&1)
check "helper: ssh status" "password_logins=false keys=$keys" "$(echo $out)"
key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGb0Xv3mQ0x0aP1l2n3o4p5q6r7s8t9u0v1w2x3y4z5A test@smoke"
for i in 1 2; do printf 'ssh_key=%s\n' "$key" | as_admin "doas -n $helper apply" >/dev/null 2>&1; done
check "ssh key added once" 1 "$(grep -cxF "$key" /home/m17/.ssh/authorized_keys)"
check "authorized_keys owner and mode" "m17:600" "$(stat -c %U:%a /home/m17/.ssh/authorized_keys)"
out=$(printf 'enable_ssh_password=true\n' | M17OS_ACTION_DELAY=0 as_admin "doas -n $helper apply" 2>&1)
case "$out" in *"ssh: true"*) ok ;; *) fail "enabling password logins: $out" ;; esac
out=$(as_admin "doas -n $helper ssh-status" 2>&1)
check "helper: ssh status after" "password_logins=true keys=$((keys + 1))" "$(echo $out)"
out=$(printf 'enable_ssh_password=true\n' | as_admin "doas -n $helper apply" 2>&1)
case "$out" in *"ssh: false"*) ok ;; *) fail "unchanged password logins reported as a change: $out" ;; esac
printf 'enable_ssh_password=false\n' | as_admin "doas -n $helper apply" >/dev/null 2>&1
grep -q '^DROPBEAR_OPTS=.*-s' /etc/conf.d/dropbear && ok || fail "password logins not switched off again"
# A new hostname is reported, so the helper restarts avahi (mDNS)
old_host=$(cat /etc/hostname)
out=$(printf 'hostname=smoke-renamed\n' | M17OS_ACTION_DELAY=0 as_admin "doas -n $helper apply" 2>&1)
case "$out" in *"hostname: true"*) ok ;; *) fail "hostname change not reported: $out" ;; esac
out=$(printf 'hostname=smoke-renamed\n' | as_admin "doas -n $helper apply" 2>&1)
case "$out" in *"hostname: false"*) ok ;; *) fail "unchanged hostname reported as a change: $out" ;; esac
printf 'hostname=%s\n' "$old_host" | as_admin "doas -n $helper apply" >/dev/null 2>&1
as_admin "doas -n $helper gateway restart" >/dev/null 2>&1
check "helper refuses gateway restart" 2 "$?"
as_admin "doas -n $helper rm -rf /" >/dev/null 2>&1
check "helper refuses unknown commands" 2 "$?"
as_admin "doas -n $helper wifi-configured extra" >/dev/null 2>&1
check "helper refuses extra arguments" 2 "$?"
as_admin "doas -n /bin/sh -c id" >/dev/null 2>&1 && fail "m17-admin can run any command through doas" || ok
su -s /bin/sh www-data -c "doas -n $helper wifi-configured" >/dev/null 2>&1 && fail "www-data can run the admin helper" || ok

section "HAT firmware (m17os-firmware)"
# Every packaged firmware file is listed and has its description built in
m17os-firmware list | grep -qx 'mmdvm_hs/MMDVM_HS_Dual_Hat.bin' && ok || fail "m17os-firmware list: $(m17os-firmware list)"
m17os-firmware list | grep -qx 'cc1200/CC1200_HAT-fw.bin' && ok || fail "CC1200 firmware not listed"
m17os-firmware list | grep -q '\.elf$' && fail "m17os-firmware lists .elf files" || ok
for f in $(m17os-firmware list); do
	# (busybox grep misses text next to binary bytes: split into text runs)
	tr -c ' -~' '\n' < "/usr/share/m17-firmware/$f" | grep -q -e 'GitID' -e 'FW v' && ok || fail "$f has no description to compare"
done
m17os-firmware check ../../etc/shadow && fail "m17os-firmware check accepted a path outside" || ok
# No HAT or GPIO in a container: flashing must fail cleanly, gateway untouched
out=$(m17os-firmware flash mmdvm_hs/MMDVM_HS_Hat.bin 2>&1) && fail "flash succeeded without a HAT" || ok
echo "$out" | grep -q -e 'serial port' -e 'GPIO chip' && ok || fail "flash without a HAT: $out"
# Through the admin helper: refused names, status
sh /usr/local/libexec/m17os/admin-helper firmware-flash ../x.bin >/dev/null 2>&1 && fail "helper flashed a bad name" || ok
rm -f /run/m17os/firmware.status
check "no flash status yet" "" "$(sh /usr/local/libexec/m17os/admin-helper firmware-status)"

section "Automatic updates"
[ -x /etc/periodic/hourly/m17os-autoupdate ] && ok || fail "hourly autoupdate job missing"
printf 'auto_update=notify\nupdate_hour=4\n' > /boot/firmware/m17-config.txt
sh /usr/local/bin/m17os-config > /tmp/au-config.log 2>&1
check "auto_update saved" "AUTO_UPDATE=notify" "$(grep '^AUTO_UPDATE=' /var/lib/m17os/autoupdate.conf)"
check "update_hour saved" "UPDATE_HOUR=4" "$(grep '^UPDATE_HOUR=' /var/lib/m17os/autoupdate.conf)"
printf 'update_hour=25\n' > /boot/firmware/m17-config.txt
sh /usr/local/bin/m17os-config > /tmp/au-config2.log 2>&1
check "bad update_hour ignored" "UPDATE_HOUR=4" "$(grep '^UPDATE_HOUR=' /var/lib/m17os/autoupdate.conf)"
/usr/local/bin/m17os-autoupdate --status | grep -q 'Policy:       notify' && ok || fail "--status: $(/usr/local/bin/m17os-autoupdate --status)"
# Against the real release feed: this rootfs reports an old version, so an
# OS release is available; a dry run records it and installs nothing
M17OS_DASHBOARD_LOG=/nonexistent sh /usr/local/bin/m17os-autoupdate --dry-run > /tmp/au-dry.log 2>&1
check "dry run exit" 0 "$?"
grep -q '^RESULT=available' /var/lib/m17os/autoupdate.status && ok || fail "dry run vs GitHub: $(cat /tmp/au-dry.log)"
grep -q 'autoupdate: OS release' /data/log/m17os-events.log && ok || fail "dry run not in the event log"
# With no OS update: the M17 packages against the real m17-apk repository
printf '#!/bin/sh\nexit 1\n' > /tmp/no-os-update && chmod +x /tmp/no-os-update
M17OS_UPGRADE=/tmp/no-os-update M17OS_DASHBOARD_LOG=/nonexistent sh /usr/local/bin/m17os-autoupdate --dry-run > /tmp/au-dry2.log 2>&1
check "package dry run exit" 0 "$?"
grep -qE '^RESULT=(current|available)' /var/lib/m17os/autoupdate.status && ok || fail "package dry run: $(cat /tmp/au-dry2.log)"
rm -f /var/lib/m17os/autoupdate.conf

section "Setup wizard (m17-admin) behind nginx"
[ -L /etc/runlevels/default/m17-admin ] && ok || fail "m17-admin not in the default runlevel"
check "m17-admin state dir" "m17-admin:700" "$(stat -c %U:%a /var/lib/m17-admin)"
id m17-admin | grep -q dialout && ok || fail "m17-admin can't open the serial port: $(id m17-admin)"
grep -q 'location \^~ /setup/' /etc/nginx/http.d/default.conf && ok || fail "no /setup/ location in the nginx site"
nginx -t 2>/dev/null && ok || fail "nginx -t with the /setup/ location"
nginx -s reload 2>/dev/null || nginx
su -s /bin/sh m17-admin -c '/usr/bin/m17-admin -listen 127.0.0.1:8090 -state-dir /var/lib/m17-admin >/tmp/m17-admin.log 2>&1 &'
for i in 1 2 3 4 5 6 7 8 9 10; do wget -q -O /dev/null http://127.0.0.1:8090/setup/static/style.css 2>/dev/null && break; sleep 1; done
wget -q -O /tmp/setup.html http://127.0.0.1/setup/ && ok || fail "GET /setup/ through nginx: $(tail -3 /tmp/m17-admin.log)"
# A dashboard password was set above, so the wizard asks for it
grep -q 'Admin password' /tmp/setup.html && grep -q '/setup/login' /tmp/setup.html && ok || \
	fail "the wizard's login page didn't come through nginx: $(head -c 300 /tmp/setup.html)"
wget -q -O /tmp/setup.css http://127.0.0.1/setup/static/style.css && grep -q 'prefers-color-scheme' /tmp/setup.css && ok || \
	fail "the wizard's stylesheet didn't come through nginx"
wget -q -O /dev/null http://127.0.0.1/index.php && ok || fail "the dashboard stopped working with the /setup/ location"

section "Setup access point (m17os-netwatch)"
for p in hostapd dnsmasq; do apk info -e "$p" >/dev/null && ok || fail "$p not installed"; done
[ -L /etc/runlevels/default/m17os-netwatch ] && ok || fail "m17os-netwatch not in the default runlevel"
[ -L /etc/runlevels/default/hostapd ] || [ -L /etc/runlevels/default/dnsmasq ] && fail "hostapd or dnsmasq starts at boot" || ok
# The generated dnsmasq configuration is valid
( NW_RUN=/tmp/nwcfg; . /usr/local/lib/m17os/netwatch.sh; nw_write_configs )
dnsmasq --test --conf-file=/tmp/nwcfg/dnsmasq.conf >/dev/null 2>&1 && ok || fail "dnsmasq rejects the setup configuration: $(dnsmasq --test --conf-file=/tmp/nwcfg/dnsmasq.conf 2>&1)"
# Phones' captive-portal checks, through nginx, lead to the wizard
for path in /generate_204 /hotspot-detect.html /connecttest.txt; do
	loc=$(wget -S -O /dev/null --header "Host: connectivitycheck.example" "http://127.0.0.1$path" 2>&1 | sed -n 's/^ *Location: //p' | head -1 | tr -d '\r')
	check "captive check $path" "http://connectivitycheck.example/setup/" "$loc"
done
# By hand
out=$(sh /usr/local/bin/m17os-setup-ap start)
[ -f /run/m17os/request-ap ] && ok || fail "m17os-setup-ap start: $out"
rm -f /run/m17os/request-ap
sh /usr/local/bin/m17os-setup-ap status | grep -q '^access point: M17-Setup-' && ok || fail "m17os-setup-ap status"
# New WiFi settings while the AP is up: the helper asks netwatch to join
echo ap > /run/m17os/mode
printf 'wifi_ssid=APTest\nwifi_password=aptestpass\n' | M17OS_ACTION_DELAY=0 sh /usr/local/libexec/m17os/admin-helper apply >/dev/null
sleep 1
[ -f /run/m17os/request-join ] && ok || fail "helper apply in AP mode didn't ask netwatch to join"
rm -f /run/m17os/request-join
# Keeping the saved WiFi while on the AP still means "join it now"
out=$(printf 'callsign=N0CALL\n' | M17OS_ACTION_DELAY=0 sh /usr/local/libexec/m17os/admin-helper apply)
sleep 1
case "$out" in *"network: true"*) ok ;; *) fail "apply on the AP without WiFi changes: $out" ;; esac
[ -f /run/m17os/request-join ] && ok || fail "apply on the AP without WiFi changes didn't ask to join"
rm -f /run/m17os/request-join
# ...but not the admin password alone (the wizard's first step)
echo ap > /run/m17os/mode
printf 'dashboard_password=smoke-test-pass\n' | M17OS_ACTION_DELAY=0 sh /usr/local/libexec/m17os/admin-helper apply >/dev/null
sleep 1
[ -f /run/m17os/request-join ] && fail "setting the admin password on the AP made it leave the AP" || ok
rm -f /run/m17os/request-join /run/m17os/mode
out=$(printf 'callsign=N0CALL\n' | M17OS_ACTION_DELAY=0 sh /usr/local/libexec/m17os/admin-helper apply)
case "$out" in *"network: false"*) ok ;; *) fail "apply off the AP without WiFi changes: $out" ;; esac

pkill -f '/usr/bin/m17-admin' 2>/dev/null

section "Gateway health hook"
/etc/m17os/health.d/50-m17-gateway >/tmp/hook 2>&1
check "hook fails when the gateway is not running" 1 "$?"

PASS=$(wc -l < /tmp/pass | tr -d ' ')
FAIL=$(wc -l < /tmp/fail | tr -d ' ')
echo
echo "smoke: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
