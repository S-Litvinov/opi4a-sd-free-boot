#!/usr/bin/env python3
# patch_nvme_prp_bin.py - binary-apply upstream u-boot b21dcebfa6 ("nvme: Fix PRP Offset
# Invalid") to a shipped Allwinner T527 sunxi-package SPI image. No toolchain needed.
#
# The 2018 vendor NVMe driver takes its PRP list pool from malloc(); a PRP list must not
# cross a 4 KiB page, so a straddling pool makes the SSD reject big reads with
# "ERROR: status = 13" (0x13 = PRP Offset Invalid). Upstream fix: memalign(page, size).
#
# Two sites are rewritten IN PLACE (no cave). dlmalloc's free() accepts memalign() pointers,
# so the realloc path's free() stays valid. Verified on u-boot 2018.07-orangepi (image
# 1.0.4, built Apr 2025); everything is located by byte pattern, not by fixed offset:
#   nvme_probe:      prp_pool = malloc(512)         -> memalign(4096, 512)
#   nvme_setup_prps: prp_pool = malloc(nprps << 3)  -> memalign(4096, nprps << 3)
#
# usage: patch_nvme_prp_bin.py <in.spi16m> <out.spi16m>
import sys, re, struct, hashlib

BASE   = 0x4A000640   # VA of payload byte 0 (file offset 0x10E40 in the image)
PSTART = 0x10E40      # u-boot payload start inside the SPI image
TOC1   = 0x10000

RE_MEMALIGN = re.compile(rb'\x2d\xe9\xf8\x45\xb1\xf1\x00\x0a\x05\x46\x03\xda'
                         rb'\x00\x24\x20\x46\xbd\xe8\xf8\x85')              # dlmalloc memalign prologue
# probe:   mov.w r0,#0x200 ; bl malloc ; str.w r0,[r4,#0x94] ; cmp r0,#0 ; beq err ; movs r3,#0x40 ; str.w r3,[r4,#0x98]
RE_PROBE   = re.compile(rb'\x4f\xf4\x00\x70....\xc4\xf8\x94\x00\x00\x28(..)\x40\x23\xc4\xf8\x98\x30', re.S)
# realloc: ldr.w r0,[r4,#0x94] ; bl free ; lsls r0,r6,#3 ; bl malloc ; str.w r0,[r4,#0x94] ; cbnz ; ldr r0,[pc] ; bl printf
RE_REALLOC = re.compile(rb'\xd4\xf8\x94\x00....\xf0\x00....\xc4\xf8\x94\x00\x60\xb9\x4d\x48....', re.S)

def bl_encode(addr, target):
    # ARMv7-M B/BL (T4): imm32 = SignExtend(S:I1:I2:imm10:imm11:'0'), S at bit24 (±16 MiB)
    off = target - (addr + 4)
    assert -(1 << 24) <= off < (1 << 24), 'branch out of range'
    s = 1 if off < 0 else 0
    x = off if off >= 0 else off + (1 << 25)
    i1, i2 = (x >> 23) & 1, (x >> 22) & 1
    h1 = 0xF000 | (s << 10) | ((x >> 12) & 0x3FF)
    h2 = 0xF000 | ((1 - (i1 ^ s)) << 13) | ((1 - (i2 ^ s)) << 11) | ((x >> 1) & 0x7FF)
    return h1.to_bytes(2, 'little') + h2.to_bytes(2, 'little')

def bl_decode(addr, b):
    h1, h2 = int.from_bytes(b[0:2], 'little'), int.from_bytes(b[2:4], 'little')
    assert (h1 & 0xF800) == 0xF000 and (h2 & 0xD000) == 0xD000, 'not a bl'
    s = (h1 >> 10) & 1
    i1, i2 = 1 - (((h2 >> 14) & 1) ^ s), 1 - (((h2 >> 12) & 1) ^ s)
    imm = (s << 24) | (i1 << 23) | (i2 << 22) | ((h1 & 0x3FF) << 12) | ((h2 & 0x7FF) << 1)
    if s: imm -= 1 << 25
    return addr + 4 + imm

# self-test against encodings emitted by the shipping toolchain
for a, t, want in ((0x4A02D320, 0x4A01B178, bytes.fromhex('edf72aff')),
                   (0x4A02CEBC, 0x4A01B178, bytes.fromhex('eef75cf9'))):
    assert bl_encode(a, t) == want, (hex(a), hex(t), bl_encode(a, t).hex())
    assert bl_decode(a, want) == t
assert bl_encode(0x4A02D322, 0x4A01B8F8) == bytes.fromhex('eef7e9fa')   # the exact branch we inject

def main(src, dst):
    img = bytearray(open(src, 'rb').read())
    assert len(img) == 16 * 1024 * 1024, 'need a 16 MiB SPI image'
    assert img[TOC1:TOC1 + 13] == b'sunxi-package', 'no TOC1 at 0x10000'
    # u-boot item header: u32 at 0x10cf0 = code length (from 0x10800, up to the appended dtb)
    code_len = struct.unpack_from('<I', img, 0x10CF0)[0]
    code = bytes(img[PSTART:0x10800 + code_len])
    va = lambda off: BASE + off
    print('u-boot code: %d bytes (boot0 load region)' % len(code))

    m = RE_MEMALIGN.search(code)
    assert m, 'memalign prologue not found'
    memalign = va(m.start())
    print('memalign        @ %#x' % memalign)

    # ---- site 1: nvme_probe, 22 bytes in place
    m = RE_PROBE.search(code)
    assert m and len(m.group(0)) == 22, 'nvme_probe pool-alloc site not found'
    addr = va(m.start())
    hw = int.from_bytes(m.group(1), 'little')                # original NULL-check: 16-bit B<eq> T1
    assert hw & 0xFF00 == 0xD000, 'unexpected beq encoding'
    off8 = hw & 0xFF
    if off8 & 0x80: off8 -= 0x100
    err = addr + 0x0E + 4 + off8 * 2
    off = err - (addr + 0x12 + 4)
    assert -256 <= off < 256 and off % 2 == 0
    new = (bytes.fromhex('4ff48050')                          # mov.w r0,#0x1000  (alignment)
           + bytes.fromhex('c108')                            # lsrs r1,r0,#3     (bytes = 512)
           + bl_encode(addr + 6, memalign)                    # bl memalign
           + bytes.fromhex('4023')                            # movs r3,#0x40
           + bytes.fromhex('c4e92503')                        # strd r0,r3,[r4,#0x94] (pool + entry_num)
           + bytes.fromhex('0028')                            # cmp r0,#0
           + bytes([(off >> 1) & 0xFF, 0xD0])                 # beq err   (B<beq> T1, little-endian)
           + bytes.fromhex('00bf'))                           # nop
    assert len(new) == 22
    img[PSTART + m.start():PSTART + m.start() + 22] = new
    print('nvme_probe      @ %#x  malloc(512) -> memalign(4096,512)' % addr)

    # ---- site 2: nvme_setup_prps realloc path; rewrite 18 bytes starting at match+8
    m = RE_REALLOC.search(code)
    assert m and len(m.group(0)) == 26, 'nvme_setup_prps realloc site not found'
    s0 = m.start(); p = va(s0 + 8)                            # VA of 'lsls r0,r6,#3'
    assert m.group(0)[0x12:0x14] == bytes.fromhex('60b9')
    # original cbnz (imm5=0xC -> +0x18) sits at p+0xA and targets p+0x26 ('str.w r6,[r4,#0x98]');
    # from its new position p+0xE the same target needs imm5 = 0xA
    imm5 = (0x26 - (0x0E + 4)) // 2
    assert 0 <= imm5 <= 0x1F
    new = (bytes.fromhex('f100')                              # lsls r1,r6,#3     (bytes = nprps*8)
           + bytes.fromhex('4ff48050')                        # mov.w r0,#0x1000  (alignment)
           + bl_encode(p + 6, memalign)                       # bl memalign
           + bytes.fromhex('c4f89400')                        # str.w r0,[r4,#0x94]
           + (0xB900 | (imm5 << 3)).to_bytes(2, 'little')     # cbnz r0, <entry_num = nprps>
           + bytes.fromhex('00bf'))                       # nop (error printf dropped; -ENOMEM return kept)
    assert len(new) == 18
    img[PSTART + s0 + 8:PSTART + s0 + 8 + 18] = new
    print('nvme_setup_prps @ %#x  malloc(nprps<<3) -> memalign(4096,nprps<<3)' % p)

    open(dst, 'wb').write(bytes(img))
    changed = sum(a != b for a, b in zip(open(src, 'rb').read(), bytes(img)))
    print('%d bytes differ; sha256 %s' % (changed, hashlib.sha256(bytes(img)).hexdigest()))
    print('Flash with readback verification (flash-spi.sh), then cold-boot without the SD card.')
    print('Expect: no "status = 13", no "CACHE: Misaligned" for the 512-byte pool, and')
    print('kernel cmdline spiboot.prp=0 (pool already page-aligned at probe time).')

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
