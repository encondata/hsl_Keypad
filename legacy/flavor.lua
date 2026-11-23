-- HSL Keypad agent: which package this is — the LEGACY package (OS 3.3.x).
--
-- scripts/package.sh --legacy ships this file as flavor.lua in place of
-- HSLKeypad/flavor.lua. See that file for the two packages.

return {
  legacy = true,
  asset = "HSLKeypad-legacy.c4z",  -- this package's file in a GitHub release
}
