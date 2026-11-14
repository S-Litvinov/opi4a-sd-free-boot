#!/bin/bash
# Build a 16 MB SPI NOR image for Orange Pi 4A (T527/sun55iw3) from
#  - boot0_spinor.fex (official Xunlong blob from orangepi-build)
#  - boot_package.fex carved from your own SD card (matches your BSP version)
# Run ON THE BOARD (needs the SD card inserted) or any Linux with the card read.
set -euo pipefail

SD_DEV=${SD_DEV:-/dev/mmcblk1}          # your SD block device
BOOT0_URL=${BOOT0_URL:-https://raw.githubusercontent.com/orangepi-xunlong/orangepi-build/next/external/packages/pack-uboot/sun55iw3/bin/boot0_spinor.fex}
OUT=${OUT:-spi-image-16m.bin}
WORK=${WORK:-/tmp/opi4a-spi}
mkdir -p "$WORK"

echo "== backup current SPI contents first! =>"
echo "   dd if=/dev/mtd0 of=spi-backup.bin bs=64k"

[ -f "$WORK/boot0_spinor.fex" ] || curl -fL -o "$WORK/boot0_spinor.fex" "$BOOT0_URL"
echo "== dumping SD boot area from $SD_DEV =="
dd if="$SD_DEV" of="$WORK/sd-area.bin" bs=1M count=20 status=none

python3 - "$WORK/boot0_spinor.fex" "$WORK/sd-area.bin" "$OUT" <<'EOF'
import sys
boot0_p, card_p, img_p = sys.argv[1:4]
img = bytearray(b'\xff' * 16 * 1024 * 1024)

b0 = open(boot0_p, 'rb').read()
assert b0[4:12] == b'eGON.BT0', 'boot0 has no eGON header'
assert len(b0) <= 0x10000
img[0:len(b0)] = b0

card = open(card_p, 'rb').read()
off = 0x1004000                     # bs=8k seek=2050 in Xunlong platform_install.sh
assert card[off:off+13] == b'sunxi-package', 'boot_package magic not found on SD'
pkg = card[off:off + 2*1024*1024]
img[0x10000:0x10000+len(pkg)] = pkg  # CONFIG_SPINOR_UBOOT_OFFSET=128 -> 0x10000

open(img_p, 'wb').write(img)
print(f'built {img_p}: boot0 {len(b0)} B, package {len(pkg)} B')
EOF
echo "== now run flash-spi.sh (as root) =="
