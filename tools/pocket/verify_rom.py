#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Toaplan V2 for the Analogue Pocket — check the ROM images against MAME.
"""Check <set>.rom byte for byte against the regions MAME itself loads.

    python3 -I tools/pocket/verify_rom.py all --zipdir ~/Downloads --romdir build/pocket

For each set: runs MAME with tools/mame_toaplan2_regions.lua (dumps into
build/mame/regions/<set>/, skipped with --no-mame if they are already there),
then checks:

  * every slot of the image, put back into MAME's logical order
    (build_rom.from_image), equals MAME's region exactly;
  * every byte outside the header and the slots is zero, and the image is
    its board's size;
  * the header: magic, the board's fields, the slot table, the set name, and
    the DIP defaults against MAME's ports at power-on; the V25 table against
    MAME's toaplan_v25_tables.h (identity for TP-030), and the nitro table
    against upstream's dogyuun_nitro_decryption.hex (rtl/sound/), a second
    source;
  * for the TP-022 sets, the program, graphics and OKI slots against the
    byte stream upstream's Dogyuun MRA builds from the same files (program
    as the file, each GP9001's two ROMs interleaved a 16-bit word at a time,
    OKI as the file), computed here straight from the zips: the check that
    the image's byte order is the order the board was built to load.

Exit status 0 only if every set matches.
"""

import argparse
import os
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_rom  # noqa: E402  (our own module, beside this file)

REPO = build_rom.REPO
LUA = os.path.join(REPO, "tools", "mame_toaplan2_regions.lua")
NITRO_HEX = os.path.join(REPO, "rtl", "sound", "dogyuun_nitro_decryption.hex")

# Upstream's Dogyuun.mra: <part> for the program, an interleave output="32"
# of (tp022_3, tp022_4) and of (tp022_5, tp022_6) with map 0021 / 2100, then
# the OKI ROM. Names and CRCs as in that MRA.
MRA_TP022 = {
    "gp9001_0": [("tp022_3.w92", 0x191b595f, 0x100000), ("tp022_4.w93", 0xd58d29ca, 0x100000)],
    "gp9001_1": [("tp022_5.w16", 0xd4c1db45, 0x200000), ("tp022_6.w17", 0xd48dc74f, 0x200000)],
    "oki": [("tp022_2.w30", 0x043271b3, 0x040000)],
}


def run_mame(setname, zipdir, dumpdir, mame):
    os.makedirs(dumpdir, exist_ok=True)
    work = os.path.join(REPO, "build", "mame", "work")
    env = dict(os.environ, DUMP_DIR=dumpdir)
    cmd = [mame, "-rompath", zipdir, setname,
           "-autoboot_script", LUA, "-skip_gameinfo", "-autoboot_delay", "0",
           "-video", "none", "-sound", "none", "-nothrottle", "-seconds_to_run", "60",
           "-cfg_directory", os.path.join(work, "cfg"),
           "-nvram_directory", os.path.join(work, "nvram"),
           "-snapshot_directory", os.path.join(work, "snap")]
    meta = os.path.join(dumpdir, "regions.txt")
    if os.path.exists(meta):
        os.remove(meta)
    r = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if not os.path.exists(meta):
        sys.stdout.write(r.stdout + r.stderr)
        raise SystemExit(f"{setname}: MAME did not dump its regions")


def read_meta(dumpdir):
    regions, ports = {}, {}
    for line in open(os.path.join(dumpdir, "regions.txt")):
        f = line.split()
        if f[0] == "region":
            regions[f[1]] = int(f[2].split("=")[1])
        elif f[0] == "port":
            ports[f[1]] = int(f[2])
    return regions, ports


def first_diff(a, b):
    for i in range(0, min(len(a), len(b)), 0x10000):
        if a[i:i + 0x10000] != b[i:i + 0x10000]:
            for j in range(i, i + 0x10000):
                if a[j] != b[j]:
                    return j
    return None if len(a) == len(b) else min(len(a), len(b))


def count_diff(a, b):
    return sum(x != y for x, y in zip(a, b)) + abs(len(a) - len(b))


def mra_stream(setname, slot, index):
    """The bytes upstream's MRA writes for a TP-022 region, from the files."""
    prefer = [setname, build_rom.SETS[setname]["parent"] or setname]
    parts = [index.read(size, crc, prefer, name)[0] for name, crc, size in MRA_TP022[slot]]
    if len(parts) == 1:
        return parts[0]
    lo, hi = parts
    out = bytearray(2 * len(lo))
    for k in (0, 1):
        out[k::4] = lo[k::2]          # map 0021: output bytes 0-1 <- part bytes 1-2
        out[2 + k::4] = hi[k::2]      # map 2100: output bytes 2-3 <- part bytes 1-2
    return bytes(out)


def mra_program(setname, index):
    spec = build_rom.SETS[setname]
    _, _, ops = spec["regions"]["maincpu"]
    (_, name, crc, _, size), = ops
    prefer = [setname, spec["parent"] or setname]
    return index.read(size, crc, prefer, name)[0]


def verify(setname, romdir, dumpdir, index):
    spec = build_rom.SETS[setname]
    board = build_rom.BOARDS[spec["board"]]
    img = open(os.path.join(romdir, f"{setname}.rom"), "rb").read()
    lines, ok = [], True

    def fail(msg):
        nonlocal ok
        ok = False
        lines.append("  " + msg)

    want_len = build_rom.image_size(spec["board"])
    if len(img) != want_len:
        return False, [f"  image is {len(img):#x} bytes, expected {want_len:#x}"]
    mame_regions, mame_ports = read_meta(dumpdir)

    # ---- header
    try:
        h = build_rom.parse_header(img[:build_rom.HEADER_SIZE])
    except ValueError as e:
        return False, [f"  header: {e}"]
    want = {"version": build_rom.FORMAT_VERSION, "board": board["id"], "gp": board["gp"],
            "table": build_rom.TABLE_ID[board["table"]], "rot": board["rot"],
            "players": board["players"], "pin7": board["pin7"], "workram": board["workram"],
            "cpu": board["cpu"], "v25": board["v25"], "oki": board["oki"],
            "length": want_len, "set": setname,
            "slots": {s: (o, n) for s, o, n in build_rom.LAYOUT[spec["board"]]}}
    bad = [k for k, v in want.items() if h[k] != v]
    if bad:
        fail(f"header fields wrong: {', '.join(bad)}")
    table = build_rom.v25_tables()[board["table"]]
    if h["v25_table"] != bytes(table):
        fail(f"header V25 table is not MAME's {board['table']} table")
    if board["table"] == "nitro":
        upstream = bytes(int(x, 16) for x in open(NITRO_HEX).read().split())
        if upstream != h["v25_table"]:
            fail("header nitro table differs from upstream's dogyuun_nitro_decryption.hex")
    if mame_ports:
        mame_dips = tuple(mame_ports[n] & 0xff for n in ("DSWA", "DSWB", "JMPR"))
        if h["dips"] != mame_dips:
            fail(f"DIP defaults {h['dips']} but MAME reads {mame_dips}")
    elif h["dips"] is not None:
        fail("DIP defaults in the header, but MAME's set has no DIP ports")
    hdr_tail = img[0x060:0x100] + img[0x200:build_rom.HEADER_SIZE]
    if any(hdr_tail):
        fail("header has stray bytes outside its fields")
    lines.append(f"  header   board {spec['board']}, {board['gp']} GP9001, V25 table "
                 f"{board['table']}, DIPs "
                 + ("none" if h["dips"] is None else " ".join(f"{d:02x}" for d in h["dips"]))
                 + ("" if not bad else "  FAIL"))

    # ---- regions
    covered = bytearray(len(img))
    covered[:build_rom.HEADER_SIZE] = b"\1" * build_rom.HEADER_SIZE
    for slot, off, size in build_rom.LAYOUT[spec["board"]]:
        covered[off:off + size] = b"\1" * size
        mname = spec["regions"][slot][0]
        path = os.path.join(dumpdir, f"{mname}.bin")
        if not os.path.exists(path):
            fail(f"{slot:<9} MAME has no region {mname}")
            continue
        mame = open(path, "rb").read()
        if mame_regions.get(mname) != len(mame) or len(mame) != size:
            fail(f"{slot:<9} MAME's {mname} is {len(mame):#x}, the slot {size:#x}")
            continue
        mine = build_rom.from_image(slot, img[off:off + size])
        d = first_diff(mine, mame)
        if d is None:
            lines.append(f"  {slot:<9} @{off:#09x}  {size:#09x} bytes  MATCH MAME's {mname}")
        else:
            fail(f"{slot:<9} @{off:#09x}  MISMATCH with MAME's {mname}: "
                 f"{count_diff(mine, mame)} bytes differ, first at +{d:#x}")
    missing = [m for m in mame_regions if m not in ("plds",)
               and m not in (r[0] for r in spec["regions"].values())]
    if missing:
        fail(f"MAME regions not in the image: {', '.join(missing)}")
    stray = sum(1 for i in range(len(img)) if not covered[i] and img[i])
    if stray:
        fail(f"{stray} bytes outside the header and slots are not zero")

    # ---- upstream's MRA order (TP-022)
    if spec["board"] == "TP-022":
        place = {s: (o, n) for s, o, n in build_rom.LAYOUT["TP-022"]}
        checks = [("maincpu", mra_program(setname, index))] + \
                 [(s, mra_stream(setname, s, index)) for s in MRA_TP022]
        for slot, stream in checks:
            o, n = place[slot]
            if img[o:o + n] == stream:
                lines.append(f"  {slot:<9} = upstream's MRA byte stream")
            else:
                fail(f"{slot:<9} differs from upstream's MRA byte stream")
    return ok, lines


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("set", help="set name, comma list, or 'all'")
    ap.add_argument("--zipdir", default=os.path.expanduser("~/Downloads"))
    ap.add_argument("--romdir", default=os.path.join(REPO, "build", "pocket"))
    ap.add_argument("--dumpdir", default=os.path.join(REPO, "build", "mame", "regions"))
    ap.add_argument("--mame", default="mame")
    ap.add_argument("--no-mame", action="store_true", help="reuse existing region dumps")
    a = ap.parse_args()

    zipdir = os.path.expanduser(a.zipdir)
    index = build_rom.RomIndex(zipdir)
    sets = build_rom.expand_sets(a.set)
    failed = []
    for i, s in enumerate(sets, 1):
        d = os.path.join(a.dumpdir, s)
        if not a.no_mame:
            run_mame(s, zipdir, d, a.mame)
        ok, lines = verify(s, a.romdir, d, index)
        print(f"{s}: {'OK' if ok else 'FAIL'} ({i} of {len(sets)})")
        print("\n".join(lines))
        if not ok:
            failed.append(s)
    print(f"{len(sets) - len(failed)} of {len(sets)} sets match MAME"
          + (f"; failed: {', '.join(failed)}" if failed else ""))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
