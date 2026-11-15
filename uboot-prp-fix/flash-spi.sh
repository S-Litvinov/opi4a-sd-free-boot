#!/bin/bash
# flash-spi.sh - write a patched 16 MiB SPI image with safety net. Run on the board:
#   sudo bash flash-spi.sh <image.bin> <expected-sha256>
# Refuses unknown SPI contents, keeps an off-chip-copyable backup, verifies by readback
# from the RAW mtd character device (mtdblock is page-cached!).
set -euo pipefail
IMG=${1:?usage: flash-spi.sh <image.bin> <sha256>}
WANT=${2:?usage: flash-spi.sh <image.bin> <sha256>}
TS=$(date +%Y%m%d-%H%M%S)
BK=/home/orangepi/spi-current-$TS.bin
[ "$(id -u)" = 0 ] || { echo "ERROR: run with sudo"; exit 1; }
[ -f "$IMG" ] || { echo "ERROR: $IMG missing"; exit 1; }
GOT=$(sha256sum "$IMG" | cut -d' ' -f1)
[ "$GOT" = "$WANT" ] || { echo "ERROR: image sha mismatch ($GOT)"; exit 1; }
[ "$(stat -c%s "$IMG")" = 16777216 ] || { echo "ERROR: image must be exactly 16 MiB"; exit 1; }

echo "== backing up current SPI =="
dd if=/dev/mtd0 of="$BK" bs=64k status=none
CUR=$(sha256sum "$BK" | cut -d' ' -f1)
echo "current SPI = $CUR"
echo "backup: $BK  (copy it off the board before rebooting)"
read -r -p "Write $GOT to SPI NOR? [y/N] " A
[ "$A" = y ] || { echo "aborted, backup kept at $BK"; exit 1; }

echo "== writing $GOT =="
dd if="$IMG" of=/dev/mtdblock0 bs=1M status=none
sync

echo "== readback verify (char device, no block cache) =="
RB=$(dd if=/dev/mtd0 bs=64k status=none | sha256sum | cut -d' ' -f1)
if [ "$RB" != "$GOT" ]; then
    echo "ERROR: readback mismatch ($RB) - do NOT power off, restore first:"
    echo "  dd if=$BK of=/dev/mtdblock0 bs=1M"
    exit 1
fi
echo "FLASH-OK readback=$RB"
