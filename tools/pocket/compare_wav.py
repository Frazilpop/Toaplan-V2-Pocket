#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare the harness's sound (tb_batsugun --wav: mono 16-bit at the board's
YM2151 rate) with MAME's (-wavwrite: 48 kHz, YM2151 0.5 + OKI 0.5) over a
window of seconds from power-on.

    python3 -I tools/pocket/compare_wav.py build/mame/batsugun_attract.wav \\
        build/sim/batsugun_long/attract.wav --from 42 --to 54

Both are cut into 10 ms blocks and their loudness (RMS) compared block for
block: the onset of sound (the first block above 1 % of full scale), the
offset between the two that lines the envelopes up best, the envelopes'
correlation there and the RMS ratio. Then, at that offset, the waveforms
themselves, resampled to 48 kHz: their correlation in 100 ms windows.
"""
import argparse
import math
import struct
import sys


def read_wav(path):
    with open(path, "rb") as f:
        d = f.read()
    if d[:4] != b"RIFF" or d[8:12] != b"WAVE":
        raise SystemExit(f"{path}: not a WAV")
    pos, rate, ch, bits, data = 12, None, None, None, None
    while pos + 8 <= len(d):
        kind, n = d[pos:pos + 4], struct.unpack("<I", d[pos + 4:pos + 8])[0]
        body = d[pos + 8:pos + 8 + n]
        if kind == b"fmt ":
            _, ch, rate, _, _, bits = struct.unpack("<HHIIHH", body[:16])
        elif kind == b"data":
            data = body
        pos += 8 + n + (n & 1)
    if bits != 16:
        raise SystemExit(f"{path}: 16-bit only")
    s = struct.unpack("<%dh" % (len(data) // 2), data[:len(data) // 2 * 2])
    if ch == 2:
        s = [(s[i] + s[i + 1]) / 2 for i in range(0, len(s) - 1, 2)]
    return rate, s


def blocks(rate, s, t0, t1, ms=10):
    n = int(rate * ms / 1000)
    out = []
    for k in range(int(t0 * 1000 / ms), int(t1 * 1000 / ms)):
        a = int(k * ms / 1000 * rate)
        seg = s[a:a + n]
        out.append(math.sqrt(sum(x * x for x in seg) / len(seg)) if seg else 0.0)
    return out


def corr(a, b):
    n = min(len(a), len(b))
    if n < 2:
        return 0.0
    ma, mb = sum(a[:n]) / n, sum(b[:n]) / n
    va = sum((x - ma) ** 2 for x in a[:n])
    vb = sum((y - mb) ** 2 for y in b[:n])
    if va == 0 or vb == 0:
        return 0.0
    return sum((a[i] - ma) * (b[i] - mb) for i in range(n)) / math.sqrt(va * vb)


def resample(rate, s, to_rate, t0, t1):
    out = []
    for i in range(int(t0 * to_rate), int(t1 * to_rate)):
        x = i * rate / to_rate
        j = int(x)
        f = x - j
        if j + 1 >= len(s):
            break
        out.append(s[j] * (1 - f) + s[j + 1] * f)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mame")
    ap.add_argument("core")
    ap.add_argument("--from", dest="t0", type=float, default=42.0)
    ap.add_argument("--to", dest="t1", type=float, default=54.0)
    ap.add_argument("--max-shift", type=float, default=0.5, help="seconds")
    a = ap.parse_args()
    mr, m = read_wav(a.mame)
    cr, c = read_wav(a.core)
    print(f"MAME {len(m) / mr:.2f} s at {mr} Hz, core {len(c) / cr:.2f} s at {cr} Hz")
    for name, r, s in (("MAME", mr, m), ("core", cr, c)):
        b = blocks(r, s, 0, len(s) / r)
        on = next((k for k, v in enumerate(b) if v > 327.67), None)
        print(f"  {name}: first sound at {on / 100:.2f} s" if on is not None else f"  {name}: silent")
    mb = blocks(mr, m, a.t0, a.t1)
    best = (-2, 0)
    steps = int(a.max_shift * 100)
    for sh in range(-steps, steps + 1):
        lo = a.t0 + sh / 100
        if lo < 0:
            continue
        cb = blocks(cr, c, lo, lo + (a.t1 - a.t0))
        r = corr(mb, cb)
        if r > best[0]:
            best = (r, sh)
    r, sh = best
    cb = blocks(cr, c, a.t0 + sh / 100, a.t1 + sh / 100)
    rms_m = math.sqrt(sum(x * x for x in mb) / len(mb))
    rms_c = math.sqrt(sum(x * x for x in cb) / len(cb))
    print(f"{a.t0:.1f}-{a.t1:.1f} s: envelopes correlate {r:.4f} with the core {sh * 10:+d} ms "
          f"from MAME; RMS MAME {rms_m:.0f}, core {rms_c:.0f} (ratio {rms_c / rms_m if rms_m else 0:.3f})")
    # waveforms, 100 ms windows, at the envelope's offset (refined to a sample)
    mw = m[int(a.t0 * mr):int(a.t1 * mr)]
    cw = resample(cr, c, mr, a.t0 + sh / 100, a.t1 + sh / 100)
    win = mr // 10
    rs = []
    for k in range(0, min(len(mw), len(cw)) - win, win):
        seg = mw[k:k + win]
        if math.sqrt(sum(x * x for x in seg) / win) < 327.67:
            continue                     # silent in MAME: nothing to compare
        best_k = max(corr(mw[k:k + win], cw[k + d:k + d + win]) for d in range(-48, 49, 4)
                     if 0 <= k + d and k + d + win <= len(cw))
        rs.append(best_k)
    if rs:
        rs.sort()
        print(f"waveform correlation in {len(rs)} sounding windows of 100 ms: median {rs[len(rs) // 2]:.3f}, "
              f"worst {rs[0]:.3f}, best {rs[-1]:.3f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
