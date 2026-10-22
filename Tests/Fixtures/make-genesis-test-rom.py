#!/usr/bin/env python3
"""Writes genesistest.md: a tiny Sega Genesis / Mega Drive ROM for the emulator tests.

Public domain (written for this project). The 68000 sets up the VDP (display on, 320-pixel
H40 mode, backdrop = palette 0 color 0), writes pure red into CRAM color 0 and spins, so
the whole 320x224 picture is red. Interrupts stay masked (as at reset), so no vectors are
needed beyond the initial stack pointer and PC.

Instructions are hand-encoded 68000 machine code. Run: python3 make-genesis-test-rom.py
"""
import struct
from pathlib import Path

VDP_DATA, VDP_CTRL = 0x00C0_0000, 0x00C0_0004
ENTRY = 0x200
ROM_SIZE = 0x2_0000


def move_w_imm_abs(value, addr):   # MOVE.W #value, (addr).L
    return struct.pack(">HHI", 0x33FC, value, addr)


def move_l_imm_abs(value, addr):   # MOVE.L #value, (addr).L
    return struct.pack(">HII", 0x23FC, value, addr)


def program():
    return b"".join([
        move_w_imm_abs(0x8004, VDP_CTRL),        # reg 0: normal colour mode
        move_w_imm_abs(0x8144, VDP_CTRL),        # reg 1: display on, mode 5, no IRQs
        move_w_imm_abs(0x8F02, VDP_CTRL),        # reg 15: auto-increment 2
        move_w_imm_abs(0x8C81, VDP_CTRL),        # reg 12: H40 (320 pixels wide)
        move_w_imm_abs(0x8700, VDP_CTRL),        # reg 7: backdrop = palette 0, colour 0
        move_l_imm_abs(0xC000_0000, VDP_CTRL),   # CRAM write, address 0
        move_w_imm_abs(0x000E, VDP_DATA),        # colour 0 = red (----BBB-GGG-RRR-)
        struct.pack(">H", 0x60FE),               # BRA.S * (spin)
    ])


def build():
    rom = bytearray(ROM_SIZE)
    struct.pack_into(">II", rom, 0, 0x00FF_FE00, ENTRY)       # initial SSP, initial PC
    rom[0x100:0x110] = b"SEGA GENESIS    "
    rom[0x110:0x120] = b"(C)DUOT 2026.OCT"
    title = b"DUOMULATOR GENESIS TEST".ljust(48)
    rom[0x120:0x150] = title                                   # domestic name
    rom[0x150:0x180] = title                                   # overseas name
    rom[0x180:0x18E] = b"GM 00000000-00"
    rom[0x190:0x1A0] = b"J".ljust(16)                          # I/O: 3-button pad
    struct.pack_into(">II", rom, 0x1A0, 0, ROM_SIZE - 1)       # ROM start/end
    struct.pack_into(">II", rom, 0x1A8, 0x00FF_0000, 0x00FF_FFFF)  # RAM start/end
    rom[0x1F0:0x1F3] = b"JUE"                                  # regions
    code = program()
    rom[ENTRY:ENTRY + len(code)] = code
    # Checksum: 16-bit sum of the words after the header.
    checksum = sum(struct.unpack(f">{(ROM_SIZE - 0x200) // 2}H", rom[0x200:])) & 0xFFFF
    struct.pack_into(">H", rom, 0x18E, checksum)
    out = Path(__file__).with_name("genesistest.md")
    out.write_bytes(rom)
    print(f"wrote {out} ({len(rom)} bytes)")


if __name__ == "__main__":
    build()
