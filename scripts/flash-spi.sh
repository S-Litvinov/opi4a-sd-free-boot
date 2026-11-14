#!/bin/bash
# Write spi-image-16m.bin to the SPI NOR and verify from the raw chip.
# Run as root ON THE BOARD, booting from SD (never rewrite SPI while booting from it).
set -euo pipefail

IMG=${IMG:-spi-image-16m.bin}
MTD_CHAR=${MTD_CHAR:-/dev/mtd0}
MTD_BLOCK=${MTD_BLOCK:-/dev/mtdblock0}
BACKUP=${BACKUP:-spi-backup-before.bin}

[ -f "$IMG" ] || { echo "image $IMG not found"; exit 1; }
[ -c "$MTD_CHAR" ] || { echo "$MTD_CHAR missing (check /proc/mtd)"; exit 1; }

echo "== backing up current SPI -> $BACKUP =="
dd if="$MTD_CHAR" of="$BACKUP" bs=64k status=none

echo "== writing (mtdblock auto-erases; ~1-2 min for 16 MB) =="
dd if="$IMG" of="$MTD_BLOCK" bs=1M conv=fsync status=none
sync

echo "== verify against RAW chip via $MTD_CHAR (never trust mtdblock cache) =="
dd if="$MTD_CHAR" of=/tmp/spi-rb.bin bs=64k status=none
if cmp -s "$IMG" /tmp/spi-rb.bin; then echo SPI-VERIFY-OK; else echo SPI-VERIFY-MISMATCH; exit 1; fi
rm -f /tmp/spi-rb.bin
echo "== done. Test: power off, remove SD, power on. Restore = dd $BACKUP back, or keep the SD. =="
