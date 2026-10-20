-- SPDX-License-Identifier: GPL-3.0-or-later
-- Toaplan V2 (Pocket): record what the 68000 hands the V25 — every write to
-- the shared RAM and to the V25's reset line — so a simulation of the V25
-- alone can be fed the same traffic (sim/v25/).
--
--   tools/pocket/mame_oracle.sh tools/mame_toaplan2_v25_feed.lua batsugun \
--       V25_FEED_OUT=build/mame/batsugun_v25_feed.txt
--
-- One line per write, the time in 94.5 MHz board clocks from power-on:
--     W <clock> <shared RAM byte offset:04x> <data:02x>
--     R <clock> <0|1>        the V25's reset line (1 = running)
-- Batsugun and Dogyuun only: shared RAM 210000-21ffff (low bytes), reset
-- line 20001d bit 5. Coin 1 is pressed at frame 120 and Start 1 at frame
-- 240, so the run carries sound commands as well as the upload.
--
-- Environment:
--   V25_FEED_OUT     output file (default toaplan2_v25_feed.txt)
--   V25_FEED_FRAMES  frames to run (default 600)

local OUT    = os.getenv("V25_FEED_OUT") or "toaplan2_v25_feed.txt"
local FRAMES = tonumber(os.getenv("V25_FEED_FRAMES") or "600")

local mach = manager.machine
local prog = mach.devices[":maincpu"].spaces["program"]
local fh = assert(io.open(OUT, "w"))
local fmt = string.format

local function now()
  return math.floor(mach.time:as_double() * 94500000 + 0.5)
end

local reset_line = -1
v25_feed_taps = {
  prog:install_write_tap(0x210000, 0x21ffff, "v25_feed_shared",
    function(offset, data, mask)
      if (mask & 0x00ff) ~= 0 then
        fh:write(fmt("W %d %04x %02x\n", now(), (offset - 0x210000) >> 1,
                     data & 0xff))
      end
    end),
  prog:install_write_tap(0x20001c, 0x20001d, "v25_feed_reset",
    function(offset, data, mask)
      if (mask & 0x00ff) ~= 0 then
        local bit = (data >> 5) & 1
        if bit ~= reset_line then
          reset_line = bit
          fh:write(fmt("R %d %d\n", now(), bit))
        end
      end
    end),
}

local function find_field(name)
  for _, port in pairs(mach.ioport.ports) do
    for fname, field in pairs(port.fields) do
      if fname == name then return field end
    end
  end
  error("no input field " .. name)
end
local coin  = find_field("Coin 1")
local start = find_field("1 Player Start")

local frames = 0
emu.register_frame_done(function()
  frames = frames + 1
  coin:set_value((frames >= 120 and frames < 126) and 1 or 0)
  start:set_value((frames >= 240 and frames < 246) and 1 or 0)
  if frames >= FRAMES then
    fh:close()
    print(fmt("v25_feed: %d frames, %d clocks", frames, now()))
    mach:exit()
  end
end)
