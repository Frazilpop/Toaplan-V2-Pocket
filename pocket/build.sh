#!/bin/sh
# Toaplan V2 for Analogue Pocket — build the bitstream.
#
#   pocket/build.sh            the core (pocket/src/fpga, the board via board.qip)
#   pocket/build.sh --clean    empty db/ and incremental_db/ first, so smart
#                              recompilation cannot skip a stage
#
# Runs Quartus Prime Lite 21.1 in Docker (raetro/quartus:21.1, linux/amd64),
# here under Colima with Rosetta. The WHOLE repository is mounted, because the
# project in pocket/src/fpga reaches ../../../rtl and ../../../third_party.
# Colima shares $HOME only — a checkout under /tmp would mount as empty.
#
# Generated files stay under build/ (the repo's rule): db/, incremental_db/
# and output_files/ in the project directory are symlinks into
# build/pocket/quartus/, made here on first use, as are the links the RTL's
# memory files are read through (rtl, microrom.mem, nanorom.mem: $readmem
# paths are relative to the project directory). The one exception is
# Analogue's own pre-flow script, which writes apf/build_id.mif with the
# build date at the start of every compile; it is ignored, not tracked, so a
# build leaves the tree clean.
#
# Afterwards: the fit and the worst slack per clock are printed, and only if
# every clock meets timing at every corner is the bit-reversed bitstream the
# Pocket loads written to pocket/dist/Cores/frazilpop.Toaplan V2/bitstream.rbf_r.
# On negative slack the script fails and leaves dist alone; the bitstream it
# made is kept as build/pocket/quartus/bitstream.rbf_r.failed for a look.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
fpga=$repo/pocket/src/fpga
qb=$repo/build/pocket/quartus
dist="$repo/pocket/dist/Cores/frazilpop.Toaplan V2"
image=raetro/quartus:21.1

clean=0
for arg in "$@"; do
    case "$arg" in
        --clean) clean=1 ;;
        -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
        *) echo "build.sh: unknown argument '$arg'" >&2; exit 2 ;;
    esac
done

case "$repo" in
    "$HOME"/*) ;;
    *) echo "build.sh: the repository must be under \$HOME ($HOME); Colima shares nothing else." >&2
       exit 1 ;;
esac

for f in "$repo/third_party/pocket-utils/ip/data_loader.sv" "$repo/third_party/fx68k/hdl/microrom.mem" \
         "$repo/third_party/IKAOPM/src/IKAOPM.v" "$repo/third_party/jt6295/hdl/jt6295.v"; do
    [ -f "$f" ] || { echo "build.sh: missing $f (run tools/bootstrap.sh?)" >&2; exit 1; }
done

# ------------------------------------------------------------ one at a time
# Two Quartus runs in one project write the same db/ and the same log, and
# neither finishes cleanly. The DCMSX page and a chat can both
# start this script, so it takes a lock (mkdir is atomic) and refuses while
# another build holds it. A lock left by a killed build is cleared once its
# pid is gone.
lock=$repo/build/pocket/build.lock
mkdir -p "$repo/build/pocket"
if ! mkdir "$lock" 2>/dev/null; then
    other=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
        echo "build.sh: another build is running (pid $other); not starting a second." >&2
        exit 1
    fi
    rm -rf "$lock"; mkdir "$lock"
fi
echo $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT INT TERM

# ---------------------------------------------------- generated -> build/
mkdir -p "$qb/db" "$qb/incremental_db" "$qb/output_files"
for d in db incremental_db output_files; do
    if [ -L "$fpga/$d" ]; then
        :
    elif [ -e "$fpga/$d" ]; then
        echo "build.sh: $fpga/$d is a real directory; move it aside so it can be a link into build/." >&2
        exit 1
    else
        # Relative, so it resolves the same inside the container (/build/...).
        ln -s "../../../build/pocket/quartus/$d" "$fpga/$d"
    fi
done

# The RTL's memory files, read relative to the project directory.
for l in "rtl:../../../rtl" "microrom.mem:../../../third_party/fx68k/hdl/microrom.mem" \
         "nanorom.mem:../../../third_party/fx68k/hdl/nanorom.mem"; do
    name=${l%%:*}; target=${l#*:}
    [ -L "$fpga/$name" ] || ln -s "$target" "$fpga/$name"
done

if [ "$clean" = 1 ]; then
    echo "== clean: emptying $qb/db and $qb/incremental_db"
    find "$qb/db" "$qb/incremental_db" -mindepth 1 -delete
fi

log=$qb/compile.log
echo "== Quartus 21.1 ($image)"
echo "   log: $log"
start=$(date +%s)
if ! docker run --rm --platform linux/amd64 \
        -v "$repo":/build -w /build/pocket/src/fpga \
        "$image" quartus_sh --flow compile ap_core > "$log" 2>&1; then
    echo "== COMPILE FAILED"
    grep -E "^Error|^ *Error \(" "$log" | head -40
    exit 1
fi
echo "   compiled in $(( $(date +%s) - start )) s"

# Critical warnings are worth a look every time; they are where a wrong pin or
# an ignored constraint shows up.
crit=$(grep -c "^Critical Warning" "$log" || true)
if [ "$crit" != "0" ]; then
    echo "== $crit critical warning(s):"
    grep "^Critical Warning" "$log" | sort -u | head -20
fi

# ------------------------------------------------------------- bitstream
rbf=$qb/output_files/ap_core.rbf
[ -f "$rbf" ] || { echo "build.sh: no $rbf" >&2; exit 1; }
rbf_r=$qb/bitstream.rbf_r.new
python3 -I - "$rbf" "$rbf_r" <<'EOF'
import sys
# APF wants every byte of the .rbf bit-reversed (Analogue: Packaging a Core).
src, dst = sys.argv[1], sys.argv[2]
table = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))
data = open(src, "rb").read()
open(dst, "wb").write(data.translate(table))
print(f"== bitstream: {len(data)} bytes")
EOF

# ------------------------------------------------------------- reports
status=0
python3 -I - "$qb/output_files" <<'EOF' || status=$?
import os, re, sys
out = sys.argv[1]

fit = open(os.path.join(out, "ap_core.fit.summary")).read()
print("== fit (5CEBA4F23C8)")
for key in ("Logic utilization (in ALMs)", "Total registers", "Total pins",
            "Total block memory bits", "Total RAM Blocks", "Total DSP Blocks",
            "Total PLLs"):
    m = re.search(re.escape(key) + r"\s*:\s*(.+)", fit)
    if m:
        print(f"   {key:<28} {m.group(1).strip()}")

sta = open(os.path.join(out, "ap_core.sta.summary")).read()
worst = {}
for typ, slack in re.findall(r"Type\s*:\s*(.+?)\nSlack\s*:\s*(-?[\d.]+)", sta):
    m = re.match(r"(.+?) Model (Setup|Hold|Recovery|Removal|Minimum Pulse Width) '(.+)'", typ)
    if not m:
        continue
    corner, kind, clk = m.groups()
    k = (clk, kind)
    s = float(slack)
    if k not in worst or s < worst[k][0]:
        worst[k] = (s, corner)

names = {
    "general[0]": "clk_sys 94.5",
    "general[1]": "clk_sdram_ps 94.5/180",
    "general[2]": "clk_vid 6.75",
    "general[3]": "clk_vid90 6.75/90",
}
def label(clk):
    for k, v in names.items():
        if k in clk:
            return v
    return clk

print("== timing: worst slack per clock over all corners (ns)")
fail = False
for clk in sorted({c for c, _ in worst}, key=label):
    row = []
    for kind in ("Setup", "Hold", "Recovery", "Removal"):
        if (clk, kind) in worst:
            s, corner = worst[(clk, kind)]
            row.append(f"{kind.lower()} {s:+.3f}")
            if s < 0:
                fail = True
    print(f"   {label(clk):<22} " + "  ".join(row))
if fail:
    print("== NEGATIVE SLACK: timing is not met")
    sys.exit(1)
print("== timing met")
EOF

# ------------------------------------------------------------- dist
# A bitstream that misses timing never reaches dist, so deploy.sh cannot put
# it on the card.
if [ "$status" != 0 ]; then
    mv "$rbf_r" "$qb/bitstream.rbf_r.failed"
    echo "== bitstream NOT written to dist" >&2
    exit 1
fi
mkdir -p "$dist"
mv "$rbf_r" "$dist/bitstream.rbf_r"
echo "== written: $dist/bitstream.rbf_r"
