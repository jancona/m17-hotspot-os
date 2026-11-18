#!/bin/sh
# build-image.sh - build an m17-hotspot-os SD card image
# Part of m17-hotspot-os. The image layout and A/B scheme follow Pi-Star OS
# by Andy Taylor, MW0MWZ (https://github.com/MW0MWZ/Pi-Star_OS), GPL-2.0.
#
# Usage: sudo scripts/build-image.sh VERSION OUTPUT_DIR
#
# Runs on a Linux host (Debian/Ubuntu tested) as root. Needs: parted,
# losetup, mkfs.vfat, mkfs.ext4, curl, xz, zstd, git, rsync, and
# qemu-user-static with binfmt support when the host isn't aarch64.
#
# Produces in OUTPUT_DIR:
#   <name>-<version>.img.xz (+ .sha256)          full image, first install
#   <name>-<version>.rootfs.tar.xz (+ .sha256)   rootfs for m17os-upgrade
#   manifest.txt                                 what m17os-upgrade reads

set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../build.conf
. "$REPO_DIR/build.conf"

VERSION="${1:-}"
OUT_DIR="${2:-}"
[ -n "$VERSION" ] && [ -n "$OUT_DIR" ] || { echo "Usage: $0 VERSION OUTPUT_DIR" >&2; exit 2; }
case "$VERSION" in *[!0-9.]*|.*|*.) echo "VERSION must be dotted numbers" >&2; exit 2 ;; esac
[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 2; }

mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
BUILD_DATE=$(date -u +%Y-%m-%d)
WORK=$(mktemp -d /tmp/m17os-build.XXXXXX)
IMG="$WORK/image.img"
MNT="$WORK/mnt"
ROOT="$MNT/root"
BOOT="$MNT/boot"
DATA="$MNT/data"
LOOP=""
BASENAME="${IMAGE_NAME}-${VERSION}"

log() { echo "==> $*"; }

cleanup() {
	set +e
	for m in "$ROOT/dev/pts" "$ROOT/dev" "$ROOT/sys" "$ROOT/proc" "$DATA" "$BOOT" "$ROOT"; do
		mountpoint -q "$m" 2>/dev/null && umount "$m"
	done
	[ -n "$LOOP" ] && losetup -d "$LOOP"
	rm -rf "$WORK"
}
trap cleanup EXIT

# ── Partitioned image ────────────────────────────────────────────────
log "Creating ${IMAGE_SIZE} image"
truncate -s "$IMAGE_SIZE" "$IMG"
parted -s "$IMG" \
	mklabel msdos \
	mkpart primary fat32 1MiB "$BOOT_END" \
	mkpart primary ext4 "$BOOT_END" "$SLOT_A_END" \
	mkpart primary ext4 "$SLOT_A_END" "$SLOT_B_END" \
	mkpart primary ext4 "$SLOT_B_END" 100% \
	set 1 boot on

LOOP=$(losetup -P --find --show "$IMG")
# Partition nodes can take a moment to appear. In a container /dev isn't
# updated by the host, so create them from sysfs if they never show up.
for _ in 1 2 3 4 5; do [ -b "${LOOP}p4" ] && break; sleep 1; done
if [ ! -b "${LOOP}p4" ]; then
	for n in 1 2 3 4; do
		sysdev="/sys/block/${LOOP#/dev/}/${LOOP#/dev/}p$n/dev"
		[ -f "$sysdev" ] || continue
		mknod "${LOOP}p$n" b "$(cut -d: -f1 "$sysdev")" "$(cut -d: -f2 "$sysdev")"
	done
fi
[ -b "${LOOP}p4" ] || { echo "partition devices for $LOOP did not appear" >&2; exit 1; }

mkfs.vfat -F 32 -n BOOT "${LOOP}p1" >/dev/null
mkfs.ext4 -q -L rootfs-a "${LOOP}p2"
mkfs.ext4 -q -L rootfs-b "${LOOP}p3"
mkfs.ext4 -q -L data "${LOOP}p4"

mkdir -p "$ROOT" "$BOOT" "$DATA"
mount "${LOOP}p2" "$ROOT"
mount "${LOOP}p1" "$BOOT"
mount "${LOOP}p4" "$DATA"

# ── Alpine minirootfs ────────────────────────────────────────────────
MIRROR="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}"
log "Finding the Alpine ${ALPINE_VERSION} minirootfs"
curl -fsSL "$MIRROR/latest-releases.yaml" -o "$WORK/latest-releases.yaml"
# Each entry is a block of "key: value" lines starting with "-"; take the
# minirootfs block's file and sha256 (word splitting intended)
# shellcheck disable=SC2046
set -- $(awk '
	/^-/ { flavor = file = sha = "" }
	/^[[:space:]-]*flavor:/ { flavor = $NF }
	/^[[:space:]]*file:/ { file = $NF }
	/^[[:space:]]*sha256:/ { sha = $NF }
	flavor == "alpine-minirootfs" && file != "" && sha != "" { print file, sha; exit }
' "$WORK/latest-releases.yaml")
ALPINE_FILE="${1:-}"
ALPINE_SHA="${2:-}"
[ -n "$ALPINE_FILE" ] && [ -n "$ALPINE_SHA" ] || { echo "minirootfs not found in latest-releases.yaml" >&2; exit 1; }
log "Downloading $ALPINE_FILE"
curl -fsSL "$MIRROR/$ALPINE_FILE" -o "$WORK/$ALPINE_FILE"
echo "$ALPINE_SHA  $WORK/$ALPINE_FILE" | sha256sum -c - >/dev/null
tar -xzf "$WORK/$ALPINE_FILE" -C "$ROOT"
ALPINE_RELEASE=$(echo "$ALPINE_FILE" | sed -n 's/^alpine-minirootfs-\([0-9.]*\)-.*/\1/p')

# Emulation for the chroot when the host isn't aarch64. binfmt's "F" flag
# usually makes this unnecessary; the copy is harmless and removed later.
QEMU=""
if [ "$(uname -m)" != "aarch64" ]; then
	QEMU=$(command -v qemu-aarch64-static || true)
	[ -n "$QEMU" ] || { echo "qemu-aarch64-static is needed on a $(uname -m) host" >&2; exit 1; }
	cp "$QEMU" "$ROOT/usr/bin/qemu-aarch64-static"
fi

# The M17 package repository's key: pinned in this repository, not
# downloaded, so the build trusts exactly this key
install -m 0644 "$REPO_DIR/keys/m17-apk.rsa.pub" "$ROOT/etc/apk/keys/m17-apk.rsa.pub"

# ── Overlay and chroot setup ─────────────────────────────────────────
log "Applying overlay"
rsync -a --chown=root:root "$REPO_DIR/overlay/" "$ROOT/"

cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
mount -t proc none "$ROOT/proc"
mount -t sysfs none "$ROOT/sys"
mount -o bind /dev "$ROOT/dev"
mount -o bind /dev/pts "$ROOT/dev/pts"

cp "$REPO_DIR/scripts/setup-rootfs.sh" "$ROOT/tmp/setup-rootfs.sh"
log "Configuring the root filesystem (chroot)"
chroot "$ROOT" /usr/bin/env -i \
	PATH=/usr/sbin:/usr/bin:/sbin:/bin \
	ALPINE_VERSION="$ALPINE_VERSION" \
	RASPINE_REPO="$RASPINE_REPO" \
	M17_APK_REPO="$M17_APK_REPO" \
	DEFAULT_HOSTNAME="$DEFAULT_HOSTNAME" \
	DEFAULT_USER="$DEFAULT_USER" \
	DEFAULT_PASSWORD="$DEFAULT_PASSWORD" \
	DEFAULT_WIFI_COUNTRY="$DEFAULT_WIFI_COUNTRY" \
	/bin/sh /tmp/setup-rootfs.sh

umount "$ROOT/dev/pts" "$ROOT/dev" "$ROOT/sys" "$ROOT/proc"
rm -f "$ROOT/tmp/setup-rootfs.sh"
# The image must not carry the build host's resolver settings
: > "$ROOT/etc/resolv.conf"

# Release key for signed OS updates, when the repository has one
if [ -f "$REPO_DIR/keys/release.pub" ]; then
	install -m 0644 "$REPO_DIR/keys/release.pub" "$ROOT/etc/m17os/release.pub"
	log "Installed release.pub: OS updates must be signed"
else
	log "No keys/release.pub: this image accepts unsigned OS updates"
fi

# pkg_version NAME - the version of an installed package in the rootfs
pkg_version() {
	awk -v p="P:$1" '$0 == p { getline; sub(/^V:/, ""); print; exit }' "$ROOT/lib/apk/db/installed"
}
# Every package from the M17 repository, for the manifest: a change here
# is a reason to build a new release
M17_PACKAGES=$(for p in m17-gateway m17-gateway-openrc rpi-dashboard m17-firmware-cc1200 \
	m17-firmware-mmdvm-hs m17-firmware-mmdvm m17-sx1255-overlay m17-admin m17-admin-openrc; do
	printf '%s-%s ' "$p" "$(pkg_version "$p")"; done | sed 's/ $//')

cat > "$ROOT/etc/m17os-release" <<EOF
m17-hotspot-os
Version: ${VERSION}
Build Date: ${BUILD_DATE}
Alpine Version: ${ALPINE_RELEASE:-$ALPINE_VERSION}
Architecture: ${ALPINE_ARCH}
m17-gateway: $(pkg_version m17-gateway)
rpi-dashboard: $(pkg_version rpi-dashboard)
Base: Alpine Linux with the Raspberry Pi OS kernel from RasPINE
EOF

# ── Boot partition: shared firmware, slot A, config ──────────────────
log "Setting up the boot partition"
[ -n "$(ls -A "$ROOT/boot/firmware" 2>/dev/null)" ] || { echo "no files in /boot/firmware" >&2; exit 1; }
cp -a "$ROOT/boot/firmware/." "$BOOT/"
cp "$REPO_DIR/boot/config.txt" "$BOOT/config.txt"
cp "$REPO_DIR/boot/m17-config.txt.sample" "$BOOT/m17-config.txt.sample"
[ -f "$BOOT/cmdline.txt" ] || { echo "cmdline.txt missing" >&2; exit 1; }

# Slot A's kernels, device trees, overlays and cmdline.txt go in slotA/,
# selected by os_prefix. GPU firmware stays at the root. slotB/ is created
# by the first upgrade.
(
	M17OS_FW_DIR="$BOOT"
	# shellcheck source=../overlay/usr/local/lib/m17os/bootslot.sh
	. "$REPO_DIR/overlay/usr/local/lib/m17os/bootslot.sh"
	install_slot_boot "$BOOT" A "$BOOT/cmdline.txt"
	set_active_slot A
)
rm -rf "$BOOT"/kernel*.img "$BOOT"/*.dtb "$BOOT/overlays" "$BOOT/cmdline.txt"
sed "s/^SLOT_A_VERSION=.*/SLOT_A_VERSION=\"${VERSION}\"/" "$REPO_DIR/boot/slot.conf" > "$BOOT/slot.conf"
log "slotA/cmdline.txt: $(cat "$BOOT/slotA/cmdline.txt")"

# ── /data skeleton ───────────────────────────────────────────────────
log "Creating the /data skeleton"
mkdir -p "$DATA/tmp" "$DATA/m17os" "$DATA/home" "$DATA/log"
cp -a "$ROOT/home/." "$DATA/home/"
chmod 0700 "$DATA/m17os"

# ── Rootfs tarball and manifest ──────────────────────────────────────
[ -n "$QEMU" ] && rm -f "$ROOT/usr/bin/qemu-aarch64-static"
ROOTFS="$BASENAME.rootfs.tar.xz"
log "Creating $ROOTFS"
tar -C "$ROOT" --numeric-owner --xattrs -cf - . | xz -T0 -6 > "$OUT_DIR/$ROOTFS"
ROOTFS_SHA256=$(sha256sum "$OUT_DIR/$ROOTFS" | cut -d' ' -f1)
echo "$ROOTFS_SHA256  $ROOTFS" > "$OUT_DIR/$ROOTFS.sha256"

cat > "$OUT_DIR/manifest.txt" <<EOF
VERSION=${VERSION}
BUILD_DATE=${BUILD_DATE}
ARCH=${ALPINE_ARCH}
ALPINE_VERSION=${ALPINE_RELEASE:-$ALPINE_VERSION}
ROOTFS_FILENAME=${ROOTFS}
ROOTFS_SHA256=${ROOTFS_SHA256}
M17_GATEWAY_VERSION=$(pkg_version m17-gateway)
RPI_DASHBOARD_VERSION=$(pkg_version rpi-dashboard)
M17_PACKAGES=${M17_PACKAGES}
RASPINE_KERNEL=$(pkg_version raspios-kernel-v8)
BUILD_COMMIT=${BUILD_COMMIT:-$(git -C "$REPO_DIR" rev-parse --verify -q HEAD 2>/dev/null || echo unknown)}
EOF

# ── Image ────────────────────────────────────────────────────────────
sync
umount "$DATA" "$BOOT" "$ROOT"
losetup -d "$LOOP"
LOOP=""

log "Compressing the image"
xz -T0 -9 -c "$IMG" > "$OUT_DIR/$BASENAME.img.xz"
(cd "$OUT_DIR" && sha256sum "$BASENAME.img.xz" > "$BASENAME.img.xz.sha256")

log "Done:"
ls -lh "$OUT_DIR"
