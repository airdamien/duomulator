#!/usr/bin/env python3
"""Writes genesis-showcase.md: a tiny Sega Genesis / Mega Drive ROM for screenshots of Duomulator.

Public domain (written for this project; the artwork is drawn procedurally below). The 68000
sets up the VDP in H40 mode, loads a 16-colour palette, one 8x8 tile per screen cell and a
plane A name table, then spins: a full-screen 320x224 picture of a neon horizon.
Hand-encoded 68000, no toolchain needed. Needs Pillow. Run: python3 make-genesis-showcase-rom.py
"""
import struct
from pathlib import Path

from PIL import Image, ImageDraw

VDP_DATA, VDP_CTRL = 0x00C0_0000, 0x00C0_0004
ENTRY = 0x200
ROM_SIZE = 0x2_0000
W, H = 320, 224
COLS, ROWS = W // 8, H // 8


# A hand-picked 16-colour palette (index 0 is the backdrop).
PALETTE = [
    (20, 10, 60), (45, 15, 90), (80, 20, 110), (120, 30, 130), (165, 40, 140), (210, 50, 140),  # sky bands
    (255, 230, 90), (255, 190, 70), (255, 140, 60), (250, 95, 70),                         # sun, top to bottom
    (25, 5, 45), (230, 60, 220),                                                           # floor, grid
] + [(0, 0, 0)] * 4


def picture():
    img = Image.new("P", (W, H))
    img.putpalette([c for rgb in PALETTE for c in rgb])
    d = ImageDraw.Draw(img)
    horizon = 132
    for y in range(horizon):   # sky in six bands, darkest at the top
        d.line([(0, y), (W, y)], fill=min(5, y * 6 // horizon))
    cx, cy, r = 160, 112, 58   # striped sun
    for y in range(cy - r, horizon):
        h = horizon - y
        if h % 10 >= max(0, 5 - h // 12):   # gaps widen toward the horizon
            half = (r * r - (y - cy) ** 2) ** 0.5
            band = 6 + min(3, (y - (cy - r)) * 4 // (horizon - (cy - r)))
            d.line([(cx - half, y), (cx + half, y)], fill=band)
    d.rectangle([0, horizon, W, H], fill=10)   # grid floor
    for i in range(-12, 13):
        d.line([(160 + i * 8, horizon), (160 + i * 60, H)], fill=11)
    y, step = horizon, 3
    while y < H:
        d.line([(0, y), (W, y)], fill=11)
        y += step
        step += 3
    return img


def genesis_color(rgb):
    r, g, b = (min(7, round(c / 255 * 7)) for c in rgb)
    return b << 9 | g << 5 | r << 1


def tiles_and_palette(img):
    palette = [genesis_color(rgb) for rgb in PALETTE]
    px = img.load()
    tiles = bytearray()
    for row in range(ROWS):
        for col in range(COLS):
            for y in range(8):
                for x in range(0, 8, 2):
                    a = px[col * 8 + x, row * 8 + y]
                    b = px[col * 8 + x + 1, row * 8 + y]
                    tiles.append(a << 4 | b)
    names = bytearray()
    for row in range(ROWS):
        for col in range(64):   # plane is 64 cells wide
            names += struct.pack(">H", row * COLS + col if col < COLS else 0)
    return palette, bytes(tiles), bytes(names)


# 68000 encoders
def move_w_imm_abs(value, addr): return struct.pack(">HHI", 0x33FC, value, addr)
def move_l_imm_abs(value, addr): return struct.pack(">HII", 0x23FC, value, addr)
def lea_a0(addr): return struct.pack(">HI", 0x41F9, addr)
def move_w_d0(value): return struct.pack(">HH", 0x303C, value)


def copy_loop(at, src, count, longs):
    """LEA src,A0; MOVE.W #count-1,D0; loop: MOVE.x (A0)+,VDP_DATA; DBRA D0,loop."""
    head = lea_a0(src) + move_w_d0(count - 1)
    loop = at + len(head)
    body = struct.pack(">HI", 0x23D8 if longs else 0x33D8, VDP_DATA)
    dbra_at = loop + len(body)
    return head + body + struct.pack(">Hh", 0x51C8, loop - (dbra_at + 2))


def build():
    palette, tiles, names = tiles_and_palette(picture())
    data_at = 0x400
    pal_at, tiles_at = data_at, data_at + 32
    names_at = tiles_at + len(tiles)
    assert names_at + len(names) <= ROM_SIZE

    code = b"".join(move_w_imm_abs(v, VDP_CTRL) for v in [
        0x8004,   # reg 0: normal colour mode
        0x8104,   # reg 1: display off while loading, mode 5
        0x8230,   # reg 2: plane A name table at 0xC000
        0x8407,   # reg 4: plane B at 0xE000
        0x8D3F,   # reg 13: H-scroll table at 0xFC00
        0x8700,   # reg 7: backdrop = palette 0, colour 0
        0x8B00,   # reg 11: full-screen scrolling
        0x8C81,   # reg 12: H40 (320 pixels)
        0x8F02,   # reg 15: auto-increment 2
        0x9001,   # reg 16: 64x32-cell planes
    ])
    code += move_l_imm_abs(0xC000_0000, VDP_CTRL)                    # CRAM write at 0
    code += copy_loop(ENTRY + len(code), pal_at, 16, longs=False)
    code += move_l_imm_abs(0x4000_0000, VDP_CTRL)                    # VRAM write at 0
    code += copy_loop(ENTRY + len(code), tiles_at, len(tiles) // 4, longs=True)
    code += move_l_imm_abs(0x4000_0003, VDP_CTRL)                    # VRAM write at 0xC000
    code += copy_loop(ENTRY + len(code), names_at, len(names) // 4, longs=True)
    code += move_l_imm_abs(0x7C00_0003, VDP_CTRL)                    # VRAM write at 0xFC00
    code += move_l_imm_abs(0, VDP_DATA)                              # H-scroll 0
    code += move_w_imm_abs(0x8144, VDP_CTRL)                         # display on
    code += move_l_imm_abs(0x4000_0010, VDP_CTRL)                    # VSRAM write at 0
    code += move_l_imm_abs(0, VDP_DATA)                              # V-scroll 0
    code += struct.pack(">H", 0x60FE)                                # BRA.S * (spin)
    assert ENTRY + len(code) <= data_at

    rom = bytearray(ROM_SIZE)
    struct.pack_into(">II", rom, 0, 0x00FF_FE00, ENTRY)
    rom[0x100:0x110] = b"SEGA GENESIS    "
    rom[0x110:0x120] = b"(C)DUOS 2026.OCT"
    title = b"DUOMULATOR SHOWCASE".ljust(48)
    rom[0x120:0x150] = title
    rom[0x150:0x180] = title
    rom[0x180:0x18E] = b"GM 00000000-00"
    rom[0x190:0x1A0] = b"J".ljust(16)
    struct.pack_into(">II", rom, 0x1A0, 0, ROM_SIZE - 1)
    struct.pack_into(">II", rom, 0x1A8, 0x00FF_0000, 0x00FF_FFFF)
    rom[0x1F0:0x1F3] = b"JUE"
    rom[ENTRY:ENTRY + len(code)] = code
    rom[pal_at:pal_at + 32] = b"".join(struct.pack(">H", c) for c in palette)
    rom[tiles_at:tiles_at + len(tiles)] = tiles
    rom[names_at:names_at + len(names)] = names
    checksum = sum(struct.unpack(f">{(ROM_SIZE - 0x200) // 2}H", rom[0x200:])) & 0xFFFF
    struct.pack_into(">H", rom, 0x18E, checksum)
    out = Path(__file__).with_name("genesis-showcase.md")
    out.write_bytes(rom)
    print(f"wrote {out} ({len(rom)} bytes)")


if __name__ == "__main__":
    build()
