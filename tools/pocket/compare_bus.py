#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare two 68000 bus traces (MAME's tools/mame_toaplan2_bus_trace.lua and
the harness's tb_batsugun --trace), access for access.

    python3 -I tools/pocket/compare_bus.py build/mame/batsugun_bus.txt build/sim/batsugun/bus.txt

Each line is "<addr> <R|W> <data> <mask>"; data is compared under the mask
(MAME's read taps give the whole word even for a byte read). '#' lines are
frame marks: shown in the report, not compared. Stops at the first
difference and prints the context, or reports how many accesses agree.
--resync N: after a difference, skip ahead on both sides to the next access
that is not a read of a beam-timed address (30000c, 50000c, 700000, 800000), allowing
for polling loops of different lengths; N is how many differences to allow.
"""
import argparse
import sys

BEAM = {0x30000c, 0x50000c, 0x700000, 0x800000}   # 800000: FixEight's line counter


def read(path):
    out, frame = [], 0
    with open(path) as f:
        for line in f:
            if line.startswith('#'):
                if line.startswith('# frame'):
                    frame = int(line.split()[2])
                continue
            p = line.split()
            if len(p) != 4:
                continue
            a, rw, d, m = int(p[0], 16), p[1], int(p[2], 16), int(p[3], 16)
            out.append((a, rw, d & m, m, frame))
    return out


def fmt(x):
    return f"{x[0]:06x} {x[1]} {x[2]:04x} {x[3]:04x}  (frame {x[4]})"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mame")
    ap.add_argument("core")
    ap.add_argument("--resync", type=int, default=0)
    ap.add_argument("--context", type=int, default=8)
    a = ap.parse_args()
    m, c = read(a.mame), read(a.core)
    i = j = same = 0
    diffs = 0
    resynced = 0
    while i < len(m) and j < len(c):
        if m[i][:4] == c[j][:4]:
            i += 1; j += 1; same += 1
            continue
        # A beam-timed poll on either side: skip polls until both agree.
        if a.resync and diffs < a.resync:
            ii, jj = i, j
            while ii < len(m) and (m[ii][0] in BEAM and m[ii][1] == 'R'):
                ii += 1
            while jj < len(c) and (c[jj][0] in BEAM and c[jj][1] == 'R'):
                jj += 1
            # step back to the access before the polls on both sides
            if (ii, jj) != (i, j) and ii < len(m) and jj < len(c) and m[ii][:4] == c[jj][:4]:
                resynced += 1
                i, j = ii, jj
                continue
            # polling loops: the loop body (ROM reads) differs in count too;
            # find the next common non-poll write on both sides
            diffs += 1
            print(f"difference {diffs} at MAME {i} / core {j}:")
            print("  MAME:", fmt(m[i]))
            print("  core:", fmt(c[j]))
            found = False
            for ii in range(i, min(len(m), i + 200000)):
                if m[ii][1] != 'W':
                    continue
                for jj in range(j, min(len(c), j + 200000)):
                    if c[jj][:4] == m[ii][:4] and c[jj][1] == 'W':
                        print(f"  resynced at the write {fmt(m[ii])}: skipped {ii - i} MAME / {jj - j} core")
                        i, j = ii, jj
                        found = True
                        break
                break
            if found:
                continue
        print(f"first difference after {same} identical accesses (MAME line {i}, core line {j}):")
        for k in range(max(0, i - a.context), min(len(m), i + a.context)):
            mk = fmt(m[k])
            ck = fmt(c[j - i + k]) if 0 <= j - i + k < len(c) else "-"
            flag = "  " if k < i else ">>"
            print(f"{flag} {mk:40s} | {ck}")
        return 1
    polls_m = sum(1 for x in m[:i] if x[0] in BEAM and x[1] == 'R')
    print(f"{same} accesses identical ({resynced} poll resyncs, {diffs} differences skipped); "
          f"MAME has {len(m)}, core {len(c)}")
    print(f"compared to MAME line {i} (frame {m[i - 1][4] if i else 0}), core line {j} "
          f"(frame {c[j - 1][4] if j else 0}); {i - polls_m} of MAME's accesses there are not "
          f"beam-timed polls")
    return 0


if __name__ == "__main__":
    sys.exit(main())
