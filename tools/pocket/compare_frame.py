#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare a harness frame (tb_batsugun's frame_NNNNN.ppm, 320 x 240 as the
board scans it) with MAME's picture of the same frame (mame_toaplan2_dump.lua's
screen.png, rotated by the game's orientation: 240 x 320 for ROT270).

    python3 -I tools/pocket/compare_frame.py build/mame/dump/batsugun/f00600/screen.png \\
        build/sim/batsugun/frame_00600.ppm [--rot 270] [--diff out.ppm]

The harness frame is rotated as MAME rotates (ROT270: the native picture
turned a quarter counter-clockwise), then compared pixel for pixel. Prints
the count of differing pixels, their bounding box and the first few; --diff
writes the harness frame with every differing pixel in magenta. Exit status
0 when pixel-exact.
"""
import argparse
import struct
import sys
import zlib


def read_png(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path}: not a PNG")
    pos, idat, w = 8, b"", None
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or ctype not in (2, 6) or interlace:
                raise SystemExit(f"{path}: only 8-bit RGB/RGBA, not interlaced")
            bpp = 3 if ctype == 2 else 4
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows, prev, p = [], bytearray(stride), 0
    for _ in range(h):
        ft = raw[p]; line = bytearray(raw[p + 1:p + 1 + stride]); p += 1 + stride
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if ft == 1: line[i] = (line[i] + a) & 0xff
            elif ft == 2: line[i] = (line[i] + b) & 0xff
            elif ft == 3: line[i] = (line[i] + ((a + b) >> 1)) & 0xff
            elif ft == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xff
        rows.append([tuple(line[x * bpp:x * bpp + 3]) for x in range(w)])
        prev = line
    return w, h, rows


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    parts, pos = [], 0
    while len(parts) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        q = pos
        while not data[q:q + 1].isspace():
            q += 1
        parts.append(data[pos:q]); pos = q
    pos += 1
    w, h = int(parts[1]), int(parts[2])
    px = data[pos:pos + 3 * w * h]
    return w, h, [[tuple(px[3 * (y * w + x):3 * (y * w + x) + 3]) for x in range(w)] for y in range(h)]


def rotate(w, h, rows, rot):
    if rot == 0:
        return w, h, rows
    if rot == 270:   # a quarter turn counter-clockwise: (x, y) -> (y, w-1-x)
        return h, w, [[rows[x][w - 1 - y] for x in range(h)] for y in range(w)]
    if rot == 90:    # clockwise: (x, y) -> (h-1-y, x)
        return h, w, [[rows[h - 1 - x][y] for x in range(h)] for y in range(w)]
    raise SystemExit("rot 0, 90 or 270")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mame_png")
    ap.add_argument("core_ppm")
    ap.add_argument("--rot", type=int, default=270)
    ap.add_argument("--diff")
    a = ap.parse_args()
    mw, mh, m = read_png(a.mame_png)
    cw, ch, c = rotate(*read_ppm(a.core_ppm), a.rot)
    if (mw, mh) != (cw, ch):
        raise SystemExit(f"sizes differ: MAME {mw}x{mh}, core {cw}x{ch} after rotation")
    bad = [(x, y) for y in range(mh) for x in range(mw) if m[y][x] != c[y][x]]
    if a.diff:
        with open(a.diff, "wb") as f:
            f.write(b"P6\n%d %d\n255\n" % (cw, ch))
            badset = set(bad)
            for y in range(ch):
                for x in range(cw):
                    f.write(bytes((255, 0, 255) if (x, y) in badset else c[y][x]))
    if not bad:
        print(f"pixel-exact: {mw} x {mh}")
        return 0
    xs, ys = [p[0] for p in bad], [p[1] for p in bad]
    print(f"{len(bad)} of {mw * mh} pixels differ, box x {min(xs)}-{max(xs)} y {min(ys)}-{max(ys)}")
    for x, y in bad[:8]:
        print(f"  ({x},{y}) MAME {m[y][x]} core {c[y][x]}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
