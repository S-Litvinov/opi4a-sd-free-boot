# [SOLVED] SD-free boot on Orange Pi 4A (T527): SPI NOR bootloader + NVMe, stock vendor stack — no mainline, no SDK

> **Authorship / attribution.** This boot chain was reverse-engineered, built and verified in one
> hands-on session by an AI agent — **Hermes** (Nous Research agent harness) running
> **Qwen3.8-Flash-Next**, on the machine of **Sergei Litvinov** (who supplied the hardware, the UART
> probe, the power cycles and the sudo password). Published with both names on purpose: the agent did
> the debugging, the human did the soldering-adjacent parts. Corrections and PRs welcome; please keep
> both names if you reuse the write-up.
>
> Repository contents: `README.md` (full write-up below), `boot.cmd.nvme` (final boot script),
> `scripts/` (SPI image builder / flasher, bootscr installer — sanitized, variables at the top),
> **`hdmi-troubleshooting.md` + `hdmi-kiosk/`** — why the HDMI shows "No signal" on this BSP
> (it is not your boot chain) and an on-demand weston emergency console that fixes it.

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

### 2. `ERROR: status = 13` on large NVMe reads — PRP bug in the 2018 u-boot driver

> **Correction (Nov 15).** The first version of this write-up blamed this on the SSD needing ~20 s to
> "settle" after power-on, and recommended `sleep 8`. That was wrong — sorry for the bad epidemiology.
> With the real fix below, a cold boot reads 24 MB in 69 ms on the *first* attempt, with zero sleeps.

`status = 13` is printed in hex. **0x13 is the NVMe generic command status "PRP Offset Invalid"** —
and it is a *host-side* bug, not the drive. The 2018-generation u-boot NVMe driver takes its 512-byte
PRP list pool from plain `malloc()`. A PRP list may not cross a 4 KiB memory-page boundary, so when
the malloc'd pool straddles a page, every read command needing more entries than fit before the
boundary gets rejected by the SSD (~220 KB at this drive's MDTS = 256 KB). Small files (1.7 KB
boot.scr) sail through; the 24 MB uImage dies. Where the pool lands depends on the heap history —
SD card in/out, HDMI plugged/unplugged, manual vs distro scan — which is exactly why the same board
"boots with the card, boot-loops without it", and why it flips between days. This also explains most
of the "T527/A523 NVMe works in Linux but not in u-boot" reports across the ecosystem.

A/B/C proof from the u-boot console: pointing `dev->prp_pool` at `0x4ffffe10` (straddling) makes a
256 KB read fail twice with `status = 13` while a 252 KB read still passes — the exact PRP-entry
boundary; moving the same pointer to a page-aligned address fixes everything, deterministically.

Upstream fixed this in 2019 — U-Boot commit `b21dcebfa6` ("nvme: Fix PRP Offset Invalid"). Xunlong's
BSP u-boot (2018.05-t527, built Apr 2025) predates it. Two ways to live with that:

**A. Runtime hot-fix, no reflashing** — boot script **v4** (see `boot.cmd.nvme`, marker `spi-boot-v4`):
finds the driver's `struct nvme_dev` in the heap by its BAR0 pointer signature and repoints
`prp_pool` to a page-aligned scratch page; if the struct cannot be located, falls back to loading
kernel/initrd in 8 KiB chunks (two pages per command need no PRP list at all — slow but bulletproof).
The fix runs before any large read; the kernel cmdline reports what happened
(`spiboot.prp=<pool page offset> spiboot.fix=<0/1>`).

**B. The real cure — binary-apply the upstream patch to the shipped u-boot and reflash SPI
NOR** — no toolchain needed. See `uboot-prp-fix/patch_nvme_prp_bin.py` and the last section.

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

## The boot script (NVMe), v4 — save as boot.cmd, compile, place on NVMe **and** SD

Full script in this repo as `boot.cmd.nvme` (v4). Skeleton with the parts that matter:

```
echo NVMe boot v4
if itest.s x${devtype} == xnvme; then echo nvme-scanned-by-distro; else pci enum; nvme scan; fi
# --- PRP hot-fix: find struct nvme_dev (signature = BAR0 pointers) walking down from
#     the admin CQ register, repoint dev->prp_pool to a page-aligned scratch page ---
setexpr.l a *0x22100030
...
while itest ${a} != ${e}; do setexpr a ${a} - 4; if itest.l *${a} == 0x22101000; then ...; fi; done
mw.l ${field} 0x48000000          # dev->prp_pool = page-aligned
setenv fixed 1

# per file: fast load if the fix applied, else 8K-chunk fallback (no PRP lists ever)
load nvme 0:1 ${addr} ${file}     # or chunked load ${file} 0x2000 <pos>

mw.l 0x22100014 0                 # NVMe CC.EN = 0 before bootm (pitfall #1)
fdt addr 0x43000000; fdt resize 65536
bootm 0x41000000 0x46000000:${filesize} 0x43000000
```

Every statement is one line on purpose, so it can be pasted into the serial console line by line.

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

Final state — SPI image with the binary PRP fix (see next section), boot script v4 as safety net:

```
[152]HELLO! BOOT0 is starting!
[08.074]workmode = 0,storage type = 3          <- storage type 3 = SPI NOR
No MMC device available                        <- no card anywhere
Scanning nvme 0:1...
3566 bytes read in 0 ms                        <- GPT + boot.scr read fine
NVMe boot v4
prp-pool bbe5e000 moved to 0x48000000          <- pool offset is 0x000: memalign worked,
                                                  the hot-fix now relocates an already-good pool
24877632 bytes read in 70 ms (338.9 MiB/s)     <- kernel: first try, full speed, zero sleeps
13358802 bytes read in 38 ms (335.3 MiB/s)
Verifying Checksum ... OK  (x2)
Starting kernel ...
<your-hostname> login:
```

Kernel cmdline ends with `spi-boot-v4 spiboot.prp=0 spiboot.fix=1`; root is `/dev/nvme0n1p1`,
no `/dev/mmcblk*` exists, HA is up in ~60 s.

## The cure: binary-apply the upstream PRP fix (no rebuild)

A full rebuild of Xunlong's `v2018.05-t527` branch is possible on the board itself
(in-tree, `make CROSS_COMPILE=arm-linux-gnueabi-` as a make *argument*, `KCFLAGS=-Wno-error`
for gcc-13, `DTC=/usr/bin/dtc`) — but the resulting image sat silent on our board: boot0
reached "Jump to second Boot" and nothing printed after it. The BSP packaging has private
touches (the packer injects PMU regulator values into the appended dtb that are not in the
git tree), so chasing the delta across toolchain generations looked like the wrong trade.

The binary patch applies the same semantics as upstream `b21dcebfa6` directly to the
shipped payload, **40 bytes, two in-place rewrites, no code cave**
(`uboot-prp-fix/patch_nvme_prp_bin.py <in.bin> <out.bin>`):

- `nvme_probe`: `malloc(512)` → `memalign(4096, 512)` (u-boot's own dlmalloc), storing
  `prp_pool` + `prp_entry_num` with one `strd`; the original NULL-check error path is kept.
- `nvme_setup_prps` realloc path: `malloc(nprps<<3)` → `memalign(4096, nprps<<3)`. The
  preceding `free()` stays valid — dlmalloc's `free()` accepts `memalign()` pointers.
  (Minor casualty: the out-of-memory `printf` loses 4 bytes and is dropped; `-ENOMEM`
  is still returned.)

Sites are found by byte patterns (probe alloc, realloc sequence, dlmalloc `memalign`
prologue) and the injected branches are re-encoded for whatever addresses your dump has,
so it works against *your* board's SPI image, not just ours.

How it was validated before touching flash:

1. **Emulation** — Unicorn, ARM/Thumb: both patched sites executed against instrumented
   `memalign/free/printf`, including the allocation-failure paths (correct branch targets,
   `-ENOMEM` intact).
2. **Live hot-patch, zero writes** — from the serial console of a *known-good* boot the
   exact patch bytes were written into the relocated u-boot image in RAM, caches evicted
   with a big `crc32`, then real NVMe loads ran through the patched driver
   (`uImage` 24 MB CRC-exact, forced realloc path via shrinking `dev->prp_entry_num`,
   heap sane afterwards), and the board was `reset` back to normal boot.
3. Only then: flash the patched image (backup first, readback verify — `flash-spi.sh`)
   and cold-boot without the card (log above).

One packaging gotcha worth knowing: boot0 caches its DRAM training into a NORPARAM block
(`bootpara` magic at `0xf800`) on early boots, so a fresh SPI dump no longer hashes equal
to the image you flashed — always diff and re-base on the *live* dump, and keep a dump of
every state (the flash script does this for you).


## Caveats / not covered

- Vendor stack only (1.0.4 image). Mainline situation is a separate story (and A523 SPI in mainline u-boot/Linux is still incomplete per sunxi-tools#217).
- `mw.l` hardcodes BAR0; if you change kernel/dtb addresses, keep them out of each other (uImage 0x41000000, dtb 0x43000000, initrd 0x46000000 are the vendor defaults I reused).
- I kept the SD slot warm with a labeled spare card; nothing about the setup forces you to throw it away.

Curious whether this also un-bricks the "boot from NVMe" saga on Cubie A5E with its vendor stack — same die, the layout constants come from the same Kconfig, only `boot0_spinor`/`boot_package` differ.

Feedback welcome — especially from anyone who has seen `status = 13` on other Allwinner PCIe boards.
