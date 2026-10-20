-- SPDX-License-Identifier: GPL-3.0-or-later
-- Toaplan V2 (Pocket): time a few events in MAME, in 94.5 MHz clocks from
-- power-on, to set against the harness's --events.
--
--   tools/pocket/mame_oracle.sh tools/mame_toaplan2_events.lua batsugun \
--       EVENTS_OUT=build/mame/batsugun_events.txt EVENTS_FRAMES=20
--
-- Lines: "<clock> <event>" (MAME's Lua gives no beam position; the beam is
-- at clock mod 1,584,576 = 432 x 262 x 14 of a frame from power-on), events:
--   frame N               MAME's frame notifier (where the other scripts'
--                         "# frame N" marks are)
--   m68 W 20001c <data>   the 68000 writes the coin / V25 reset latch
--   v25 W <addr> <data>   the V25 writes a shared RAM byte in EVENTS_V25
--                         (offsets into the 32 KB, comma list; default 7800)
--   m68 R 21f000 <data>   the 68000 reads that byte and gets a new value
--
-- Taps and notifiers are globals (a local is collected).

local OUT = os.getenv("EVENTS_OUT") or "toaplan2_events.txt"
local MAX_FRAMES = tonumber(os.getenv("EVENTS_FRAMES") or "20")
local WATCH = {}
for o in string.gmatch(os.getenv("EVENTS_V25") or "7800", "[^,]+") do
  WATCH[tonumber(o, 16)] = true
end

local mach = manager.machine
local main = mach.devices[":maincpu"]
local v25 = mach.devices[":audiocpu"]
local fh = assert(io.open(OUT, "w"))
local fmt = string.format
local frames = 0

local function clk()
  return math.floor(mach.time:as_double() * 94.5e6 + 0.5)
end
local function ev(s)
  fh:write(fmt("%d %s\n", clk(), s))
end

local last = {}
_G.tp2_ev = {}
_G.tp2_ev[1] = main.spaces["program"]:install_write_tap(0x20001c, 0x20001d, "tp2_ev_w",
  function(offset, data, mask) ev(fmt("m68 W 20001c %04x", data & mask)) end)
_G.tp2_ev[2] = v25.spaces["program"]:install_write_tap(0x80000, 0xfffff, "tp2_ev_v25",
  function(offset, data, mask)
    local o = offset & 0x7fff
    if WATCH[o] then ev(fmt("v25 W %05x %02x", o, data & 0xff)) end
  end)
_G.tp2_ev[3] = main.spaces["program"]:install_read_tap(0x210000, 0x21ffff, "tp2_ev_r",
  function(offset, data, mask)
    local o = (offset - 0x210000) >> 1
    if WATCH[o] then
      local d = data & 0xff
      if last[o] ~= d then last[o] = d; ev(fmt("m68 R %06x %02x", offset, d)) end
    end
  end)
-- The frame notifier's own time and beam, to place MAME's frame marks.
_G.tp2_ev_frame = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  ev(fmt("frame %d", frames))
  fh:flush()
  if frames >= MAX_FRAMES then fh:close(); mach:exit() end
end)
