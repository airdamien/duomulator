#!/usr/bin/env python3
"""Writes snes-showcase.sfc: a tiny Super Nintendo ROM for screenshots of Duomulator.

Public domain (written for this project; the artwork is drawn procedurally below). The 65816
switches to mode 1, DMAs a 16-colour palette, one 4bpp tile per screen cell and a BG1 tile
map into the PPU, turns the screen on and spins: a full-screen 256x224 picture of rolling
hills. Hand-encoded 65816 in a 32 KB LoROM, no toolchain needed. Needs Pillow.
Run: python3 make-snes-showcase-rom.py
"""
import math
import random
import struct
from pathlib import Path

from PIL import Image, ImageDraw

W, H = 256, 224
COLS, ROWS = W // 8, H // 8
ROM_SIZE = 0x8000            # one LoROM bank, mapped at $00:8000
CODE, TILES = 0x8000, 0x8100


def picture():
    img = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(img)
    for y in range(H):   # sky: deep blue to pale
        t = y / H
        d.line([(0, y), (W, y)], fill=(int(60 + 150 * t), int(120 + 110 * t), 250))
    for cx, cy in [(60, 40), (170, 60), (220, 30)]:   # clouds
        for dx, dy, r in [(-16, 4, 12), (0, 0, 16), (16, 4, 12)]:
            d.ellipse([cx + dx - r, cy + dy - r, cx + dx + r, cy + dy + r], fill=(255, 255, 255))
    layers = [(150, 26, 0.020, (90, 170, 90)), (172, 20, 0.031, (60, 140, 60)), (196, 14, 0.045, (40, 110, 45))]
    for base, amp, freq, color in layers:
        pts = [(x, base - amp * math.sin(x * freq + base)) for x in range(0, W + 4, 4)]
        d.polygon(pts + [(W, H), (0, H)], fill=color)
    random.seed(7)
    for _ in range(14):   # trees
        x, y = random.randrange(8, W - 8), random.randrange(176, 214)
        d.rectangle([x - 1, y, x + 1, y + 6], fill=(90, 60, 30))
        d.polygon([(x - 7, y + 2), (x + 7, y + 2), (x, y - 14)], fill=(20, 80, 35))
    return img


def snes_color(rgb):
    r, g, b = (c >> 3 for c in rgb)
    return b << 10 | g << 5 | r


def tiles_map_palette(img):
    q = img.quantize(colors=16, dither=Image.Dither.NONE)
    pal = q.getpalette()[:48]
    palette = b"".join(struct.pack("<H", snes_color(pal[i * 3:i * 3 + 3])) for i in range(16))
    px = q.load()
    tiles = bytearray()
    for row in range(ROWS):
        for col in range(COLS):
            planes = [[0] * 8 for _ in range(4)]
            for y in range(8):
                for x in range(8):
                    v = px[col * 8 + x, row * 8 + y]
                    for p in range(4):
                        if v >> p & 1:
                            planes[p][y] |= 0x80 >> x
            for y in range(8):
                tiles += bytes([planes[0][y], planes[1][y]])
            for y in range(8):
                tiles += bytes([planes[2][y], planes[3][y]])
    tilemap = b"".join(struct.pack("<H", i) for i in range(ROWS * COLS))
    return bytes(tiles), tilemap.ljust(32 * 32 * 2, b"\0"), palette


def sta(value, reg):   # LDA #value; STA reg
    return bytes([0xA9, value & 0xFF, 0x8D, reg & 0xFF, reg >> 8])


def dma(mode, dest, src, size):
    return (sta(mode, 0x4300) + sta(dest, 0x4301) + sta(src, 0x4302) + sta(src >> 8, 0x4303)
            + sta(0, 0x4304) + sta(size, 0x4305) + sta(size >> 8, 0x4306) + sta(1, 0x420B))


def build():
    tiles, tilemap, palette = tiles_map_palette(picture())
    map_at = TILES + len(tiles)
    pal_at = map_at + len(tilemap)
    assert pal_at + len(palette) <= 0xFFB0, hex(pal_at)
    code = bytes([0x78, 0x18, 0xFB])      # SEI; CLC; XCE (native mode, 8-bit registers)
    code += sta(0x80, 0x2100)             # force blank
    code += sta(0x01, 0x2105)             # mode 1
    code += sta(0x70, 0x2107)             # BG1 map at VRAM $7000, 32x32
    code += sta(0x00, 0x210B)             # BG1 tiles at VRAM $0000
    code += sta(0xFF, 0x210E) + sta(0xFF, 0x210E)   # BG1 V-scroll -1: line 0 is the top row
    code += sta(0x01, 0x212C)             # BG1 on the main screen
    code += sta(0x80, 0x2115)             # VRAM: increment after the high byte
    code += sta(0x00, 0x2116) + sta(0x00, 0x2117)
    code += dma(0x01, 0x18, TILES, len(tiles))
    code += sta(0x00, 0x2116) + sta(0x70, 0x2117)
    code += dma(0x01, 0x18, map_at, len(tilemap))
    code += sta(0x00, 0x2121)             # CGRAM address 0
    code += dma(0x00, 0x22, pal_at, len(palette))
    code += sta(0x0F, 0x2100)             # screen on, full brightness
    code += bytes([0x80, 0xFE])           # BRA * (spin)
    assert CODE + len(code) <= TILES

    rom = bytearray(ROM_SIZE)
    def at(addr): return addr - 0x8000
    rom[0:len(code)] = code
    rom[at(TILES):at(TILES) + len(tiles)] = tiles
    rom[at(map_at):at(map_at) + len(tilemap)] = tilemap
    rom[at(pal_at):at(pal_at) + len(palette)] = palette
    rom[0x7FC0:0x7FD5] = b"DUOMULATOR SHOWCASE".ljust(21)
    rom[0x7FD5] = 0x20                    # LoROM, slow
    rom[0x7FD6] = 0x00                    # ROM only
    rom[0x7FD7] = 0x05                    # 32 KB
    rom[0x7FD9] = 0x01                    # North America
    struct.pack_into("<H", rom, 0x7FFC, CODE)   # emulation-mode reset vector
    struct.pack_into("<HH", rom, 0x7FDC, 0xFFFF, 0)
    checksum = sum(rom) & 0xFFFF
    struct.pack_into("<HH", rom, 0x7FDC, checksum ^ 0xFFFF, checksum)
    out = Path(__file__).with_name("snes-showcase.sfc")
    out.write_bytes(rom)
    print(f"wrote {out} ({len(rom)} bytes)")


if __name__ == "__main__":
    build()
