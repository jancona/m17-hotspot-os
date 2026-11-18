#!/bin/sh
# setup-rootfs.sh - configure the Alpine root filesystem (runs in the chroot)
# Part of m17-hotspot-os. Base system setup follows Pi-Star OS by Andy
# Taylor, MW0MWZ (https://github.com/MW0MWZ/Pi-Star_OS), GPL-2.0.
#
# Expects in the environment: ALPINE_VERSION, RASPINE_REPO,
# DEFAULT_HOSTNAME, DEFAULT_USER, DEFAULT_PASSWORD, DEFAULT_WIFI_COUNTRY.
# Expects the overlay to be applied and the M17 components staged in
# /tmp/m17-stage (see fetch-m17.sh).

set -eu

STAGE=/tmp/m17-stage
PHP=php84

# ── Packages ─────────────────────────────────────────────────────────
echo "nameserver 1.1.1.1" > /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf

wget -q -O /etc/apk/keys/raspine.rsa.pub "$RASPINE_REPO/raspine.rsa.pub"
cat > /etc/apk/repositories <<EOF
$RASPINE_REPO/v${ALPINE_VERSION}/community
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community
EOF
# apk_add ARGS - apk add, retried: a package download from a mirror or
# behind a CDN occasionally fails partway, and one bad fetch shouldn't fail
# the whole build
apk_add() {
	for try in 1 2 3; do
		apk add --no-cache "$@" && return 0
		echo "apk add failed (try $try of 3), retrying..." >&2
		sleep $((try * 10))
		apk update >/dev/null 2>&1 || true
	done
	return 1
}

for try in 1 2 3; do apk update && break; sleep 10; done

apk_add \
	alpine-base openrc busybox-openrc util-linux e2fsprogs e2fsprogs-extra parted \
	dropbear dropbear-scp \
	wpa_supplicant wireless-regdb iw dhcpcd \
	ca-certificates tzdata curl minisign procps \
	doas doas-sudo-shim \
	avahi \
	nginx $PHP $PHP-fpm $PHP-session $PHP-opcache $PHP-ctype $PHP-mbstring \
	stm32flash

# The Raspberry Pi OS kernel looks for modules and firmware under /lib;
# Alpine keeps them in /usr/lib. Replace the empty dirs with symlinks.
rm -rf /lib/firmware
ln -s /usr/lib/firmware /lib/firmware
rmdir /lib/modules 2>/dev/null || true
ln -sfn /usr/lib/modules /lib/modules
apk_add --force-overwrite \
	raspios-firmware raspios-kernel-v8 raspios-kernel-2712

update-ca-certificates >/dev/null 2>&1 || true

# ── Services ─────────────────────────────────────────────────────────
for s in devfs dmesg hwdrivers mdev; do rc-update add "$s" sysinit; done
for s in modules sysctl hostname bootmisc syslog networking wpa_supplicant dhcpcd; do
	rc-update add "$s" boot
done
rc-update del hwclock boot 2>/dev/null || true
rc-update add swclock boot
# m17-hotspot-os boot services (ordering comes from their depend())
for s in m17os-data-resize m17os-varlog m17os-bindmounts m17os-config m17os-boot-watchdog; do
	rc-update add "$s" boot
done
for s in dropbear crond avahi-daemon php-fpm84 nginx m17-gateway m17os-health-check; do
	rc-update add "$s" default
done

# ── System settings ──────────────────────────────────────────────────
echo "$DEFAULT_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost localhost.localdomain
127.0.1.1   $DEFAULT_HOSTNAME
::1         localhost ip6-localhost ip6-loopback
EOF
cp /usr/share/zoneinfo/UTC /etc/localtime
echo UTC > /etc/timezone

# SSH: keys only unless m17-config.txt enables passwords
echo 'DROPBEAR_OPTS="-B -s"' > /etc/conf.d/dropbear
echo 'wpa_supplicant_args="-q"' > /etc/conf.d/wpa_supplicant

# mDNS, so the hotspot answers as <hostname>.local. Without D-Bus.
sed -i 's/^#*enable-dbus=.*/enable-dbus=no/' /etc/avahi/avahi-daemon.conf
grep -q '^enable-dbus=no' /etc/avahi/avahi-daemon.conf || \
	sed -i 's/^\[server\]/[server]\nenable-dbus=no/' /etc/avahi/avahi-daemon.conf

# Device permissions for the HATs: UART, SPI, GPIO, I2C
addgroup -S gpio 2>/dev/null || true
addgroup -S spi 2>/dev/null || true
if ! grep -q 'm17-hotspot-os' /etc/mdev.conf; then
	sed -i '/# fallback for any!device/i\
# m17-hotspot-os: radio HAT devices\
ttyAMA[0-9]*        root:dialout 0660\
spidev[0-9]\\.[0-9]   root:spi 0660\
gpiochip[0-9]*      root:gpio 0660\
i2c-[0-9]*          root:dialout 0660\
' /etc/mdev.conf
fi

cat >> /etc/modules <<EOF
brcmfmac
brcmutil
cfg80211
rfkill
i2c-dev
spidev
EOF
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/raspi-wifi.conf <<EOF
options brcmfmac roamoff=1
options brcmfmac feature_disable=0x82000
EOF
cat > /etc/modprobe.d/cfg80211.conf <<EOF
options cfg80211 ieee80211_regdom=$DEFAULT_WIFI_COUNTRY
EOF
cat > /etc/modprobe.d/rfkill_default.conf <<EOF
options rfkill default_state=1 master_switch_mode=2
EOF

# Networking: DHCP on every interface; WiFi from m17-config.txt.
# dhcpcd.conf lives in /etc/dhcpcd/ so it persists on /data.
mkdir -p /etc/dhcpcd
cat > /etc/dhcpcd/dhcpcd.conf <<'EOF'
# m17-hotspot-os dhcpcd configuration
hostname
clientid
persistent
option rapid_commit
option domain_name_servers, domain_name, domain_search, host_name
option classless_static_routes
option interface_mtu
require dhcp_server_identifier
slaac hwaddr
waitip 4
nohook wpa_supplicant
EOF
ln -sf dhcpcd/dhcpcd.conf /etc/dhcpcd.conf
mkdir -p /usr/lib/dhcpcd/dhcpcd-hooks
cat > /usr/lib/dhcpcd/dhcpcd-hooks/30-time-sync <<'EOF'
#!/bin/sh
# The Pi has no clock battery: set the time as soon as there is a network
case "$reason" in
BOUND|INFORM|REBIND|REBOOT)
	ntpd -q -n -p pool.ntp.org 2>/dev/null || \
	ntpd -q -n -p time.cloudflare.com 2>/dev/null || \
	logger -t dhcpcd "Time sync failed"
	;;
esac
EOF
chmod +x /usr/lib/dhcpcd/dhcpcd-hooks/30-time-sync
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

allow-hotplug eth0
iface eth0 inet manual

allow-hotplug wlan0
iface wlan0 inet manual
EOF
mkdir -p /etc/wpa_supplicant
cat > /etc/wpa_supplicant/wpa_supplicant.conf <<EOF
ctrl_interface=/var/run/wpa_supplicant
ctrl_interface_group=0
update_config=1
country=$DEFAULT_WIFI_COUNTRY
EOF
chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf

# ── Users ────────────────────────────────────────────────────────────
adduser -D -s /bin/sh "$DEFAULT_USER"
addgroup "$DEFAULT_USER" wheel
for g in dialout gpio spi audio; do addgroup "$DEFAULT_USER" "$g"; done
echo "$DEFAULT_USER:$DEFAULT_PASSWORD" | chpasswd
passwd -l root >/dev/null
chmod 0600 /etc/doas.d/m17os.conf

# m17-gateway runs as its own user; the dashboard (www-data) may edit its
# configuration through the m17-gateway-control group, as on Debian
addgroup -S m17-gateway
addgroup -S m17-gateway-control
adduser -S -D -H -h /opt/m17/m17-gateway -s /sbin/nologin -G m17-gateway m17-gateway
for g in dialout gpio spi audio; do addgroup m17-gateway "$g"; done
getent passwd www-data >/dev/null || adduser -S -D -H -h /var/www -s /sbin/nologin -G www-data www-data
addgroup www-data m17-gateway-control

# ── m17-gateway ──────────────────────────────────────────────────────
mkdir -p /opt/m17
cp -a "$STAGE/gateway/opt/m17/m17-gateway" /opt/m17/
chown -R root:root /opt/m17
chmod 0755 /opt/m17 /opt/m17/m17-gateway /opt/m17/m17-gateway/m17-gateway

# The configuration lives in /etc/m17-gateway/ so it persists on /data;
# /etc/m17-gateway.ini is where the gateway and dashboard look for it.
mkdir -p /etc/m17-gateway
INI=/etc/m17-gateway/m17-gateway.ini
sed 's/^#/;/' "$STAGE/gateway/etc/m17-gateway.ini.sample" > "$INI"
. /usr/local/lib/m17os/ini.sh
ini_set "$INI" General DashboardLog /var/log/m17-gateway/dashboard.log
ini_set "$INI" Reflector HostFile /opt/m17/rpi-dashboard/files/M17Hosts.txt
ini_set "$INI" Reflector OverrideHostFile /opt/m17/rpi-dashboard/files/OverrideHosts.txt
ini_set "$INI" Log Level INFO
chown m17-gateway:m17-gateway-control "$INI"
chmod 0664 "$INI"
ln -sf m17-gateway/m17-gateway.ini /etc/m17-gateway.ini

# ── rpi-dashboard ────────────────────────────────────────────────────
# Code in /opt/m17/rpi-dashboard (part of the slot, replaced by upgrades);
# its config.php and files/ in /var/lib/m17-dashboard (persistent).
cp -a "$STAGE/dashboard" /opt/m17/rpi-dashboard
rm -rf /opt/m17/rpi-dashboard/files /opt/m17/rpi-dashboard/config.php
STATE=/var/lib/m17-dashboard
mkdir -p "$STATE/files"
: > "$STATE/config.php"
cp "$STAGE/M17Hosts.txt" "$STATE/files/M17Hosts.txt"
cp "$STAGE/gateway/opt/m17/m17-gateway/OverrideHosts.txt" "$STATE/files/OverrideHosts.txt"
ln -sf /var/log/m17-gateway/dashboard.log "$STATE/files/dashboard.log"
ln -sf /etc/m17-gateway.ini "$STATE/files/m17-gateway.ini"
ln -s "$STATE/config.php" /opt/m17/rpi-dashboard/config.php
ln -s "$STATE/files" /opt/m17/rpi-dashboard/files
chown -R root:www-data /opt/m17/rpi-dashboard
chmod -R g-w,o-w /opt/m17/rpi-dashboard
chown -R www-data:www-data "$STATE"
chmod 0775 "$STATE" "$STATE/files"
chmod 0664 "$STATE/config.php" "$STATE/files/M17Hosts.txt" "$STATE/files/OverrideHosts.txt"
rm -f /opt/m17/m17-gateway/M17Hosts.txt /opt/m17/m17-gateway/OverrideHosts.txt

# The SX1255 HAT's audio codec overlay. It goes in the rootfs's
# /boot/firmware/overlays so every slot built from this rootfs has it.
cp "$STAGE/overlays/genericstereoaudiocodec.dtbo" /boot/firmware/overlays/

# PHP-FPM: run as www-data on localhost, with a PATH that finds the
# systemctl stand-in in /usr/local/bin. ondemand keeps memory use low.
POOL=/etc/$PHP/php-fpm.d/www.conf
sed -i \
	-e 's/^user = .*/user = www-data/' \
	-e 's/^group = .*/group = www-data/' \
	-e 's/^listen = .*/listen = 127.0.0.1:9000/' \
	-e 's/^pm = .*/pm = ondemand/' \
	-e 's/^pm.max_children = .*/pm.max_children = 4/' \
	"$POOL"
grep -q '^env\[PATH\]' "$POOL" || \
	echo 'env[PATH] = /usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin' >> "$POOL"
# The dashboard's own login is the protection; keep sessions in /tmp
sed -i 's|^;*session.save_path = .*|session.save_path = "/tmp"|' /etc/$PHP/php.ini

# nginx: our site replaces the default one
rm -f /etc/nginx/http.d/default.conf.apk-new

# ── Home directory skeleton ──────────────────────────────────────────
mkdir -p "/home/$DEFAULT_USER"
chown "$DEFAULT_USER:$DEFAULT_USER" "/home/$DEFAULT_USER"

# Directories the persistent bind mounts land on
mkdir -p /data /var/lib/m17os /etc/dropbear
chmod 0700 /var/lib/m17os

# /var/log is a tmpfs on the running system: record the directories
# packages created here so m17os-varlog can recreate them at boot
find /var/log -mindepth 1 -type d -exec stat -c '%a %U:%G %n' {} + | sort -k3 > /etc/m17os/var-log-dirs

rm -f /boot/initramfs 2>/dev/null || true
rm -rf /var/cache/apk/*
echo "Root filesystem configured"
