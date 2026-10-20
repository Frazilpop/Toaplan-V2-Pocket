-- SPDX-License-Identifier: GPL-3.0-or-later
-- Toaplan V2 (Pocket): trace the V25 (sound CPU) from power-on — its bus, its
-- port reads and its resets — as the oracle for the core's V25.
--
--   tools/pocket/mame_oracle.sh tools/mame_toaplan2_v25_trace.lua batsugun \
--       V25_TRACE_OUT=build/mame/batsugun_v25.txt V25_TRACE_COUNT=500000
--
-- Format, one event per line:
--     <space> <addr:05x> <R|W> <data:02x|04x>
--   P  program space (20-bit, bytes): shared RAM 80000-87fff (mirrored to
--      fffff, where the reset vector lands), YM2151 and OKI at the bottom;
--      opcode fetches included (raw bytes, before the V25's opcode table).
--   S  the special function registers, 16-bit internal data space offsets
--      100-1ff: P0 100, P1 108, PT 138 (MAME reads the DIP ports through
--      them: Batsugun PT/P0/P1 = DSWA/DSWB/JMPR, inverted), the timer and
--      interrupt registers. Internal RAM (offsets 000-0ff, the register
--      banks) only with V25_TRACE_IRAM=1.
--   #  "# frame N" (vblank_begin of frame N) and "# reset <0|1>
--      at <68000 PC>" when the 68000 writes the V25's reset line (the bit
--      written; 0 = held in reset): 20001d bit 5 on Batsugun and Dogyuun,
--      20001d bit 4 on Grind Stormer / V-Five, 700000 bit 3 on FixEight.
--      Knuckle Bash's V25 is reset only with the 68000.
--
-- Environment:
--   V25_TRACE_OUT     output file (default toaplan2_v25_trace.txt)
--   V25_TRACE_COUNT   events to record (default 500000)
--   V25_TRACE_FRAMES  stop after this many frames whatever the count (3000)
--   V25_TRACE_IRAM    1 = include internal RAM (data space 000-0ff)
--
-- Where the 68000 uploads the V25's program (all but Knuckle Bash), the V25
-- is held in reset from machine_reset until the 68000 has written the shared
-- RAM and raises the line; only the V25's own accesses are recorded, so the
-- first P events are its reset vector fetch at ffff0, after the "# reset 1".
-- Measured (MAME 0.289): Batsugun releases it in frame 6, at 68000 PC 03bfdc,
-- and the V25's first eight reads are ffff0-ffff7 (xor ax,ax; dec ax;
-- jmp a000:7e00), then a7e00 on.

local MAX  = tonumber(os.getenv("V25_TRACE_COUNT") or "500000")
local OUT  = os.getenv("V25_TRACE_OUT") or "toaplan2_v25_trace.txt"
local MAX_FRAMES = tonumber(os.getenv("V25_TRACE_FRAMES") or "3000")
local IRAM = (os.getenv("V25_TRACE_IRAM") or "0") ~= "0"

local mach  = manager.machine
local v25   = mach.devices[":audiocpu"]
local main  = mach.devices[":maincpu"]
local prog  = v25.spaces["program"]
local data  = v25.spaces["data"]
local romname = emu.romname()

local fh = assert(io.open(OUT, "w"))
local n, done, frames = 0, false, 0
local t0 = os.clock()
local fmt = string.format

local function emit(line)
  if done then return end
  n = n + 1
  fh:write(line)
  if (n & 0x3fff) == 0 then fh:flush() end
  if n >= MAX then done = true end
end

print(fmt("v25 trace: %s, script at machine time %.6f", romname, mach.time:as_double()))

_G.tp2_v25_taps = {
  prog:install_read_tap(0x00000, 0xfffff, "tp2_v25_pr",
    function(offset, d, mask) emit(fmt("P %05x R %02x\n", offset, d & 0xff)) end),
  prog:install_write_tap(0x00000, 0xfffff, "tp2_v25_pw",
    function(offset, d, mask) emit(fmt("P %05x W %02x\n", offset, d & 0xff)) end),
}
local dlo = IRAM and 0x000 or 0x100
local function sfr(rw)
  return function(offset, d, mask)
    -- 16-bit space: report the byte lane that was used.
    if mask == 0xff00 then emit(fmt("S %05x %s %02x\n", offset + 1, rw, (d >> 8) & 0xff))
    elseif mask == 0x00ff then emit(fmt("S %05x %s %02x\n", offset, rw, d & 0xff))
    else emit(fmt("S %05x %s %04x\n", offset, rw, d & 0xffff)) end
  end
end
_G.tp2_v25_taps[#_G.tp2_v25_taps + 1] = data:install_read_tap(dlo, 0x1ff, "tp2_v25_sr", sfr("R"))
_G.tp2_v25_taps[#_G.tp2_v25_taps + 1] = data:install_write_tap(dlo, 0x1ff, "tp2_v25_sw", sfr("W"))

-- The V25's reset line, as the 68000 writes it: (address, bit) by parent set.
local mspace = main.spaces["program"]
local RESET_AT = { batsugun = { 0x20001d, 0x20 }, dogyuun = { 0x20001d, 0x20 },
                   grindstm = { 0x20001d, 0x10 }, vfive = { 0x20001d, 0x10 },
                   fixeight = { 0x700001, 0x08 } }
local r
for k, v in pairs(RESET_AT) do if romname:sub(1, #k) == k then r = v end end
if r then
  _G.tp2_v25_reset_tap = mspace:install_write_tap(r[1] & ~1, r[1] | 1, "tp2_v25_rst",
    function(offset, d, mask)
      -- the byte lane the register sits on (odd address: the low lane)
      local lane = (r[1] & 1) == 1 and 0x00ff or 0xff00
      if (mask & lane) == 0 then return end
      local b = (lane == 0x00ff) and (d & 0xff) or ((d >> 8) & 0xff)
      emit(fmt("# reset %d at %06x\n", ((b & r[2]) ~= 0) and 1 or 0, main.state["PC"].value))
    end)
end

_G.tp2_v25_frame = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if not done then fh:write(fmt("# frame %d\n", frames)) end
  if done or frames >= MAX_FRAMES then
    for _, t in ipairs(_G.tp2_v25_taps) do t:remove() end
    if _G.tp2_v25_reset_tap then _G.tp2_v25_reset_tap:remove() end
    fh:flush(); fh:close()
    print(fmt("v25 trace: %d events in %d frames (%.3f s emulated), %.1f s CPU -> %s",
              n, frames, mach.time:as_double(), os.clock() - t0, OUT))
    mach:exit()
  end
end)
