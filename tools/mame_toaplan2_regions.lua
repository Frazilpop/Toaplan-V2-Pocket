-- SPDX-License-Identifier: GPL-3.0-or-later
-- Toaplan V2 (Pocket): dump MAME's ROM regions and DIP defaults for a set, so
-- tools/pocket/verify_rom.py can check the .rom image byte for byte.
--
--   DUMP_DIR=build/mame/regions/batsugun \
--   mame -rompath ~/Downloads batsugun -autoboot_script tools/mame_toaplan2_regions.lua \
--        -skip_gameinfo -autoboot_delay 0 -video none -sound none -nothrottle
--
-- (verify_rom.py runs it.) Writes <region>.bin for every region the
-- set has (maincpu, audiocpu, gp9001_0, gp9001_1, gp9001, oki, eeprom, plds),
-- each at MAME's region size, and regions.txt: one line a region (size,
-- endianness, width) and one a DIP port (DSWA, DSWB, JMPR as MAME reads them
-- at power-on).
--
-- LOGICAL BYTE ORDER. The 16-bit regions are big-endian and MAME stores them
-- byte-swapped on a little-endian host; memory_region:read_u32 in the
-- region's own endianness undoes that, so byte 0 here is the high byte of the
-- first word — MAME's logical order, which build_rom.py builds.

local DIR  = os.getenv("DUMP_DIR") or "."
local mach = manager.machine
local NAMES = { "maincpu", "audiocpu", "gp9001_0", "gp9001_1", "gp9001", "oki", "eeprom", "plds" }

local function dump(name)
  local r = mach.memory.regions[":" .. name]
  if not r then return nil end
  local f = assert(io.open(DIR .. "/" .. name .. ".bin", "wb"))
  local fmt = (r.endianness == "big") and ">I4" or "<I4"
  local size = r.size
  local chunk = {}
  local a = 0
  while a + 4 <= size do
    chunk[#chunk + 1] = string.pack(fmt, r:read_u32(a))
    a = a + 4
    if #chunk >= 8192 then f:write(table.concat(chunk)); chunk = {} end
  end
  while a < size do chunk[#chunk + 1] = string.char(r:read_u8(a)); a = a + 1 end
  f:write(table.concat(chunk))
  f:close()
  return string.format("region %s size=%d endianness=%s bitwidth=%d\n", name, size, r.endianness, r.bitwidth)
end

local meta = assert(io.open(DIR .. "/regions.txt", "w"))
meta:write("set=" .. emu.romname() .. "\n")
for _, n in ipairs(NAMES) do
  local line = dump(n)
  if line then meta:write(line) end
end
for _, n in ipairs({ "DSWA", "DSWB", "JMPR" }) do
  local p = mach.ioport.ports[":" .. n]
  if p then meta:write(string.format("port %s %d\n", n, p:read())) end
end
meta:close()
mach:exit()
