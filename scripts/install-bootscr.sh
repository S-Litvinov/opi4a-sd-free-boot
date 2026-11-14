#!/bin/bash
# Compile boot.cmd.nvme -> boot.scr and deploy to BOTH the NVMe rootfs /boot
# and the SD boot partition (stock SD script kept once as boot.scr.orig).
# Run as root ON THE BOARD with the SD card inserted.
set -euo pipefail

CMD=${CMD:-boot.cmd.nvme}
SD_BOOT=${SD_BOOT:-/media/mmcboot/boot}     # mountpoint of the SD boot partition
NVME_BOOT=${NVME_BOOT:-/boot}               # / of the rootfs when the bind-mount is off
OUT=/tmp/boot.scr.nvme

[ -f "$CMD" ] || { echo "$CMD not found"; exit 1; }
grep -q 'root=UUID=' "$CMD"
if grep -q '<NVME_ROOT_UUID>' "$CMD"; then
  echo "edit $CMD first: replace <NVME_ROOT_UUID> with the real ext4 UUID of your NVMe rootfs (blkid)"
  exit 1
fi

mkimage -C none -A arm -T script -d "$CMD" "$OUT" >/dev/null

# --- NVMe side: real rootfs /boot (vendor images bind-mount the SD over it) ---
umount "$NVME_BOOT" 2>/dev/null || true
install -m 0644 "$OUT" "$NVME_BOOT/boot.scr"
# make distro-boot go straight to our script instead of a stale extlinux entry
[ -f "$NVME_BOOT/extlinux/extlinux.conf" ] && \
  mv "$NVME_BOOT/extlinux/extlinux.conf" "$NVME_BOOT/extlinux/extlinux.conf.disabled"
mount "$NVME_BOOT" 2>/dev/null || true

# --- SD side ---
[ -d "$SD_BOOT" ] || { echo "$SD_BOOT not mounted"; exit 1; }
mount -o remount,rw "$SD_BOOT"
trap 'mount -o remount,ro "$SD_BOOT" 2>/dev/null || true' EXIT
[ -f "$SD_BOOT/boot.scr.orig" ] || cp -a "$SD_BOOT/boot.scr" "$SD_BOOT/boot.scr.orig"
install -m 0644 "$OUT" "$SD_BOOT/boot.scr"
sync

sha256sum "$NVME_BOOT/boot.scr" "$SD_BOOT/boot.scr"
echo BOOTSCR_INSTALLED
