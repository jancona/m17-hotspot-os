#!/bin/sh
# setup-rootfs.sh - configure the Alpine root filesystem (runs in the chroot)
# Part of m17-hotspot-os. Base system setup follows Pi-Star OS by Andy
# Taylor, MW0MWZ (https://github.com/MW0MWZ/Pi-Star_OS), GPL-2.0.
#
# Expects in the environment: ALPINE_VERSION, RASPINE_REPO, M17_APK_REPO,
# DEFAULT_HOSTNAME, DEFAULT_USER, DEFAULT_PASSWORD, DEFAULT_WIFI_COUNTRY.
# Expects the overlay to be applied, and the M17 package repository's key
# in /etc/apk/keys (build-image.sh copies keys/m17-apk.rsa.pub there).

set -eu

PHP=php84

# ── Packages ─────────────────────────────────────────────────────────
echo "nameserver 1.1.1.1" > /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf

wget -q -O /etc/apk/keys/raspine.rsa.pub "$RASPINE_REPO/raspine.rsa.pub"
cat > /etc/apk/repositories <<EOF
$RASPINE_REPO/v${ALPINE_VERSION}/community
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community
$M17_APK_REPO/v${ALPINE_VERSION}/m17
EOF
[ -f /etc/apk/keys/m17-apk.rsa.pub ] || { echo "m17-apk.rsa.pub is not in /etc/apk/keys" >&2; exit 1; }
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
	dropbear dropbear-scp openssh-sftp-server \
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

# M17 software from the m17-apk repository. It stays in
# /etc/apk/repositories, so the hotspot can update these with apk.
apk_add \
	m17-gateway m17-gateway-openrc rpi-dashboard \
	m17-firmware-cc1200 m17-firmware-mmdvm-hs m17-firmware-mmdvm \
	m17-sx1255-overlay

# ── Services ─────────────────────────────────────────────────────────
for s in devfs dmesg hwdrivers mdev; do rc-update add "$s" sysinit; done
for s in modules sysctl hostname bootmisc syslog networking wpa_supplicant dhcpcd; do
	rc-update add "$s" boot
done
rc-update del hwclock boot 2>/dev/null || true
rc-update add swclock boot
# m17-hotspot-os boot services (ordering comes from their depend())
for s in m17os-data-resize m17os-varlog m17os-clock m17os-bindmounts m17os-config m17os-boot-watchdog; do
	rc-update add "$s" boot
done
for s in dropbear crond ntpd avahi-daemon php-fpm84 nginx m17-gateway m17os-health-check; do
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
# The Pi has no clock battery: set the time as soon as there is a network,
# without waiting for the ntpd service (which then keeps it right), and
# save it so the next boot starts close to the real time
case "$reason" in
BOUND|INFORM|REBIND|REBOOT)
	rc-service ntpd status >/dev/null 2>&1 && exit 0
	if ntpd -q -n -p pool.ntp.org 2>/dev/null || \
	   ntpd -q -n -p time.cloudflare.com 2>/dev/null; then
		/usr/local/libexec/m17os/clock save
	else
		logger -t dhcpcd "Time sync failed"
	fi
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

# ── M17 software settings ────────────────────────────────────────────
# The packages created the m17-gateway user, its configuration in
# /etc/m17-gateway/ (persistent on /data), the host files in
# /var/lib/m17-gateway/ and the dashboard's settings in
# /var/lib/m17-dashboard/. The image only changes defaults.
. /usr/local/lib/m17os/ini.sh
ini_set /etc/m17-gateway/m17-gateway.ini Log Level INFO
[ -L /etc/m17-gateway.ini ] || { echo "/etc/m17-gateway.ini link missing" >&2; exit 1; }

# The dashboard's nginx site, as the default site
cp /usr/share/rpi-dashboard/nginx-site.conf /etc/nginx/http.d/default.conf

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
