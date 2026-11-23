-- HSL Keypad agent: which package this is.
--
-- There are two packages built from the same source:
--   HSLKeypad.c4z         standard — OS 3.4.x and X4 (this file)
--   HSLKeypad-legacy.c4z  legacy   — OS 3.3.x (scripts/package.sh --legacy puts
--                         legacy/flavor.lua here instead)
-- Control4 tells drivers apart by file name, so they are separate agents.

return {
  legacy = false,
  asset = "HSLKeypad.c4z",  -- this package's file in a GitHub release
}
