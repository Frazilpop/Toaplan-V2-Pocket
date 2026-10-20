-- SPDX-License-Identifier: GPL-3.0-or-later
-- Toaplan V2 (Pocket): trace the 68000's first N bus accesses from power-on,
-- as the oracle for the core's own trace.
--
--   tools/pocket/mame_oracle.sh tools/mame_toaplan2_bus_trace.lua batsugun \
--       BUS_TRACE_OUT=build/mame/batsugun_bus.txt BUS_TRACE_COUNT=200000
--
-- Format, one access per line (Mille Miglia's, so its diff tools read it):
--     <addr:06x> <R|W> <data:04x> <mask:04x>
-- addr is the byte address of the 16-bit word (even), mask the lanes the
-- 68000 drove (ffff word, ff00 even byte, 00ff odd byte). Lines starting '#'
-- mark frame boundaries ("# frame N" = MAME's vblank_begin of frame N).
--
-- Environment:
--   BUS_TRACE_OUT        output file (default toaplan2_bus_trace.txt)
--   BUS_TRACE_COUNT      accesses to record (default 200000)
--   BUS_TRACE_DATA_ONLY  1 = skip the program ROM (000000-07ffff) but for
--                        the autovectors (000060-00007f, so interrupts
--                        still show): RAM, I/O, VDP and palette accesses.
--                        Far fewer Lua callbacks.
--   BUS_TRACE_FRAMES     stop after this many frames whatever the count
--                        (default 3000)
--
-- FROM POWER-ON. With -autoboot_delay 0 the script runs at machine time 0,
-- before the 68000 has executed a cycle, so the first two accesses are the
-- reset vector reads at 000000/000002 and every RAM holds its power-on
-- content (MAME zero-fills).
--
-- WHAT THE BOARD RETURNS THAT A CORE MUST MATCH (Batsugun's map; Dogyuun
-- and V-Five the same less the 64 KB work RAM, Knuckle Bash and FixEight
-- elsewhere: Knuckle Bash's inputs at 2080xx, FixEight's line counter at 800000):
--   300000-30000d / 500000-50000d  GP9001 #0 / #1: the status word at +0c
--           (vblank and the busy bits) depends on the beam position, so a
--           core a few pixels off reads a different value; the polling loops
--           then differ in length, not in kind.
--   700000  the VDP's line counter (vdpcount_r): beam position again.
--   210000-21ffff  the V25's shared RAM, odd bytes: what the 68000 reads back
--           depends on how far the V25 has got — the two CPUs' interleaving.
--   20001d  coin counters/lock and, bit 5, the V25's reset (low holds it in
--           reset); the 68000's RESET instruction resets it too.
--   IRQ 4 (VDP0's vblank) is autovectored: the two vector reads at 000070.
--           Batsugun takes none: it polls 30000c and 700000 instead (none in
--           its first 513 frames, measured).

local MAX  = tonumber(os.getenv("BUS_TRACE_COUNT") or "200000")
local OUT  = os.getenv("BUS_TRACE_OUT") or "toaplan2_bus_trace.txt"
local DATA_ONLY = (os.getenv("BUS_TRACE_DATA_ONLY") or "0") ~= "0"
local MAX_FRAMES = tonumber(os.getenv("BUS_TRACE_FRAMES") or "3000")

local mach  = manager.machine
local cpu   = mach.devices[":maincpu"]
local space = cpu.spaces["program"]
local romname = emu.romname()

local fh = assert(io.open(OUT, "w"))
local n, done, frames = 0, false, 0
local t0 = os.clock()
local fmt = string.format

local function record(rw, offset, data, mask)
  if done then return end
  n = n + 1
  fh:write(fmt("%06x %s %04x %04x\n", offset & 0xffffff, rw, data & 0xffff, mask & 0xffff))
  if (n & 0x3fff) == 0 then fh:flush() end
  if n >= MAX then done = true end
end

print(fmt("bus trace: %s, script at machine time %.6f, PC %06x, %s",
          romname, mach.time:as_double(), cpu.state["PC"].value,
          DATA_ONLY and "data only" or "all accesses"))

-- Taps and notifiers are GLOBALS: a local is collected and the callback
-- stops with no error.
local ranges = DATA_ONLY and { { 0x000060, 0x00007f }, { 0x080000, 0xffffff } }
                          or { { 0x000000, 0xffffff } }
_G.tp2_taps = {}
for i, r in ipairs(ranges) do
  _G.tp2_taps[#_G.tp2_taps + 1] = space:install_read_tap(r[1], r[2], "tp2_bt_r" .. i,
    function(offset, data, mask) record("R", offset, data, mask) end)
  _G.tp2_taps[#_G.tp2_taps + 1] = space:install_write_tap(r[1], r[2], "tp2_bt_w" .. i,
    function(offset, data, mask) record("W", offset, data, mask) end)
end

-- Finishing happens here, never inside a tap: exiting from a tap tears the
-- machine down under the access in flight.
_G.tp2_bt_frame = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if not done then fh:write(fmt("# frame %d\n", frames)) end
  if done or frames >= MAX_FRAMES then
    for _, t in ipairs(_G.tp2_taps) do t:remove() end
    fh:flush(); fh:close()
    print(fmt("bus trace: %d accesses in %d frames (%.3f s emulated), %.1f s CPU -> %s",
              n, frames, mach.time:as_double(), os.clock() - t0, OUT))
    mach:exit()
  end
end)
