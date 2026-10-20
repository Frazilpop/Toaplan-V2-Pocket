-- SPDX-License-Identifier: GPL-3.0-or-later
-- Toaplan V2 (Pocket): dump the board's video state at chosen frames, with
-- MAME's own picture of each, as the oracle for the RTL.
--
--   tools/pocket/mame_oracle.sh tools/mame_toaplan2_dump.lua batsugun \
--       DUMP_DIR=build/mame/dump/batsugun DUMP_FRAME=600,1800 \
--       WAV_OUT=build/mame/batsugun_attract.wav
--
-- Environment:
--   DUMP_DIR    output directory. One frame: files go straight in it. Several
--               (DUMP_FRAME=600,1800,...): one subdirectory f<NNNNN> each.
--   DUMP_FRAME  frame number(s), counted as MAME frame notifications from
--               power-on: frame 1 is the first picture MAME renders. The run
--               ends after the last one.
--   DUMP_SET    optional; checked against the running set.
--
-- Files (16-bit data as little-endian u16 words):
--   gp<i>_vram.bin       GP9001 #i's 16 KB, its own address space 0000-3fff:
--                        three 4 KB tile layers, then the 2 KB live sprite
--                        RAM at 3000 (mirrored at 3800)
--   gp<i>_sprbuf.bin     the 2 KB buffered sprite RAM (m_buffered) at the
--                        notifier: the sprites picture N was drawn from
--   palette.bin          400000-400fff, 2048 xBGR_555 entries
--   workram.bin          100000 up, 64 KB (TP-030) or 16 KB
--   shared.bin           the RAM the 68000 shares with the V25: 32 KB at the
--                        V25's 80000 (Knuckle Bash: 2 KB at its 00000)
--   screen.png           MAME's picture of this frame (screen:snapshot, which
--                        applies the game's rotation: 240 x 320 for ROT270)
--   frame.json           frame numbers, time, and per chip the scroll register
--                        select, voffs, the three layers' and the sprites'
--                        scroll and flip
--
-- FRAME ALIGNMENT. The notifier runs from video_manager::frame_update(),
-- which screen_device::vblank_begin() calls once picture N is rendered
-- (VIDEO_UPDATE_BEFORE_VBLANK: one screen_update per frame here) and before
-- any CPU runs again. So VRAM, registers, palette and RAM are the state the
-- tilemaps of picture N were drawn from. The sprites were drawn from the
-- buffer (m_sp.use_sprite_buffer), which the board's screen_vblank copies
-- from live sprite RAM at the same vblank — AFTER the notifier: on Batsugun's
-- attract frames 3000 and 3600 the buffer at the notifier differs from live
-- sprite RAM (MAME 0.289, measured; frame.json's sprbuf_equals_live). So
-- gp<i>_sprbuf.bin, read at notifier N, is live sprite RAM as of vblank N-1
-- and is what picture N's sprites were drawn from. screen.png is picture N;
-- screen:pixels() would be N-1 here (Mille Miglia's finding, same MAME).

local DIR = os.getenv("DUMP_DIR") or "."
local SET = os.getenv("DUMP_SET")
if DIR:sub(1, 1) ~= "/" then DIR = (os.getenv("PWD") or ".") .. "/" .. DIR end

local FRAMES, WANT = {}, {}
for s in (os.getenv("DUMP_FRAME") or "600"):gmatch("[^,]+") do
  local n = assert(tonumber(s), "bad DUMP_FRAME")
  FRAMES[#FRAMES + 1] = n; WANT[n] = true
end
table.sort(FRAMES)
local LAST = FRAMES[#FRAMES]

local mach    = manager.machine
local romname = emu.romname()
assert(not SET or SET == romname, "DUMP_SET=" .. tostring(SET) .. " but running " .. romname)

local space = mach.devices[":maincpu"].spaces["program"]
local v25   = mach.devices[":audiocpu"].spaces["program"]
local scr   = mach.screens[":screen"]

-- One or two GP9001s.
local VDPS = {}
for _, tag in ipairs({ ":gp9001_0", ":gp9001_1", ":gp9001" }) do
  if mach.devices[tag] then VDPS[#VDPS + 1] = tag end
end
local WORKRAM = romname:sub(1, 8) == "batsugun" and 0x10000 or 0x4000

local function item(tag, name)
  local idx = mach.devices[tag].items[name]
  assert(idx, "no save item " .. tag .. " " .. name)
  return emu.item(idx)
end

local chips = {}
for i, tag in ipairs(VDPS) do
  local c = { tag = tag, space = mach.devices[tag].spaces["gp9001vdp"],
              buffered = item(tag .. ":spriteram", "0/m_buffered"), regs = {} }
  for _, n in ipairs({ "0/m_scroll_reg", "0/m_voffs", "0/m_sp.scrollx", "0/m_sp.scrolly", "0/m_sp.flip" }) do
    c.regs[n] = item(tag, n)
  end
  for l = 0, 2 do
    for _, f in ipairs({ "scrollx", "scrolly", "flip" }) do
      local n = string.format("%d/m_tm[i].%s", l, f)
      c.regs[n] = item(tag, n)
    end
  end
  chips[i - 1] = c
end

-- ------------------------------------------------------------- writers
local outdir = DIR
local function words_le(get, n)
  local t, out = {}, {}
  for i = 0, n - 1 do
    local v = get(i)
    t[#t + 1] = string.char(v & 0xff, (v >> 8) & 0xff)
    if #t >= 4096 then out[#out + 1] = table.concat(t); t = {} end
  end
  out[#out + 1] = table.concat(t)
  return table.concat(out)
end
local function write(name, data)
  local f = assert(io.open(outdir .. "/" .. name, "wb"))
  f:write(data); f:close()
end
local function json_str(s) return '"' .. tostring(s):gsub('[%c"\\]', function(c)
  return string.format("\\u%04x", c:byte()) end) .. '"' end

local frame = 0

local function dump_frame(n)
  outdir = (#FRAMES > 1) and string.format("%s/f%05d", DIR, n) or DIR
  os.execute('mkdir -p "' .. outdir .. '"')
  local meta = {}
  for i = 0, #VDPS - 1 do
    local c = chips[i]
    local vram = words_le(function(k) return c.space:read_u16(k * 2) end, 0x2000)
    write(string.format("gp%d_vram.bin", i), vram)
    local buf = words_le(function(k) return c.buffered:read(k) end, c.buffered.count)
    write(string.format("gp%d_sprbuf.bin", i), buf)
    local live = vram:sub(0x3000 + 1, 0x3800)
    local regs = {}
    local names = {}
    for k, _ in pairs(c.regs) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do
      regs[#regs + 1] = string.format("%s: %d", json_str(k), c.regs[k]:read(0))
    end
    meta[#meta + 1] = string.format('  "gp%d": { "tag": %s, "sprbuf_equals_live": %s, ' ..
      '"regs": { %s } }', i, json_str(c.tag), tostring(buf == live), table.concat(regs, ", "))
  end
  write("palette.bin", words_le(function(k) return space:read_u16(0x400000 + k * 2) end, 0x800))
  write("workram.bin", words_le(function(k) return space:read_u16(0x100000 + k * 2) end, WORKRAM // 2))
  local t = {}
  local lo, hi = 0x80000, 0x87fff
  if romname:sub(1, 5) == "kbash" then lo, hi = 0x00000, 0x007ff end
  for a = lo, hi do t[#t + 1] = string.char(v25:read_u8(a)) end
  write("shared.bin", table.concat(t))
  local err = scr:snapshot(outdir .. "/screen.png")

  local f = assert(io.open(outdir .. "/frame.json", "w"))
  f:write("{\n")
  f:write(string.format('  "set": %s,\n  "frame": %d,\n  "screen_frame_number": %d,\n',
          json_str(romname), n, scr:frame_number()))
  f:write(string.format('  "machine_time": "%.9f",\n', mach.time:as_double()))
  f:write(string.format('  "picture": %s,\n', json_str("screen.png = picture " .. n ..
          (err and (" (snapshot error " .. tostring(err) .. ")") or ""))))
  f:write(table.concat(meta, ",\n") .. "\n}\n")
  f:close()
  print(string.format("dump: frame %d (screen frame %d) -> %s", n, scr:frame_number(), outdir))
end

_G.tp2_dump_frame = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if WANT[frame] then dump_frame(frame) end
  if frame >= LAST then mach:exit() end
end)
