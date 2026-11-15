#!/usr/bin/env bash
# install-sd-free.sh — Orange Pi 4A (T527): detach boot from microSD in one shot.
#   Preview everything (read-only):   curl -fsSL https://raw.githubusercontent.com/S-Litvinov/opi4a-sd-free-boot/main/install-sd-free.sh | sudo bash
#   Apply:                            ... same command ... | sudo bash -s -- --install
#   After reboot, from the board:     ... same command ... | sudo bash -s -- verify
#
# What it does: writes u-boot (with the upstream PRP fix binary-applied) into SPI NOR,
# assembled from YOUR OWN SD card's boot_package + Xunlong's boot0_spinor, installs the
# NVMe boot script (v4) and shows you how to verify. Nothing on the NVMe OS is touched
# except /boot/boot.scr (backup kept) and SD's boot.scr (kept as boot.scr.orig).
#
# Prerequisite: your OS must ALREADY be on the NVMe (root=/dev/nvme...). If it is still
# on the SD card, first move it with the vendor tool: `nand-sata-install` (or
# orangepi-config -> Boot Media), reboot, confirm `findmnt /` shows nvme, then run this.
set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/S-Litvinov/opi4a-sd-free-boot/main"
TARBALL="https://codeload.github.com/S-Litvinov/opi4a-sd-free-boot/tar.gz/refs/heads/main"
WORK=/root/opi4a-sd-free
MODE="${1:-check}"
[ "$MODE" = "--install" ] && MODE=install

log() { printf '\n== %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
# NOTE: read the answer from the TERMINAL, never from stdin.
# The documented one-liner is  curl ... | sudo bash -s -- --install  -> stdin IS this
# script, so a plain `read` swallows the next line of the script instead of the user's
# answer (verified: it consumed the following `dd` line, then aborted with "nothing written").
ask()  {
    [ "$MODE" = install ] || return 0
    printf '%s [y/N] ' "$1"
    local a=""
    if [ -r /dev/tty ]; then
        read -r a < /dev/tty || a=""
    else
        echo >&2
        echo "ERROR: no terminal available to answer the confirmation prompt." >&2
        echo "       Download the script to a file and run it from there:" >&2
        echo "         curl -fsSL -o install-sd-free.sh <url>" >&2
        echo "         sudo bash install-sd-free.sh --install" >&2
        return 1
    fi
    [ "$a" = y ] || [ "$a" = Y ]
}

# ------------------------------------------------------------------ verify mode
if [ "$MODE" = verify ]; then
    cmd=$(cat /proc/cmdline)
    case "$cmd" in
      *spi-boot-v4*) echo "SPI+NVMe boot path ACTIVE. root=$(findmnt -no SOURCE /)  markers: $(echo "$cmd" | tr ' ' '\n' | grep -E 'spi-boot|spiboot')" ;;
      *)  if findmnt -no SOURCE / | grep -q nvme; then
              echo "root is on NVMe but boot script marker missing — you are probably still booting via the SD card's stock boot.scr."
          else echo "still booting the stock way (root=$(findmnt -no SOURCE /))."; fi ;;
    esac
    exit 0
fi

# ------------------------------------------------------------------ checks
[ "$(id -u)" = 0 ] || die "run with sudo (curl ... | sudo bash)"
log "checks"
grep -qa 'sun55iw3' /proc/device-tree/compatible 2>/dev/null || \
    die "this does not look like an Orange Pi 4A (T527) — compatible: $(cat /proc/device-tree/compatible 2>/dev/null | tr -d '\0')"
have python3 && have curl || die "python3+curl required (apt-get install -y python3 curl)"
[ -e /dev/mtd0 ] || die "/dev/mtd0 missing — SPI NOR not exposed by this kernel"
MTDSZ=$(awk '/^mtd0:/{print $2}' /proc/mtd)
[ "$MTDSZ" = "01000000" ] || die "SPI NOR is not 16 MiB ($MTDSZ) — aborting"
ROOTSRC=$(findmnt -no SOURCE /)
case "$ROOTSRC" in
  /dev/nvme*) : ;;
  /dev/mmcblk*) die "root is on the SD card ($ROOTSRC). Move the OS to NVMe first (nand-sata-install), reboot, then rerun." ;;
  *) die "root device $ROOTSRC not understood" ;;
esac
ROOTUUID=$(blkid -o value -s UUID "$ROOTSRC")
[ -n "$ROOTUUID" ] || die "cannot read root UUID"
for f in /boot/uImage /boot/uInitrd; do
    [ -e "$f" ] || die "$f missing on the NVMe root — install mode needs /boot populated (vendor layout)"
done
DTB=$(ls /boot/dtb/allwinner/*orangepi-4a*.dtb 2>/dev/null | head -1)
[ -n "$DTB" ] || die "no /boot/dtb/allwinner/*orangepi-4a*.dtb found"
echo "board OK; root=$ROOTSRC (UUID=$ROOTUUID); kernel=/boot/uImage; dtb=$DTB"

SD=""
for d in $(lsblk -dn -o NAME,RM,TYPE | awk '$2==1 && $3=="disk" && $1 ~ /^mmcblk/ {print $1}'); do
    SD=$d; done
if [ -n "$SD" ]; then
    echo "SD card present: /dev/$SD (it will get the same boot.scr as a fallback copy; its stock boot.scr is kept as boot.scr.orig)"
else
    echo "no SD card detected — SPI will be your only firmware path (that is fine; the backup is your undo button)"
fi

SPI_CUR=$(dd if=/dev/mtd0 bs=64k status=none | sha256sum | cut -d' ' -f1)
SPI_MAGIC=$(dd if=/dev/mtd0 bs=1 count=1 status=none | od -An -tx1 | tr -d ' \n')
# The 0xf800-0xffff NORPARAM block holds boot0's board-local DRAM training cache
# ("bootpara"), written by boot0 on the first boot of THIS board. It is the only
# board-specific part of the image, so ignore it when comparing against the
# released artifact (which ships it erased, so any other board trains its own).
SPI_CUR_NORPARAM=$(python3 -c '
import hashlib, sys
try:
    d = bytearray(open("/dev/mtd0", "rb").read())
except OSError:
    sys.exit(0)
d[0xf800:0x10000] = b"\xff" * 0x800
print(hashlib.sha256(bytes(d)).hexdigest())' 2>/dev/null || true)
if [ "$SPI_CUR" = 31ec3781a5a9986560ef983fdb8f0b693e0f2222a0af6d3a6239f2421da30983 ] ||
   [ "$SPI_CUR_NORPARAM" = 31ec3781a5a9986560ef983fdb8f0b693e0f2222a0af6d3a6239f2421da30983 ]; then
    echo "SPI already contains this exact PRP-fixed image (1.0.4 prebuilt)"
elif [ "$SPI_MAGIC" = de ] || [ "$SPI_MAGIC" = ee ]; then   # 0xde = Allwinner eGON.BT0 header
    echo "SPI currently holds a bootloader (sha $SPI_CUR...) — it will be backed up before overwrite"
elif [ "$SPI_MAGIC" = ff ]; then
    echo "SPI is empty/factory"
else
    echo "SPI contents unclear (first byte $SPI_MAGIC, sha $SPI_CUR...) — backup covers you either way"
fi
if [ "$MODE" != install ]; then
    log "preview only — nothing was written"
    echo "Re-run with --install to: back up SPI -> write u-boot (PRP-fixed) to SPI NOR -> install boot.scr v4 on NVMe${SD:+ and on the SD card}."
    exit 0
fi

# ------------------------------------------------------------------ fetch tooling
log "fetch repo"
mkdir -p "$WORK"; cd "$WORK"
curl -fsSL "$TARBALL" -o pkg.tgz
tar xzf pkg.tgz --strip-components=1 -C "$WORK"
[ -f uboot-prp-fix/patch_nvme_prp_bin.py ] && [ -f bin/boot0_spinor.fex ] && [ -f boot.cmd.nvme ] || die "repo contents missing"

# ------------------------------------------------------------------ build SPI image
log "build SPI image"
IMG=$WORK/spi-final-16m.bin
BUILT=custom
if [ -n "$SD" ]; then
    dd if=/dev/$SD of=$WORK/sd-area.bin bs=1M count=21 status=none
    python3 - "$WORK" <<'PYEOF'
import sys
w = sys.argv[1]
img = bytearray(b'\xff' * 16 * 1024 * 1024)
img[0:61440] = open(w + '/bin/boot0_spinor.fex', 'rb').read()
card = open(w + '/sd-area.bin', 'rb').read()
assert card[0x1004000:0x1004000 + 13] == b'sunxi-package', 'boot_package not found on your SD at 0x1004000'
img[0x10000:0x10000 + 2 * 1024 * 1024] = card[0x1004000:0x1004000 + 2 * 1024 * 1024]
open(w + '/spi-custom-16m.bin', 'wb').write(img)
print('custom image assembled from your own card')
PYEOF
    if python3 uboot-prp-fix/patch_nvme_prp_bin.py "$WORK/spi-custom-16m.bin" "$IMG" >"$WORK/patch.log" 2>&1; then
        cat "$WORK/patch.log"
    else
        echo "NOTE: your u-boot build is not recognized by the pattern-based patcher:"
        tail -3 "$WORK/patch.log"
        BUILT=prebuilt
    fi
else
    BUILT=prebuilt
fi
if [ "$BUILT" = prebuilt ]; then
    VER=$([ -r /etc/orangepi-release ] && sed -n 's/^VERSION=//p' /etc/orangepi-release || echo unknown)
    [ "$VER" = "1.0.4" ] || echo "WARNING: prebuilt image is for the stock 1.0.4 vendor stack; you report VERSION=$VER"
    ask "fall back to the prebuilt PRP-fixed image for the 1.0.4 stack?" || die "aborted"
    # SHA256SUMS.txt lists BARE file names while the images live in bin/ -> run sha256sum
    # from inside bin/, otherwise --ignore-missing skips the file and sha256sum exits 1
    # ("no file was verified"), so the check never passes.
    ( cd bin && sha256sum -c --ignore-missing <(grep spi-image-16m-prp SHA256SUMS.txt) ) || die "prebuilt sha mismatch"
    cp bin/spi-image-16m-prp-1.0.4.bin "$IMG"
fi
FINAL_SHA=$(sha256sum "$IMG" | cut -d' ' -f1)

# ------------------------------------------------------------------ flash SPI
log "flash SPI NOR"
BK=/root/spi-backup-$(date +%Y%m%d-%H%M%S).bin
dd if=/dev/mtd0 of="$BK" bs=64k status=none
echo "SPI backup: $BK (sha $(sha256sum "$BK" | cut -c1-16)...)  <-- copy it to your PC now:  scp <user>@$(hostname -I | awk '{print $1}'):$BK ."
ask "write $FINAL_SHA to SPI NOR?" || die "aborted, nothing written (backup: $BK)"
dd if="$IMG" of=/dev/mtdblock0 bs=1M status=none
sync
RB=$(dd if=/dev/mtd0 bs=64k status=none | sha256sum | cut -d' ' -f1)
if [ "$RB" != "$FINAL_SHA" ]; then
    echo "readback MISMATCH ($RB) — restoring backup"
    dd if="$BK" of=/dev/mtdblock0 bs=1M status=none; sync
    die "flash failed and was rolled back"
fi
echo "SPI flashed and verified by readback."

# ------------------------------------------------------------------ fstab: SD mounts must never block boot
log "/etc/fstab: mark SD mounts optional (nofail)"
SDUUID=""
[ -n "$SD" ] && [ -b /dev/${SD}p1 ] && SDUUID=$(blkid -o value -s UUID /dev/${SD}p1)
cp -a /etc/fstab /etc/fstab.pre-sdfree.bak
python3 - "$SDUUID" <<'PYEOF'
import sys
sd = sys.argv[1]
out, changed = [], 0
for line in open('/etc/fstab'):
    f = line.split()
    if len(f) >= 4 and not f[0].startswith('#'):
        mp, dev, opts = f[1], f[0], f[3]
        sd_related = ('mmc' in dev.lower() or 'mmc' in mp.lower()
                      or (sd and dev == 'UUID=' + sd))
        if sd_related and 'nofail' not in opts:
            opts2 = opts + ',nofail,x-systemd.device-timeout=10s'
            if mp == '/boot' and '/mmcboot' not in opts:
                opts2 += ',x-systemd.mount-after=/media/mmcboot'
            line = line.replace(f[3], opts2, 1)
            changed += 1
    out.append(line)
open('/etc/fstab', 'w').writelines(out)
print('%d fstab line(s) patched with nofail' % changed)
PYEOF

# ------------------------------------------------------------------ boot.scr v4 on NVMe (+SD)
log "install boot.scr (NVMe)"
if ! have mkimage; then
    apt-get install -y u-boot-tools >/dev/null || die "apt install u-boot-tools failed"
fi
sed "s|<NVME_ROOT_UUID>|$ROOTUUID|" boot.cmd.nvme > "$WORK/boot.cmd"
mkimage -T script -C none -n "NVMe boot v4" -d "$WORK/boot.cmd" "$WORK/boot.scr" >/dev/null
# if /boot is a bind-mount from the SD card (vendor fstab), detach it to reach the NVMe /boot
if findmnt -no SOURCE /boot 2>/dev/null | grep -q mmcblk; then
    umount /boot /media/mmcboot
    echo "(/boot bind-mount from SD detached — NVMe /boot is the real one now)"
fi
[ -f /boot/boot.scr ] && cp -a /boot/boot.scr /boot/boot.scr.pre-sdfree.bak
install -m 644 "$WORK/boot.scr" /boot/boot.scr
[ -f /boot/extlinux/extlinux.conf ] && mv /boot/extlinux/extlinux.conf /boot/extlinux/extlinux.conf.disabled
echo "/boot/boot.scr installed (marker: spi-boot-v4); stale extlinux disabled"
if [ -n "$SD" ] && [ -b /dev/${SD}p1 ]; then
    mkdir -p /media/sdfree-tmp
    if mount /dev/${SD}p1 /media/sdfree-tmp; then
        if [ -f /media/sdfree-tmp/boot/boot.scr ] && [ ! -f /media/sdfree-tmp/boot/boot.scr.orig ]; then
            cp -a /media/sdfree-tmp/boot/boot.scr /media/sdfree-tmp/boot/boot.scr.orig
        fi
        [ -f /media/sdfree-tmp/boot/boot.scr.orig ] && install -m 644 "$WORK/boot.scr" /media/sdfree-tmp/boot/boot.scr
        sync; umount /media/sdfree-tmp
        echo "SD fallback boot.scr updated (stock kept as boot.scr.orig)"
    fi
fi

log "done"
cat <<'EOF'
Final test (the moment of truth):
  1. sudo poweroff, unplug power, REMOVE the microSD card, wait 10 s, power on.
  2. Watch UART (115200 8N1) or wait ~60 s and check:  install-sd-free.sh verify
     (i.e. curl -fsSL <the URL above> | sudo bash -s -- verify)
Undo if anything is wrong: boot with the SD card inserted and run:
  sudo dd if=<your spi-backup file> of=/dev/mtdblock0 bs=1M
EOF
