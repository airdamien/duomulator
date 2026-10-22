#!/usr/bin/env python3
"""Writes dstest.nds: a tiny Nintendo DS homebrew ROM for the emulator tests.

Public domain (written for this project). The ARM9 turns on the LCD and 2D engine A on the
top screen, switches to VRAM framebuffer display, maps VRAM bank A and fills 256x192 pixels
with a color gradient, then spins. The ARM7 just spins. The touch screen stays blank.

Instructions are hand-encoded ARM (no DS toolchain needed). Run: python3 make-ds-test-rom.py
"""
import struct
from pathlib import Path

ARM9_ADDR = 0x0200_0000
ARM7_ADDR = 0x0238_0000
ARM9_OFFSET = 0x200   # below 0x4000: homebrew layout, no secure area
ARM7_OFFSET = 0x400
ROM_SIZE = 0x2_0000


def ldr_lit(rd, at, lit):
    """LDR rd, [pc, #lit - (at + 8)]"""
    off = lit - (at + 8)
    assert 0 <= off < 0x1000
    return 0xE59F_0000 | rd << 12 | off


def str_(rd, rn):  return 0xE580_0000 | rn << 16 | rd << 12      # STR rd, [rn]
def strb(rd, rn):  return 0xE5C0_0000 | rn << 16 | rd << 12      # STRB rd, [rn]
def mov(rd, imm):  return 0xE3A0_0000 | rd << 12 | imm           # MOV rd, #imm8
def strh_post2(rd, rn): return 0xE0C0_00B2 | rn << 16 | rd << 12  # STRH rd, [rn], #2
def add1(rd, rn):  return 0xE280_0001 | rn << 16 | rd << 12      # ADD rd, rn, #1
def cmp_(rn, rm):  return 0xE150_0000 | rn << 16 | rm            # CMP rn, rm


def branch(at, target, cond=0xE):
    off = (target - (at + 8)) >> 2
    return cond << 28 | 0x0A00_0000 | (off & 0xFF_FFFF)


def arm9_program():
    literals = {
        "powcnt": 0x0400_0304, "powval": 0x0000_8003,  # LCDs on, engine A on, A on top
        "dispcnt": 0x0400_0000, "dispval": 0x0002_0000,  # display mode 2: VRAM framebuffer
        "vramcnt": 0x0400_0240,
        "vram": 0x0680_0000, "count": 256 * 192,
    }
    code_len = 18 * 4
    lit_at = {name: code_len + i * 4 for i, name in enumerate(literals)}
    code = [
        ldr_lit(0, 0x00, lit_at["powcnt"]),
        ldr_lit(1, 0x04, lit_at["powval"]),
        str_(1, 0),
        ldr_lit(0, 0x0C, lit_at["dispcnt"]),
        ldr_lit(1, 0x10, lit_at["dispval"]),
        str_(1, 0),
        ldr_lit(0, 0x18, lit_at["vramcnt"]),
        mov(1, 0x80),                       # bank A enabled, LCDC mode
        strb(1, 0),
        ldr_lit(0, 0x24, lit_at["vram"]),
        mov(2, 0),
        ldr_lit(3, 0x2C, lit_at["count"]),
        strh_post2(2, 0),                   # 0x30 loop: *vram++ = i (15-bit color)
        add1(2, 2),
        cmp_(2, 3),
        branch(0x3C, 0x30, cond=0xB),       # BLT loop
        branch(0x40, 0x40),                 # spin
        branch(0x44, 0x44),
    ]
    assert len(code) * 4 == code_len
    return b"".join(struct.pack("<I", w) for w in code + list(literals.values()))


def crc16(data):
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def build():
    arm9 = arm9_program()
    arm7 = struct.pack("<I", branch(0, 0))
    rom = bytearray(ROM_SIZE)
    struct.pack_into("<12s4s2s", rom, 0, b"DUOTEST", b"DUOT", b"00")
    rom[0x14] = 0x00                                   # capacity: 128 KB
    struct.pack_into("<4I", rom, 0x20, ARM9_OFFSET, ARM9_ADDR, ARM9_ADDR, len(arm9))
    struct.pack_into("<4I", rom, 0x30, ARM7_OFFSET, ARM7_ADDR, ARM7_ADDR, len(arm7))
    struct.pack_into("<II", rom, 0x80, ROM_SIZE, 0x4000)  # used ROM size, header size
    struct.pack_into("<H", rom, 0x15C, 0xCF56)            # logo CRC
    rom[ARM9_OFFSET:ARM9_OFFSET + len(arm9)] = arm9
    rom[ARM7_OFFSET:ARM7_OFFSET + len(arm7)] = arm7
    struct.pack_into("<H", rom, 0x15E, crc16(rom[:0x15E]))
    out = Path(__file__).with_name("dstest.nds")
    out.write_bytes(rom)
    print(f"wrote {out} ({len(rom)} bytes)")


if __name__ == "__main__":
    build()
