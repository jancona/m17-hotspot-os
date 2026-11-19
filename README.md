# m17-hotspot-os

A ready-to-flash SD card image for an [M17](https://m17project.org/) hotspot: a Raspberry Pi with a CC1200, SX1255 or MMDVM radio HAT running [m17-gateway](https://github.com/jancona/m17) and the [M17 web dashboard](https://github.com/M17-Project/rpi-dashboard).

Download the image, write it to a card, boot, and set your callsign. No Raspberry Pi OS install and no installer script. OS updates are installed to a second root partition and roll back automatically if the new version doesn't come up healthy.

> **Status: early development.** Tested on a Raspberry Pi Zero 2 W with an MMDVM_HS_Dual_Hat: first boot, configuration from `m17-config.txt`, the setup wizard over the setup access point from a phone and over the LAN, upgrades in both directions, signature checks, automatic rollback and automatic updates. Other Pi models and the CC1200 and SX1255 HATs are untested. The [installer script](https://github.com/M17-Project/m17-hotspot-installer) for Raspberry Pi OS remains the supported way to build a hotspot, and stays that way: this image is an alternative for people who want an appliance.

## What's in it

| | |
|---|---|
| **Base** | Alpine Linux userland with the Raspberry Pi OS kernel and firmware, from [RasPINE](https://github.com/MW0MWZ/RasPINE) |
| **Hardware** | Raspberry Pi Zero 2 W, 3, 4, 5 (64-bit only) |
| **M17** | m17-gateway, rpi-dashboard (nginx + PHP-FPM), the [m17-admin](https://github.com/jancona/m17-admin) setup wizard, HAT firmware (CC1200, MMDVM_HS, MMDVM) and the SX1255 I2S codec overlay, from the [m17-apk](https://github.com/jancona/m17-apk) package repository; stm32flash |
| **Updates** | A/B root partitions with boot watchdog, health check and automatic rollback, based on [Pi-Star OS](https://github.com/MW0MWZ/Pi-Star_OS) |
| **Footprint** | Logs in RAM to spare the SD card, except the dashboard's activity log (one line per event), which is kept on `/data` so recent activity survives reboots; settings on a separate `/data` partition |

## Getting started

1. Download `m17-hotspot-os-<version>.img.xz` from [Releases](../../releases/latest).
2. Write it to an SD card (4 GB or larger) with Raspberry Pi Imager ("Use custom") or balenaEtcher. Both take the `.img.xz` as is.
3. **Optional:** to set it up without a phone, open the `BOOT` partition before ejecting the card, copy `m17-config.txt.sample` to `m17-config.txt` and fill in your WiFi, callsign and HAT. See [Boot configuration](#boot-configuration).
4. Put the card in the Pi and power it on. The first boot expands the data partition and reboots once (twice for an SX1255 HAT), so give it two or three minutes.
5. Set it up with the wizard:
   - **No network yet** (WiFi only, no `m17-config.txt`): join the hotspot's own WiFi network, **M17-Setup-XXXX**, with a phone. The wizard opens by itself. See below.
   - **Ethernet, or WiFi from `m17-config.txt`:** open **http://m17-hotspot.local/setup/** (or the Pi's IP address).
6. When the wizard finishes, the dashboard is at **http://m17-hotspot.local/**. Its **Setup** link in the sidebar brings you back to the wizard to change settings.

### The setup access point

If the hotspot has no network 90 seconds after it starts (no Ethernet, and no WiFi it can join), it starts its own open WiFi network, **M17-Setup-XXXX** (the last four characters of its WiFi MAC address). Join it with a phone or laptop: the setup wizard opens by itself (or open any web address). The wizard sets the admin password, WiFi, callsign, radio HAT (it detects CC1200 and MMDVM boards, and offers to flash newer firmware), frequency, reflector, updates and SSH access. When it applies new WiFi details, the hotspot leaves M17-Setup and joins that network; if it can't within a minute, M17-Setup comes back so you can try again.

With Ethernet, open **http://m17-hotspot.local/setup/** instead. The wizard is also how to change those settings later.

The same access point starts if a working network is lost for 5 minutes. While it's up and nobody is connected to it, the hotspot retries its saved WiFi every 10 minutes, so after a power cut it finds the router again by itself even if the Pi started first. `doas m17os-setup-ap start|stop|status` controls it by hand.

### Logging in

The user is `m17` with password `m17hotspot`. **Change it** with `user_password` in `m17-config.txt` or with `passwd`. SSH accepts keys only (add one with `ssh_key`), unless `enable_ssh_password=true` is set. `root` is locked; use `doas` (or `sudo`, which maps to it).

The wizard's admin password is also the password for the dashboard's Gateway and Settings pages. You can set it with `dashboard_password` in `m17-config.txt` too, or over SSH:

```bash
doas -u www-data php84 /opt/m17/rpi-dashboard/set_password.php
```

## Boot configuration

`m17-config.txt` on the boot partition is read at the next boot and then **deleted**, because it may contain passwords. It works for the first boot and for recovery: if your WiFi changes, put the card in a PC, drop in a new `m17-config.txt`, and boot again.

| Key | Meaning |
|---|---|
| `wifi_ssid`, `wifi_password`, `wifi_ssid_2` … `_10` | WiFi networks; the highest number wins when several are in range |
| `wifi_country` | Two-letter country code (default `US`) |
| `user_password`, `ssh_key`, `enable_ssh_password` | Login for the `m17` user |
| `hostname`, `timezone` | e.g. `m17-hotspot`, `America/New_York` |
| `callsign` | Your callsign, e.g. `N0CALL` or `N0CALL H` |
| `hat` | `cc1200`, `sx1255` or `mmdvm`; also sets the usual serial speed (460800 for CC1200, 115200 for MMDVM) |
| `modem_speed` | Serial speed to the HAT, if your board differs from the default for its type |
| `frequency`, `rx_frequency`, `tx_frequency` | MHz (`439.5`) or Hz; `frequency` sets both |
| `duplex`, `power` | `true`/`false`; transmit power in dBm |
| `reflector`, `module` | e.g. `M17-M17`, `C` |
| `dashboard_password` | Password for the dashboard's admin pages (8+ characters) |
| `auto_update`, `update_hour` | `auto` (default), `notify` or `off`; the local hour (0-23, default 3) in which updates run |

The full list with comments is in [`boot/m17-config.txt.sample`](boot/m17-config.txt.sample).

The setup wizard ([m17-admin](https://github.com/jancona/m17-admin)) applies the same keys, through `m17os-config --apply` (settings on stdin, a `warning:`/`reboot:`/`network:`/`gateway:` result on stdout). It runs as its own user and reaches root only through `/usr/local/libexec/m17os/admin-helper`, which accepts a fixed set of commands. `reflector=none` means no reflector (RF only).

The gateway settings go into `/etc/m17-gateway.ini`, the file the dashboard's Gateway page edits; everything else there can be changed on that page.

## Updates

```bash
doas m17os-upgrade --check     # is there a newer release?
doas m17os-upgrade --install   # install it to the other slot, then reboot
m17os-slot-info                # which slot is running, versions, recent update events
doas m17os-rollback            # go back to the previous slot
```

How it works:

- The card has two root partitions. An update is written to the one that isn't running, and its kernel and device trees go to that slot's own directory on the boot partition (`slotA/`, `slotB/`). Switching slots means changing one line, `os_prefix=` in `config.txt`, so the running system is never modified.
- After switching, the new slot is **pending**. On each boot the watchdog counts an attempt. Then the health check waits for the network (if one is configured), m17-gateway (if a callsign is set) and the dashboard. Hooks live in `/etc/m17os/health.d/`. If they pass, the slot is marked good. If they don't, the Pi reboots, and after three failed attempts it switches back to the previous slot.
- Upgrades, pending boots, health check results and rollbacks are recorded in `/data/log/m17os-events.log`, which survives the reboots they cause.
- `/data` holds everything that must survive an update: WiFi, SSH keys, the gateway configuration, the dashboard's settings and host files, home directories, and the `m17` password.
- If a slot won't boot at all, put the card in a PC and change `os_prefix=slotA/` to `os_prefix=slotB/` (or the reverse) at the end of `config.txt`.

### Automatic updates

Every night in the update hour (03:00 local time unless `update_hour` says otherwise, plus a random delay of up to 45 minutes), `m17os-autoupdate` checks for updates:

1. **A new OS release:** installed to the other slot, and the hotspot reboots into it. The health check and rollback described above guard it.
2. **Otherwise, new M17 packages** (m17-gateway, the dashboard, firmware) from the m17-apk repository: upgraded in place (with `apk upgrade <packages>`, which touches their dependencies only when a new version needs it), and the gateway or PHP restarted if they changed. Other Alpine packages and the kernel come only with OS releases, which are rebuilt at least monthly: a kernel upgraded with apk wouldn't match the slot's boot files.

Nothing is installed during a transmission: it waits up to 30 minutes for the gateway to be idle, and otherwise tries the next night. With `auto_update=notify` it only records what is available; with `off` it does nothing. Results go to the event log that `m17os-slot-info` shows.

```bash
doas m17os-autoupdate --status   # policy, update hour, last result
doas m17os-autoupdate --dry-run  # what would be updated now
doas m17os-autoupdate --now      # update now (still waits for an idle gateway)
```

To change the settings later, edit `/var/lib/m17os/autoupdate.conf` (`AUTO_UPDATE=auto|notify|off`, `UPDATE_HOUR=0-23`) or drop a new `m17-config.txt` on the boot partition.

## Hardware notes

- The HAT uses the PL011 UART on GPIO 14/15 (`/dev/ttyAMA0`); Bluetooth is moved to the mini UART (`dtoverlay=miniuart-bt`), and no serial console is started.
- **SX1255:** `hat=sx1255` (or `doas m17os-hat set sx1255`) enables I2S and the `genericstereoaudiocodec` overlay, then needs a reboot. Those pins (GPIO 18–21) are the CC1200 HAT's BOOT0/NRST lines, so the overlay is only enabled for the SX1255.
- The Pi has no clock battery. The time is saved to `/data` every 15 minutes and at shutdown, and restored at boot (never moving the clock backwards); `ntpd` keeps it right once the network is up.
- `scp` and `sftp` work (OpenSSH's `sftp-server` alongside Dropbear).
- **HAT firmware:** the wizard's Firmware step compares the version the HAT reports with the files from the m17-firmware packages and offers to flash a newer one. Nothing is flashed without asking. By hand: `m17os-firmware list`, then `doas m17os-firmware flash mmdvm_hs/MMDVM_HS_Hat.bin` (for example). It stops the gateway, puts the HAT's STM32 into its bootloader through BOOT0/NRST (`Boot0Pin`/`NRSTPin` in `[Modem]`, GPIO 20 and 21 by default), writes and verifies the file with `stm32flash`, and starts the gateway again. A wrong file can't damage the board: the bootloader is in ROM, so flashing the right one fixes it.

## Building

Images are built by GitHub Actions on arm64 runners ([`.github/workflows/build.yml`](.github/workflows/build.yml)): on every push and pull request (as a check), weekly when the kernel or an M17 package changes or the last release is a month old, and on demand. Releases are named `YYYY.MM.DD.N`.

To build locally you need Linux (arm64, or x86 with qemu-user-static and binfmt) and root:

```bash
sudo apt-get install parted dosfstools e2fsprogs curl xz-utils zstd git rsync fdisk util-linux binutils
sudo scripts/build-image.sh 2026.11.17.1 out
```

On a Mac, run the same thing in a privileged `debian:trixie` container (Docker or Colima). The Alpine version and the package repositories are set in [`build.conf`](build.conf). The M17 software's versions are set in [m17-apk](https://github.com/jancona/m17-apk); each release's `manifest.txt` lists the M17 packages it contains.

| Path | |
|---|---|
| `scripts/build-image.sh` | Partitions the image, installs Alpine, runs the chroot setup, builds slot A, writes the rootfs tarball and manifest |
| `scripts/setup-rootfs.sh` | Runs inside the chroot: packages (including the M17 ones), services, users, and the image's settings for the gateway and dashboard |
| `keys/m17-apk.rsa.pub` | The M17 package repository's signing key, trusted by the build and by every hotspot |
| `overlay/` | Files copied into the root filesystem: A/B tools, init scripts, nginx, doas |
| `boot/` | `config.txt`, `slot.conf` and the `m17-config.txt` sample for the boot partition |
| `tests/` | `unit.sh` (libraries and tools), `run-smoke.sh` (sets up the rootfs in a container and checks the result) |

### Signing releases

`m17os-upgrade` verifies a release's checksum. If `/etc/m17os/release.pub` exists, it also requires a valid [minisign](https://jedisct1.github.io/minisign/) signature on `manifest.txt`, which lists the rootfs checksum. To turn signing on:

```bash
minisign -G -W -p keys/release.pub -s release.key   # -W: no password, for CI
```

Commit `keys/release.pub` and add the contents of `release.key` as the repository secret `MINISIGN_SECRET_KEY`. Keep a copy of `release.key` offline. Images built after that only accept signed updates. Only release builds are signed, so pushes and pull requests build without the secret.

This repository signs its releases with the key in [`keys/release.pub`](keys/release.pub) (minisign key ID `806421099057CCCE`).

## Differences from Pi-Star OS

The A/B update system, boot configuration file and `/data` layout come from Pi-Star OS, renamed (`m17os-*`). Changes:

- **aarch64**, so Zero 2 W and later only.
- **Health check hooks** in `/etc/m17os/health.d/` instead of a built-in Pi-Star MCP check.
- **Reboot on a failed health check**, so a slot that boots but isn't healthy still gets rolled back.
- **An interrupted upgrade is noticed.** `slot.conf` is written before `config.txt` switches slots. If power fails in between, the watchdog sees that the old slot booted and clears the pending state, instead of marking a slot that never ran as good.
- **`slot.conf` is parsed, not sourced.** It sits on a FAT partition anyone can edit.
- **Optional minisign signatures** on the release manifest.
- **M17 settings in the boot configuration file**, and a HAT tool for the SX1255's overlays.

## Credits and license

- [Pi-Star OS](https://github.com/MW0MWZ/Pi-Star_OS) and [RasPINE](https://github.com/MW0MWZ/RasPINE) by Andy Taylor, MW0MWZ, for the A/B update system, the boot configuration processor, the build approach and the Alpine + Raspberry Pi kernel base.
- [m17-gateway](https://github.com/jancona/m17), [rpi-dashboard](https://github.com/M17-Project/rpi-dashboard) and the [hotspot installer](https://github.com/M17-Project/m17-hotspot-installer) from the M17 Project.

GPL-2.0, like Pi-Star OS, from which parts of this repository are derived. See [LICENSE](LICENSE).
