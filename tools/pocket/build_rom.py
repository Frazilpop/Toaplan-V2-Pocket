#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Toaplan V2 for the Analogue Pocket — the ROM images.
"""Build the Pocket's ROM image (<set>.rom) for a Toaplan V2 set from MAME zips.

    python3 -I tools/pocket/build_rom.py batsugun ~/Downloads build/pocket
    python3 -I tools/pocket/build_rom.py all      ~/Downloads build/pocket
    python3 -I tools/pocket/build_rom.py dogyuun  ~/Downloads build/roms --regions

THE IMAGE. A 4 KB header, then every region of the set at a fixed offset for
its board (LAYOUT), each gap zero. The header says which board and game it is
(clocks, map, rotation, the DIP defaults, the region table) and carries the
V25's 256-byte opcode table, so one board serves every set and nothing about
a game is built into the bitstream.

The bytes go in as the board's loader takes them: it pairs each even byte
with the next into one 16-bit SDRAM word, the EVEN BYTE IN THE LOW LANE (the
order upstream's MiSTer core loads, which this board keeps). So a 16-bit
region is stored as little-endian words of MAME's big-endian ones:

  maincpu         MAME's logical words, each stored low byte first.
  gp9001_0 / _1   each 32-bit block holds word k of the region's lower half,
                  then word k of its upper half (planes 0-1 and 2-3 of the
                  same pixels, one SDRAM burst; rtl's dogyuun_gfx_repack),
                  each word stored low byte first.
  audiocpu, oki   bytes as MAME's region (the board reads them a byte at a
                  time: even byte in the low lane).
  eeprom          MAME's region as it stands, which is MAME's nvram file
                  byte for byte (the 93C46's words big-endian): what the
                  Pocket's save slot is seeded with and must hold.

"Logical" is MAME's own order: byte 0 of maincpu is the high byte of the
68000's first word, as ROM_LOAD16_WORD_SWAP leaves it. verify_rom.py checks
every region against MAME's, byte for byte, after undoing the above.

FILES ARE FOUND BY CRC32, NOT BY NAME. Every zip in ZIPDIR is indexed
(central directory only), the set's own zip and its parent's preferred, so a
merged parent zip and split clone zips both work; ZIPDIR/<set>/ of loose
files too. Size and CRC must both match; zipfile re-checks the CRC as it
decompresses.

--regions writes OUTDIR/<set>_<region>.bin for every region in MAME's
logical order, for the Verilator harness.

No ROM data is in this file. The V25 opcode tables are read from MAME's
source at run time (third_party/mame/src/mame/toaplan/toaplan_v25_tables.h,
tools/bootstrap.sh fetches it), not copied in.
"""

import argparse
import hashlib
import os
import re
import struct
import sys
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
V25_TABLES_SRC = os.path.join(REPO, "third_party", "mame", "src", "mame", "toaplan",
                              "toaplan_v25_tables.h")

HEADER_SIZE = 0x1000
MAGIC = b"TPV2"
FORMAT_VERSION = 1

# Image slots, in header order. The single-GP9001 boards' "gp9001" region
# goes in gp9001_0.
SLOTS = ["maincpu", "audiocpu", "gp9001_0", "gp9001_1", "oki", "eeprom"]
SLOT_KIND = {"maincpu": "word", "audiocpu": "byte", "gp9001_0": "gfx",
             "gp9001_1": "gfx", "oki": "byte", "eeprom": "raw"}

# ---------------------------------------------------------------- boards
# From MAME's machine configs (batsugun.cpp, dogyuun.cpp, kbash.cpp,
# fixeight.cpp, vfive.cpp, 0.289). Clocks in Hz; Dogyuun's OKI is 25 MHz / 24,
# rounded. pin7: 0 low, 1 high, None no OKI. table: the V25's opcode table
# (identity = no set_decryption_table). rot: MAME's ROTxxx / 90.
BOARDS = {
    "TP-030": dict(id=0, gp=2, cpu=16_000_000, v25=16_000_000, oki=4_000_000,
                   pin7=0, workram=64, table="identity", rot=3, players=2),
    "TP-022": dict(id=1, gp=2, cpu=12_500_000, v25=12_500_000, oki=1_041_667,
                   pin7=1, workram=16, table="nitro", rot=3, players=2),
    "TP-023": dict(id=2, gp=1, cpu=16_000_000, v25=16_000_000, oki=1_000_000,
                   pin7=1, workram=16, table="nitro", rot=0, players=2),
    "TP-026": dict(id=3, gp=1, cpu=16_000_000, v25=16_000_000, oki=1_000_000,
                   pin7=1, workram=16, table="ts001turbo", rot=3, players=3),
    "TP-027": dict(id=4, gp=1, cpu=10_000_000, v25=10_000_000, oki=0,
                   pin7=None, workram=16, table="nitro", rot=3, players=2),
}
TABLE_ID = {"identity": 0, "nitro": 1, "ts001turbo": 2}

# Where each region sits in the image, per board: (slot, offset, size). The
# sizes are MAME's region sizes, which are the same for every set of a board.
LAYOUT = {
    "TP-030": [("maincpu", 0x001000, 0x080000), ("gp9001_0", 0x081000, 0x400000),
               ("gp9001_1", 0x481000, 0x200000), ("oki", 0x681000, 0x040000)],
    "TP-022": [("maincpu", 0x001000, 0x080000), ("gp9001_0", 0x081000, 0x200000),
               ("gp9001_1", 0x281000, 0x400000), ("oki", 0x681000, 0x040000)],
    "TP-023": [("maincpu", 0x001000, 0x080000), ("audiocpu", 0x081000, 0x008000),
               ("gp9001_0", 0x089000, 0x800000), ("oki", 0x889000, 0x040000)],
    "TP-026": [("maincpu", 0x001000, 0x080000), ("gp9001_0", 0x081000, 0x400000),
               ("oki", 0x481000, 0x040000), ("eeprom", 0x4c1000, 0x000080)],
    "TP-027": [("maincpu", 0x001000, 0x080000), ("gp9001_0", 0x081000, 0x200000)],
}


def image_size(board):
    return max(off + size for _, off, size in LAYOUT[board])


# ------------------------------------------------------------- ROM_START
# Transcribed from MAME 0.289's ROM_START blocks, in source order within each
# region:
#   ("L", name, crc, offset, length)   ROM_LOAD
#   ("B", name, crc, offset, length)   ROM_LOAD16_BYTE: file byte k -> offset+2k
#   ("W", name, crc, offset, length)   ROM_LOAD16_WORD_SWAP: k -> offset+(k^1)
# A region is (MAME region name, size, [loads]). The plds region (Batsugun's
# mixing GAL) is not loaded: the board has MAME's rule in logic.

def L(n, c, o, s): return ("L", n, c, o, s)
def B(n, c, o, s): return ("B", n, c, o, s)
def W(n, c, o, s): return ("W", n, c, o, s)


def _batsugun(prog, gp0, gp1, oki):
    return {"maincpu": ("maincpu", 0x080000, [W(*prog, 0x000000, 0x080000)]),
            "gp9001_0": ("gp9001_0", 0x400000, gp0),
            "gp9001_1": ("gp9001_1", 0x200000, gp1),
            "oki": ("oki", 0x040000, [L(*oki, 0x00000, 0x40000)])}


def _batsugun_gfx(p3l, p3h, p4l, p4h, p5, p6):
    return ([L(*p3l, 0x000000, 0x100000), L(*p3h, 0x100000, 0x100000),
             L(*p4l, 0x200000, 0x100000), L(*p4h, 0x300000, 0x100000)],
            [L(*p5, 0x000000, 0x100000), L(*p6, 0x100000, 0x100000)])


_BATSUGUN_GFX = _batsugun_gfx(("tp030_3l.bin", 0x3024b793), ("tp030_3h.bin", 0xed75730b),
                              ("tp030_4l.bin", 0xfedb9861), ("tp030_4h.bin", 0xd482948b),
                              ("tp030_5.bin", 0xbcf5ba05), ("tp030_6.bin", 0x0666fecd))


def _dogyuun(prog):
    return {"maincpu": ("maincpu", 0x080000, [W(*prog, 0x000000, 0x080000)]),
            "gp9001_0": ("gp9001_0", 0x200000, [
                W("tp022_3.w92", 0x191b595f, 0x000000, 0x100000),
                W("tp022_4.w93", 0xd58d29ca, 0x100000, 0x100000)]),
            "gp9001_1": ("gp9001_1", 0x400000, [
                W("tp022_5.w16", 0xd4c1db45, 0x000000, 0x200000),
                W("tp022_6.w17", 0xd48dc74f, 0x200000, 0x200000)]),
            "oki": ("oki", 0x040000, [L("tp022_2.w30", 0x043271b3, 0x00000, 0x40000)])}


def _kbash(prog):
    return {"maincpu": ("maincpu", 0x080000, [W(*prog, 0x000000, 0x080000)]),
            "audiocpu": ("audiocpu", 0x008000, [L("tp023_02.bin", 0x4cd882a1, 0x0000, 0x8000)]),
            "gp9001_0": ("gp9001", 0x800000, [
                L("tp023_3.bin", 0x32ad508b, 0x000000, 0x200000),
                L("tp023_5.bin", 0xb84c90eb, 0x200000, 0x200000),
                L("tp023_4.bin", 0xe493c077, 0x400000, 0x200000),
                L("tp023_6.bin", 0x9084b50a, 0x600000, 0x200000)]),
            "oki": ("oki", 0x040000, [L("tp023_7.bin", 0x3732318f, 0x00000, 0x40000)])}


def _fixeight(nv):
    # ROMS_FIXEIGHT, then the set's own factory EEPROM (ROM_REGION16_BE).
    return {"maincpu": ("maincpu", 0x080000, [W("tp-026-1", 0xf7b1746a, 0x000000, 0x080000)]),
            "gp9001_0": ("gp9001", 0x400000, [
                L("tp-026-3", 0xe5578d98, 0x000000, 0x200000),
                L("tp-026-4", 0xb760cb53, 0x200000, 0x200000)]),
            "oki": ("oki", 0x040000, [L("tp-026-2", 0x85063f1f, 0x00000, 0x40000)]),
            "eeprom": ("eeprom", 0x80, [L(*nv, 0x00, 0x80)])}


def _vfive(prog):
    return {"maincpu": ("maincpu", 0x080000, [W(*prog, 0x000000, 0x080000)]),
            "gp9001_0": ("gp9001", 0x200000, [
                L("tp027_02.bin", 0x877b45e8, 0x000000, 0x100000),
                L("tp027_03.bin", 0xb1fc6362, 0x100000, 0x100000)])}


def _set(board, parent, title, regions, dips):
    """dips: MAME's DSWA, DSWB, JMPR at power-on (the ports' low bytes,
    active-high as MAME reads them; the V25 sees them inverted), or None for
    a board without DIPs. Read from MAME 0.289 and checked by verify_rom.py."""
    return {"board": board, "parent": parent, "title": title,
            "regions": regions, "dips": dips}


SETS = {
    # TP-030 Batsugun
    "batsugun": _set("TP-030", None, "Batsugun",
                     _batsugun(("tp030_1a.bin", 0xcb1d4554), *_BATSUGUN_GFX,
                               ("tp030_2.bin", 0x276146f5)), (0x00, 0x00, 0x90)),
    "batsuguna": _set("TP-030", "batsugun", "Batsugun (older, set 1)",
                      _batsugun(("tp030_01.bin", 0x3873d7dd), *_BATSUGUN_GFX,
                                ("tp030_2.bin", 0x276146f5)), (0x00, 0x00, 0x90)),
    "batsugunc": _set("TP-030", "batsugun", "Batsugun (older, set 2)",
                      _batsugun(("tp-030_01.u69", 0x545305c4),
                                *_batsugun_gfx(("tp030_rom3-l.u55", 0x3024b793),
                                               ("tp030_rom3-h.u56", 0xed75730b),
                                               ("tp030_rom4-l.u54", 0xfedb9861),
                                               ("tp030_rom4-h.u57", 0xd482948b),
                                               ("tp030_rom5.u32", 0xbcf5ba05),
                                               ("tp030_rom6.u31", 0x0666fecd)),
                                ("tp030_rom2.u65", 0x276146f5)), (0x00, 0x00, 0x90)),
    # The Korean PCB: the same graphics in 512 KB EPROM pairs, byte-interleaved.
    "batsugunb": _set("TP-030", "batsugun", "Batsugun (Korean PCB)",
                      _batsugun(("large_rom1.bin", 0xc9de8ed8),
                                [B("rom12.bin", 0xd25affc6, 0x000000, 0x080000),
                                 B("rom6.bin", 0xddd6df60, 0x000001, 0x080000),
                                 B("rom11.bin", 0xed72fe3e, 0x100000, 0x080000),
                                 B("rom5.bin", 0xfd44b33b, 0x100001, 0x080000),
                                 B("rom10.bin", 0x86b2c6a9, 0x200000, 0x080000),
                                 B("rom4.bin", 0xe7c1c623, 0x200001, 0x080000),
                                 B("rom9.bin", 0xfda8ee00, 0x300000, 0x080000),
                                 B("rom3.bin", 0xa7c4dee8, 0x300001, 0x080000)],
                                [B("rom8.bin", 0xa2c6a170, 0x000000, 0x080000),
                                 B("rom2.bin", 0xa457e202, 0x000001, 0x080000),
                                 B("rom7.bin", 0x8644518f, 0x100000, 0x080000),
                                 B("rom1.bin", 0x8e339897, 0x100001, 0x080000)],
                                ("rom13.bin", 0x276146f5)), (0x00, 0x00, 0x90)),
    "batsugunsp": _set("TP-030", "batsugun", "Batsugun - Special Version",
                       _batsugun(("tp-030sp.u69", 0x8072a0cd), *_BATSUGUN_GFX,
                                 ("tp030_2.bin", 0x276146f5)), (0x00, 0x00, 0x90)),
    # TP-022 Dogyuun. dogyuun's JMPR default is 0x8030 in MAME: bit 15 is
    # MAME's own (it picks the coinage table), not on the board.
    "dogyuun": _set("TP-022", None, "Dogyuun", _dogyuun(("tp022_01.r16", 0x79eb2429)),
                    (0x00, 0x00, 0x30)),
    "dogyuuna": _set("TP-022", "dogyuun", "Dogyuun (older set)",
                     _dogyuun(("01.u64", 0xfe5bd7f4)), (0x00, 0x00, 0x30)),
    "dogyuunb": _set("TP-022", "dogyuun", "Dogyuun (oldest set)",
                     _dogyuun(("mr.u64", 0x4dc258dc)), (0x00, 0x00, 0x20)),
    "dogyuunt": _set("TP-022", "dogyuun", "Dogyuun (10/9/1992 location test)",
                     _dogyuun(("sample10.9.u64.bin", 0x585f5016)), (0x00, 0x00, 0x20)),
    # TP-023 Knuckle Bash
    "kbash": _set("TP-023", None, "Knuckle Bash", _kbash(("tp023_01.bin", 0x2965f81d)),
                  (0x00, 0x00, 0x20)),
    "kbashk": _set("TP-023", "kbash", "Knuckle Bash (Korean PCB)",
                   _kbash(("tp023_01.u52", 0x099aefbc)), (0x00, 0x00, 0x00)),
    # TP-027 Grind Stormer / V-Five
    "grindstm": _set("TP-027", None, "Grind Stormer", _vfive(("01.bin", 0x4923f790)),
                     (0x00, 0x00, 0x90)),
    "grindstma": _set("TP-027", "grindstm", "Grind Stormer (older set)",
                      _vfive(("tp027-01.rom", 0x8d8c0392)), (0x00, 0x00, 0x90)),
    "vfive": _set("TP-027", "grindstm", "V-Five (Japan)", _vfive(("tp027_01.bin", 0x731d50f4)),
                  (0x00, 0x00, 0x00)),
}

# TP-026 FixEight: fourteen sets, one board, one set of ROMs; only the
# factory EEPROM (region and licence) differs.
for _name, _crc, _title in [
        ("fixeight", 0x02e925d0, "FixEight (Europe)"),
        ("fixeightk", 0xcac91c6f, "FixEight (Korea)"),
        ("fixeighth", 0x95dec584, "FixEight (Hong Kong)"),
        ("fixeighttw", 0x74e6afb9, "FixEight (Taiwan)"),
        ("fixeighta", 0x2bf17652, "FixEight (Southeast Asia)"),
        ("fixeightu", 0x5dfefc3b, "FixEight (USA)"),
        ("fixeightj", 0x21e22038, "FixEight - Jigoku no Eiyuu Densetsu (Japan)"),
        ("fixeightt", 0xc0da4a05, "FixEight (Europe, Taito license)"),
        ("fixeightkt", 0x08fa73ba, "FixEight (Korea, Taito license)"),
        ("fixeightht", 0x57edaa51, "FixEight (Hong Kong, Taito license)"),
        ("fixeighttwt", 0xb6d5c06c, "FixEight (Taiwan, Taito license)"),
        ("fixeightat", 0xe9c21987, "FixEight (Southeast Asia, Taito license)"),
        ("fixeightut", 0x9fcd93ee, "FixEight (USA, Taito license)"),
        ("fixeightjt", 0xe3d14fed, "FixEight - Jigoku no Eiyuu Densetsu (Japan, Taito license)")]:
    SETS[_name] = _set("TP-026", None if _name == "fixeight" else "fixeight", _title,
                       _fixeight((_name + ".nv", _crc)), None)

# The order sets are built and listed in (the README's and the card's).
ORDER = ["batsugun", "batsuguna", "batsugunc", "batsugunb", "batsugunsp",
         "dogyuun", "dogyuuna", "dogyuunb", "dogyuunt", "kbash", "kbashk",
         "fixeight", "fixeightk", "fixeighth", "fixeighttw", "fixeighta", "fixeightu",
         "fixeightj", "fixeightt", "fixeightkt", "fixeightht", "fixeighttwt",
         "fixeightat", "fixeightut", "fixeightjt", "grindstm", "grindstma", "vfive"]
assert sorted(ORDER) == sorted(SETS)


# ------------------------------------------------------------ ROM finding
class RomIndex:
    """Every ROM file under ZIPDIR, keyed by (size, crc32).

    Zips: the central directory gives both without decompressing anything.
    Loose files: only under ZIPDIR/<set>/ for the sets asked about (and their
    parents), hashed on demand — a whole Downloads folder is not read.
    """

    def __init__(self, zipdir):
        self.zipdir = zipdir
        self.entries = {}        # (size, crc) -> [(stem, kind, path, member)]
        self._loose_done = set()
        for name in sorted(os.listdir(zipdir)):
            path = os.path.join(zipdir, name)
            if name.lower().endswith(".zip") and os.path.isfile(path):
                try:
                    zf = zipfile.ZipFile(path)
                except (zipfile.BadZipFile, OSError):
                    continue
                stem = os.path.splitext(name)[0]
                for info in zf.infolist():
                    if not info.is_dir():
                        self.entries.setdefault((info.file_size, info.CRC), []).append(
                            (stem, "zip", path, info.filename))
                zf.close()

    def _add_loose(self, setname):
        if setname in self._loose_done:
            return
        self._loose_done.add(setname)
        d = os.path.join(self.zipdir, setname)
        if not os.path.isdir(d):
            return
        for root, _, files in os.walk(d):
            for f in files:
                p = os.path.join(root, f)
                with open(p, "rb") as fh:
                    data = fh.read()
                self.entries.setdefault((len(data), zlib.crc32(data)), []).append(
                    (setname, "file", p, None))

    def read(self, size, crc, prefer, name):
        for s in prefer:
            self._add_loose(s)
        cands = self.entries.get((size, crc), [])
        if not cands:
            raise SystemExit(f"missing ROM {name} (size {size:#x}, crc {crc:08x}) "
                             f"in {self.zipdir}: looked in every zip, preferring "
                             f"{', '.join(p + '.zip' for p in prefer)}")
        rank = {s: i for i, s in enumerate(prefer)}
        _, kind, path, member = sorted(cands, key=lambda c: (rank.get(c[0], len(prefer)), c[0]))[0]
        if kind == "zip":
            with zipfile.ZipFile(path) as zf:
                data = zf.read(member)      # zipfile checks the CRC as it reads
        else:
            with open(path, "rb") as fh:
                data = fh.read()
        if len(data) != size or zlib.crc32(data) != crc:
            raise SystemExit(f"{name}: {path}:{member} does not match its CRC")
        return data, f"{os.path.basename(path)}:{member}" if member else path


# ------------------------------------------------------------ region build
def build_regions(setname, index, log=print):
    """MAME's regions for a set, keyed by slot, in MAME's logical byte order."""
    spec = SETS[setname]
    prefer = [setname] + ([spec["parent"]] if spec["parent"] else [])
    out = {}
    for slot in SLOTS:
        if slot not in spec["regions"]:
            continue
        mname, size, ops = spec["regions"][slot]
        buf = bytearray(size)
        for kind, name, crc, off, length in ops:
            data, where = index.read(length, crc, prefer, name)
            span = 2 * length - 1 if kind == "B" else length
            if off + span > size:
                raise SystemExit(f"{setname}:{mname}: {name} overruns the region")
            if kind == "L":
                buf[off:off + length] = data
            elif kind == "B":
                buf[off:off + span:2] = data
            elif kind == "W":
                if off & 1 or length & 1:
                    raise SystemExit(f"{setname}:{mname}: odd WORD_SWAP load")
                buf[off:off + length:2] = data[1::2]
                buf[off + 1:off + length:2] = data[0::2]
            else:
                raise AssertionError(kind)
            log(f"    {mname:<9} {off:#09x} {kind} {name:<20} {crc:08x} <- {where}")
        out[slot] = bytes(buf)
    return out


def swap16(data):
    """Each 16-bit word's two bytes exchanged (the low byte goes first)."""
    out = bytearray(len(data))
    out[0::2] = data[1::2]
    out[1::2] = data[0::2]
    return bytes(out)


def to_image(slot, logical):
    """A region in MAME's logical order -> its bytes in the image."""
    kind = SLOT_KIND[slot]
    if kind == "word":
        return swap16(logical)
    if kind == "gfx":
        half = len(logical) // 2
        lo, hi = swap16(logical[:half]), swap16(logical[half:])
        out = bytearray(len(logical))
        for k in (0, 1):
            out[k::4] = lo[k::2]
            out[2 + k::4] = hi[k::2]
        return bytes(out)
    return logical


def from_image(slot, stored):
    """The inverse of to_image: image bytes -> MAME's logical order."""
    kind = SLOT_KIND[slot]
    if kind == "word":
        return swap16(stored)
    if kind == "gfx":
        lo, hi = bytearray(len(stored) // 2), bytearray(len(stored) // 2)
        for k in (0, 1):
            lo[k::2] = stored[k::4]
            hi[k::2] = stored[2 + k::4]
        return swap16(bytes(lo)) + swap16(bytes(hi))
    return stored


# ------------------------------------------------------------- V25 tables
_TABLES = None


def v25_tables(src=V25_TABLES_SRC):
    """MAME's V25 opcode tables by name, plus the identity table."""
    global _TABLES
    if _TABLES is None:
        if not os.path.exists(src):
            raise SystemExit(f"need {src} for the V25 tables (tools/bootstrap.sh)")
        text = open(src, encoding="utf-8", errors="replace").read()
        # The tables are annotated in /* */ comments between the values.
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        text = re.sub(r"//[^\n]*", "", text)
        tabs = {"identity": list(range(256))}
        for name in ("nitro", "ts001turbo"):
            m = re.search(r"static\s+constexpr\s+u8\s+" + name +
                          r"_decryption_table\s*\[\s*256\s*\]\s*=\s*\{(.*?)\};", text, re.S)
            if not m:
                raise SystemExit(f"{name}_decryption_table not found in {src}")
            vals = [int(v, 16) for v in re.findall(r"0x([0-9a-fA-F]{1,2})\b", m.group(1))]
            if len(vals) != 256:
                raise SystemExit(f"{name}_decryption_table: {len(vals)} entries, expected 256")
            tabs[name] = vals
        _TABLES = tabs
    return _TABLES


# ------------------------------------------------------------------ header
def build_header(setname, img_len):
    spec = SETS[setname]
    board = BOARDS[spec["board"]]
    h = bytearray(HEADER_SIZE)
    h[0x000:0x004] = MAGIC
    h[0x004] = FORMAT_VERSION
    h[0x005] = board["id"]
    h[0x006] = board["gp"]
    h[0x007] = TABLE_ID[board["table"]]
    h[0x008] = board["rot"]
    h[0x009] = board["players"]
    h[0x00a] = 0xff if board["pin7"] is None else board["pin7"]
    h[0x00b] = board["workram"]
    struct.pack_into("<III", h, 0x00c, board["cpu"], board["v25"], board["oki"])
    if spec["dips"] is not None:
        h[0x018:0x01b] = bytes(spec["dips"])
        h[0x01b] = 0x07                      # DSWA, DSWB and JMPR present
    struct.pack_into("<I", h, 0x01c, img_len)
    place = {slot: (off, size) for slot, off, size in LAYOUT[spec["board"]]}
    for i, slot in enumerate(SLOTS):
        struct.pack_into("<II", h, 0x020 + 8 * i, *place.get(slot, (0, 0)))
    name = setname.encode("ascii")
    h[0x050:0x050 + len(name)] = name
    h[0x100:0x200] = bytes(v25_tables()[board["table"]])
    return bytes(h)


def parse_header(h):
    """The header's fields, for verify_rom.py and anything reading an image."""
    if h[:4] != MAGIC:
        raise ValueError("not a Toaplan V2 image (bad magic)")
    cpu, v25, oki = struct.unpack_from("<III", h, 0x00c)
    slots = {}
    for i, slot in enumerate(SLOTS):
        off, size = struct.unpack_from("<II", h, 0x020 + 8 * i)
        if size:
            slots[slot] = (off, size)
    return {"version": h[4], "board": h[5], "gp": h[6], "table": h[7], "rot": h[8],
            "players": h[9], "pin7": None if h[10] == 0xff else h[10], "workram": h[11],
            "cpu": cpu, "v25": v25, "oki": oki,
            "dips": tuple(h[0x18:0x1b]) if h[0x1b] else None,
            "length": struct.unpack_from("<I", h, 0x01c)[0], "slots": slots,
            "set": h[0x50:0x60].rstrip(b"\0").decode("ascii"),
            "v25_table": bytes(h[0x100:0x200])}


def build_image(setname, regions):
    board = SETS[setname]["board"]
    size = image_size(board)
    img = bytearray(size)
    for slot, off, slot_size in LAYOUT[board]:
        data = regions[slot]
        if len(data) != slot_size:
            raise SystemExit(f"{setname}: {slot} is {len(data):#x}, its slot {slot_size:#x}")
        img[off:off + slot_size] = to_image(slot, data)
    img[:HEADER_SIZE] = build_header(setname, size)
    return bytes(img)


# -------------------------------------------------------------------- main
def expand_sets(arg):
    if arg == "all":
        return list(ORDER)
    names = arg.split(",")
    for n in names:
        if n not in SETS:
            raise SystemExit(f"unknown set {n!r}; known: {', '.join(ORDER)}")
    return names


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("set", help="set name, comma list, or 'all'")
    ap.add_argument("zipdir", help="directory holding the MAME zips")
    ap.add_argument("outdir", help="output directory (keep it under build/)")
    ap.add_argument("--regions", action="store_true",
                    help="write <set>_<region>.bin per region instead of <set>.rom")
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()

    index = RomIndex(os.path.expanduser(a.zipdir))
    os.makedirs(a.outdir, exist_ok=True)
    log = (lambda *x: None) if a.quiet else print
    sets = expand_sets(a.set)
    for i, s in enumerate(sets, 1):
        spec = SETS[s]
        print(f"{s}: {spec['board']}, V25 table {BOARDS[spec['board']]['table']} "
              f"({i} of {len(sets)})")
        regions = build_regions(s, index, log)
        if a.regions:
            for slot, data in regions.items():
                p = os.path.join(a.outdir, f"{s}_{spec['regions'][slot][0]}.bin")
                with open(p, "wb") as f:
                    f.write(data)
                print(f"  {p}  {len(data):#x}")
        else:
            img = build_image(s, regions)
            p = os.path.join(a.outdir, f"{s}.rom")
            with open(p, "wb") as f:
                f.write(img)
            print(f"  {p}  {len(img)} bytes  sha1 {hashlib.sha1(img).hexdigest()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
