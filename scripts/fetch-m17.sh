#!/bin/sh
# fetch-m17.sh - download the M17 components into a staging directory
# Part of m17-hotspot-os.
#
# Usage: scripts/fetch-m17.sh STAGE_DIR
#
# Until the M17 apk repository exists, the image takes these straight from
# upstream at the versions pinned in build.conf:
#   gateway/    m17-gateway's files, unpacked from its arm64 .deb (the
#               binary is static, so it runs on musl unchanged)
#   dashboard/  rpi-dashboard at RPI_DASHBOARD_REF
#   overlays/   the SX1255 HAT's I2S codec overlay
#   M17Hosts.txt  the current reflector host file
# setup-rootfs.sh installs them inside the chroot.

set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../build.conf
. "$REPO_DIR/build.conf"

STAGE="${1:?usage: fetch-m17.sh STAGE_DIR}"
mkdir -p "$STAGE"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> m17-gateway ${M17_GATEWAY_VERSION}"
DEB="m17-gateway_${M17_GATEWAY_VERSION}_arm64.deb"
curl -fsSL -o "$TMP/$DEB" \
	"https://github.com/jancona/m17/releases/download/v${M17_GATEWAY_VERSION}/$DEB"
(cd "$TMP" && ar x "$DEB")
mkdir -p "$STAGE/gateway"
case $(ls "$TMP"/data.tar.*) in
	*.zst) zstd -dc "$TMP"/data.tar.zst | tar -xf - -C "$STAGE/gateway" ;;
	*.xz)  tar -xJf "$TMP"/data.tar.xz -C "$STAGE/gateway" ;;
	*.gz)  tar -xzf "$TMP"/data.tar.gz -C "$STAGE/gateway" ;;
	*) echo "unknown data archive in $DEB" >&2; exit 1 ;;
esac
[ -x "$STAGE/gateway/opt/m17/m17-gateway/m17-gateway" ] || { echo "m17-gateway binary missing from $DEB" >&2; exit 1; }
[ -f "$STAGE/gateway/etc/m17-gateway.ini.sample" ] || { echo "m17-gateway.ini.sample missing from $DEB" >&2; exit 1; }

echo "==> rpi-dashboard ${RPI_DASHBOARD_REF}"
git init -q "$TMP/dashboard"
git -C "$TMP/dashboard" fetch -q --depth 1 https://github.com/M17-Project/rpi-dashboard.git "$RPI_DASHBOARD_REF"
git -C "$TMP/dashboard" checkout -q FETCH_HEAD
rm -rf "$TMP/dashboard/.git"
mkdir -p "$STAGE/dashboard"
cp -a "$TMP/dashboard/." "$STAGE/dashboard/"

echo "==> I2S codec overlay ${I2S_OVERLAY_REF}"
mkdir -p "$STAGE/overlays"
curl -fsSL -o "$STAGE/overlays/genericstereoaudiocodec.dtbo" \
	"https://raw.githubusercontent.com/M17-Project/RaspberryPi_I2S_Slave/${I2S_OVERLAY_REF}/genericstereoaudiocodec.dtbo"

echo "==> M17 host file"
if ! curl -fsSL --max-time 60 -o "$STAGE/M17Hosts.txt" https://m17-project.github.io/hostfiles/M17Hosts.txt; then
	echo "    could not download; using the copy from the m17-gateway package"
	cp "$STAGE/gateway/opt/m17/m17-gateway/M17Hosts.txt" "$STAGE/M17Hosts.txt"
fi
