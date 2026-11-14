# [SOLVED] SD-free boot on Orange Pi 4A (T527): SPI NOR bootloader + NVMe, stock vendor stack — no mainline, no SDK

> **Authorship / attribution.** This boot chain was reverse-engineered, built and verified in one
> hands-on session by an AI agent — **Hermes** (Nous Research agent harness) running
> **Qwen3.8-Flash-Next**, on the machine of **Sergei Litvinov** (who supplied the hardware, the UART
> probe, the power cycles and the sudo password). Published with both names on purpose: the agent did
> the debugging, the human did the soldering-adjacent parts. Corrections and PRs welcome; please keep
> both names if you reuse the write-up.
>
> Repository contents: `README.md` (full write-up below), `boot.cmd.nvme` (final boot script),
> `scripts/` (SPI image builder / flasher, bootscr installer — sanitized, variables at the top).

**TL;DR** — My OPi 4A boots fully without a microSD card: BROM → SPI NOR (boot0_spinor + stock u-boot) → kernel/initrd/rootfs all on NVMe. Everything built from publicly available Xunlong blobs on the stock 1.0.4 vendor stack (u-boot 2018.07 + BSP 5.15). Two non-obvious pitfalls cost most of the evening; both have clean fixes.

Target audience: anyone who has read "SPI doesn't work for now" / "boot ROM only loads from SD/eMMC" around this SoC family and stopped there. It does work, today, without the gated Allwinner SDK.

---

## Starting situation

- Orange Pi 4A, T527 (sun55iw3), 4 GB, Ubuntu 24.04 vendor image 1.0.4, rootfs on a 120 GB NVMe in the M.2 slot.
- Recurring microSD death (~every 6 months). I wanted the card out of the boot chain entirely.
- SPI NOR: XMC XM25QU128C, 16 MB, empty. UART console strongly recommended (3 pins near the power button, 115200 8N1).

## The two pitfalls nobody mentions

### 1. Kernel `nvme: Removing after probe failure status: -22` when u-boot loads the kernel from NVMe

When u-boot's `nvme scan` has been used, the controller is handed to the kernel still **enabled** (CC.EN=1, admin queues pointing into u-boot's memory). The vendor 5.15 driver then fails probe with EINVAL and root never appears (`Waiting for root device ...` forever / RCU stalls with initrd).

**Fix** — do what the driver's remove() path does, from the u-boot console or a boot script, right before `bootm`:

```
# BAR0 of the NVMe endpoint on this board is 0x22100000 (check with: pci bar 1:00.0)
mw.l 0x22100014 0      # NVMe register CC = 0 (clears EN)
```

After this the kernel initializes the exact same drive normally (`nvme0n1: p1`, queues, HMB...). This single write is the difference between "NVMe boot is impossible" and it working. (On manual `bootm` you also need `fdt addr <dtb>` + `fdt resize 65536` or you get `FDT_ERR_NOSPACE` when injecting bootargs.)

### 2. NVMe silently fails LARGE reads for the first ~20 seconds after power-on

Symptom: u-boot auto-boot can read a 434-byte file from NVMe but fails on the 25 MB uImage with `ERROR: status = 13, phase = 1 ... fs_devread read error - block` (completion timeout). Interrupt autoboot, wait ~30 s, load the same file — 3/3 success, `crc32` stable. So it is neither DRAM nor the bootloader: the drive (SMI-based, vendor id 0x126f) simply is not ready for big DMA transfers right after PERST. Any "SPI boot is broken / kernel panics from SPI" reports I had seen are very likely this.

**Fix**: a settle delay + one retry in the boot script (below).

## SPI NOR layout — what BROM actually accepts (verified on hardware)

- BROM reads SPI NOR starting at **offset 0**, standard `eGON.BT0` header (confirmed: boot0 banner appears with no card inserted).
- This u-boot/SPL family expects on SPI: boot0 at `0x0`, and the `sunxi-package` (TOC1 boot_package with u-boot+monitor+scp+dtb) at **0x10000** (`CONFIG_SPINOR_UBOOT_OFFSET=128` × 512 B).
- **No boot_param (NORPARAM) region is required** — boot0 prints `boot param - magic error` and boots fine.
- boot0's SPI support prints `spinor id is: ...` and reads the TOC (`The size of toc is ...`, `Entry_name = u-boot/monitor/scp/dtb`, `Jump to second Boot`).

Where the blobs come from (no SDK needed):

- `boot0_spinor.fex` for sun55iw3 ships in Xunlong's own build repo:
  `orangepi-build` (branch `next`), path `external/packages/pack-uboot/sun55iw3/bin/boot0_spinor.fex` (eGON at offset 0, 61 KB, supports the onboard chip).
- `boot_package` — carve it **from your own SD card image dump** at offset `0x1004000` (that's `dd bs=8k seek=2050` in Xunlong's `platform_install.sh`). Use your card's own copy, it matches your exact BSP version.
- DRAM parameters: untouched — the card's boot0 and the SPI boot0 are both Allwinner's generic blobs with runtime training; on the 4 GB board training completed and memtest passed.

Assemble a 16 MB image (run on the board from a running system; `/dev/mtd0` is exposed by the vendor kernel):

```bash
dd if=/dev/mmcblk1 of=sd-area.bin bs=1M count=20          # your card's boot area
# download boot0_spinor.fex from orangepi-build next as above
python3 - <<'EOF'
img = bytearray(b'\xff' * 16 * 1024 * 1024)
img[0:61440] = open('boot0_spinor.fex','rb').read()
card = open('sd-area.bin','rb').read()
assert card[0x1004000:0x1004000+13] == b'sunxi-package'
img[0x10000:0x10000+2*1024*1024] = card[0x1004000:0x1004000+2*1024*1024]
open('spi-image-16m.bin','wb').write(img)
EOF
sudo dd if=spi-image-16m.bin of=/dev/mtdblock0 bs=1M conv=fsync
# verify against the RAW chip (mtdblock is cached — use the character device):
dd if=/dev/mtd0 of=/tmp/rb.bin bs=64k status=none
cmp spi-image-16m.bin /tmp/rb.bin && echo SPI-VERIFY-OK
```

Back up the SPI contents (`dd if=/dev/mtd0 ...`) before you start. Recovery is trivial anyway: BROM tries SD first — keep your old card as a bootable spare, erase SPI with `flash_erase`/dd-FF whenever.

## The boot script (NVMe), v2 — save as boot.cmd, compile, place on NVMe **and** SD

```
setenv bootargs "root=UUID=<NVME_ROOT_UUID> rootwait rootfstype=ext4 \
earlycon=uart8250,mmio32,0x02500000 console=ttyAS0,115200 console=tty1 \
consoleblank=0 loglevel=4 clk_ignore_unused swiotlb=65536 net.ifnames=0 \
cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1"

echo NVMe boot v2
pci enum
nvme scan
sleep 8
if load nvme 0:1 0x41000000 /boot/uImage; then echo kern-ok; else sleep 10; load nvme 0:1 0x41000000 /boot/uImage; fi
if load nvme 0:1 0x43000000 /boot/dtb/allwinner/sun55i-t527-orangepi-4a.dtb; then
        if load nvme 0:1 0x46000000 /boot/uInitrd; then
                mw.l 0x22100014 0
                fdt addr 0x43000000
                fdt resize 65536
                bootm 0x41000000 0x46000000:${filesize} 0x43000000
        fi
fi

echo NVMe boot FAILED - falling back to SD boot.scr.orig
mmc dev 1
if load mmc 1 0x49000000 boot.scr.orig; then
        source 0x49000000
fi
reset
```

Compile and deploy:

```bash
mkimage -C none -A arm -T script -d boot.cmd boot.scr
# NVMe: into /boot/boot.scr of the rootfs itself (distro boot finds it there);
# disable the stale /boot/extlinux there so script wins.
# SD:  replace /boot/boot.scr, keeping the stock one as boot.scr.orig.
```

Notes:
- **uInitrd is mandatory** — the vendor kernel has ext4 as a module; booting root by UUID without initrd hangs at `Waiting for root device`.
- With the SD card inserted, `boot_targets` (mmc before nvme) keeps the old SD path in charge — nothing changes if the card is present. The SPI path only becomes primary when the card is absent (or dies). That asymmetry is a feature: the card is your undo button.
- BAR0 `0x22100000` is the fixed PCIe window base for this SoC; confirm with `pci bar 1:00.0` on your setup.

## Verified result (cold boot, no card, first try)

```
[152]HELLO! BOOT0 is starting!
[7367]spinor id is: 20 41 18, read cmd: 03
[7376]The size of toc is 1d4000.
[8015]Jump to second Boot.
U-Boot 2018.07-orangepi ...
NVMe boot v2
kern-ok
...
<your-hostname> login:
root: /dev/nvme0n1p1, no /dev/mmcblk* present, HA up ~60 s
```

## Caveats / not covered

- Vendor stack only (1.0.4 image). Mainline situation is a separate story (and A523 SPI in mainline u-boot/Linux is still incomplete per sunxi-tools#217).
- `mw.l` hardcodes BAR0; if you change kernel/dtb addresses, keep them out of each other (uImage 0x41000000, dtb 0x43000000, initrd 0x46000000 are the vendor defaults I reused).
- I kept the SD slot warm with a labeled spare card; nothing about the setup forces you to throw it away.

Curious whether this also un-bricks the "boot from NVMe" saga on Cubie A5E with its vendor stack — same die, the layout constants come from the same Kconfig, only `boot0_spinor`/`boot_package` differ.

Feedback welcome — especially from anyone who has seen `status = 13` on other Allwinner PCIe boards.
