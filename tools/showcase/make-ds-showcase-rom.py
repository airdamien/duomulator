#!/usr/bin/env python3
"""Writes ds-showcase.nds: a tiny Nintendo DS homebrew ROM for screenshots of Duomulator.

Public domain (written for this project; the artwork is drawn procedurally below). The ARM9
shows a sunset scene on the top screen (engine A, VRAM framebuffer mode) and a grid of
colored tiles on the touch screen (engine B, a 16-bit bitmap background), then spins.
Hand-encoded ARM, no DS toolchain needed. Needs Pillow. Run: python3 make-ds-showcase-rom.py
"""
import math
import struct
from pathlib import Path

from PIL import Image, ImageDraw

ARM9_ADDR = 0x0200_0000
ARM7_ADDR = 0x0238_0000
ARM7_OFFSET = 0x200
ARM9_OFFSET = 0x1000
ROM_SIZE = 0x4_0000
W, H = 256, 192


def top_image():
    img = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(img)
    horizon = 118
    for y in range(horizon):   # sky: deep violet to orange
        t = y / horizon
        d.line([(0, y), (W, y)], fill=(int(40 + 215 * t), int(20 + 120 * t ** 1.6), int(90 - 40 * t)))
    d.ellipse([160, 58, 214, 112], fill=(255, 214, 120))
    for i, (base, amp, color) in enumerate([(100, 18, (70, 40, 90)), (110, 12, (45, 28, 70))]):
        pts = [(x, base - amp * (0.5 + 0.5 * math.sin(x / (23 + 9 * i) + i * 2))) for x in range(0, W + 8, 8)]
        d.polygon(pts + [(W, horizon), (0, horizon)], fill=color)
    for y in range(horizon, H):   # water with the sun's reflection
        t = (y - horizon) / (H - horizon)
        d.line([(0, y), (W, y)], fill=(int(60 - 30 * t), int(40 - 20 * t), int(90 - 30 * t)))
        if y % 4 < 2:
            half = 26 * (1 - t) + 4
            d.line([(187 - half, y), (187 + half, y)], fill=(255, 190, 110))
    return img


def bottom_image():
    img = Image.new("RGB", (W, H), (24, 24, 32))
    d = ImageDraw.Draw(img)
    colors = [(229, 72, 77), (245, 166, 35), (80, 200, 120), (64, 140, 255), (170, 100, 240), (40, 200, 210)]
    for i, color in enumerate(colors):
        col, row = i % 3, i // 3
        x, y = 20 + col * 76, 28 + row * 76
        d.rounded_rectangle([x, y, x + 64, y + 64], radius=14, fill=color)
        d.ellipse([x + 22, y + 22, x + 42, y + 42], fill=(255, 255, 255))
    return img


def rgb555(img, opaque):
    out = bytearray()
    for r, g, b in img.getdata():
        out += struct.pack("<H", (r >> 3) | (g >> 3) << 5 | (b >> 3) << 10 | (0x8000 if opaque else 0))
    return bytes(out)


# Encoders
def ldr_lit(rd, at, lit): return 0xE59F_0000 | rd << 12 | (lit - (at + 8))
def str_(rd, rn): return 0xE580_0000 | rn << 16 | rd << 12
def strb(rd, rn): return 0xE5C0_0000 | rn << 16 | rd << 12
def strh(rd, rn): return 0xE1C0_00B0 | rn << 16 | rd << 12
def ldrh_post2(rd, rn): return 0xE0D0_00B2 | rn << 16 | rd << 12
def strh_post2(rd, rn): return 0xE0C0_00B2 | rn << 16 | rd << 12
def subs1(rd, rn): return 0xE250_0001 | rn << 16 | rd << 12
def branch(at, target, cond=0xE): return cond << 28 | 0x0A00_0000 | (((target - (at + 8)) >> 2) & 0xFF_FFFF)


def arm9_program():
    top, bottom = rgb555(top_image(), False), rgb555(bottom_image(), True)
    # (register, literal name) loads and stores, in order; copy loops appended below.
    steps = [
        ("ldr", 0, "powcnt"), ("ldr", 1, "powval"), ("str", 1, 0),
        ("ldr", 0, "dispcnt_a"), ("ldr", 1, "dispval_a"), ("str", 1, 0),
        ("ldr", 0, "vramcnt_a"), ("ldr", 1, "vramval_a"), ("strb", 1, 0),
        ("ldr", 0, "vramcnt_c"), ("ldr", 1, "vramval_c"), ("strb", 1, 0),
        ("ldr", 0, "dispcnt_b"), ("ldr", 1, "dispval_b"), ("str", 1, 0),
        ("ldr", 0, "bg3cnt_b"), ("ldr", 1, "bg3val"), ("strh", 1, 0),
        ("ldr", 0, "bg3pa_b"), ("ldr", 1, "one"), ("strh", 1, 0),
        ("ldr", 0, "bg3pd_b"), ("strh", 1, 0),
        ("copy", "vram_a", "img_top"), ("copy", "vram_c", "img_bottom"),
        ("spin",),
    ]
    n_words = sum({"copy": 7, "spin": 1}.get(s[0], 1) for s in steps)
    literals = {
        "powcnt": 0x0400_0304, "powval": 0x0000_8203,       # LCDs, engines A and B, A on top
        "dispcnt_a": 0x0400_0000, "dispval_a": 0x0002_0000,  # VRAM framebuffer display
        "vramcnt_a": 0x0400_0240, "vramval_a": 0x80,        # bank A: LCDC
        "vramcnt_c": 0x0400_0242, "vramval_c": 0x84,        # bank C: sub-engine BG
        "dispcnt_b": 0x0400_1000, "dispval_b": 0x0001_0805,  # mode 5, BG3 on, normal display
        "bg3cnt_b": 0x0400_100E, "bg3val": 0x4084,          # 256x256 direct-color bitmap
        "bg3pa_b": 0x0400_1030, "bg3pd_b": 0x0400_1036, "one": 0x100,
        "vram_a": 0x0680_0000, "vram_c": 0x0620_0000, "pixels": W * H,
        "img_top": 0, "img_bottom": 0,
    }
    lit_base = n_words * 4
    lit_at = {k: lit_base + i * 4 for i, k in enumerate(literals)}
    img_at = lit_base + len(literals) * 4
    literals["img_top"] = ARM9_ADDR + img_at
    literals["img_bottom"] = ARM9_ADDR + img_at + len(top)

    code = []
    for s in steps:
        at = len(code) * 4
        if s[0] == "ldr":
            code.append(ldr_lit(s[1], at, lit_at[s[2]]))
        elif s[0] == "str":
            code.append(str_(s[1], s[2]))
        elif s[0] == "strb":
            code.append(strb(s[1], s[2]))
        elif s[0] == "strh":
            code.append(strh(s[1], s[2]))
        elif s[0] == "copy":
            code.append(ldr_lit(0, at, lit_at[s[1]]))
            code.append(ldr_lit(5, at + 4, lit_at[s[2]]))
            code.append(ldr_lit(3, at + 8, lit_at["pixels"]))
            loop = at + 12
            code += [ldrh_post2(4, 5), strh_post2(4, 0), subs1(3, 3), branch(loop + 12, loop, cond=0x1)]
        elif s[0] == "spin":
            code.append(branch(at, at))
    assert len(code) == n_words
    blob = b"".join(struct.pack("<I", w) for w in code + list(literals.values()))
    return blob + top + bottom


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
    assert ARM9_OFFSET + len(arm9) <= ROM_SIZE
    rom = bytearray(ROM_SIZE)
    struct.pack_into("<12s4s2s", rom, 0, b"DUOSHOWCASE", b"DUOS", b"00")
    rom[0x14] = 0x01                                   # capacity: 256 KB
    struct.pack_into("<4I", rom, 0x20, ARM9_OFFSET, ARM9_ADDR, ARM9_ADDR, len(arm9))
    struct.pack_into("<4I", rom, 0x30, ARM7_OFFSET, ARM7_ADDR, ARM7_ADDR, len(arm7))
    struct.pack_into("<II", rom, 0x80, ROM_SIZE, 0x4000)
    struct.pack_into("<H", rom, 0x15C, 0xCF56)
    rom[ARM9_OFFSET:ARM9_OFFSET + len(arm9)] = arm9
    rom[ARM7_OFFSET:ARM7_OFFSET + len(arm7)] = arm7
    struct.pack_into("<H", rom, 0x15E, crc16(rom[:0x15E]))
    out = Path(__file__).with_name("ds-showcase.nds")
    out.write_bytes(rom)
    print(f"wrote {out} ({len(rom)} bytes)")


if __name__ == "__main__":
    build()
