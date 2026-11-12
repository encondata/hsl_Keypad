-- Runs the HSL Keypad agent's Lua tests on a Mac:  luajit Control4/tests/run.lua
local here = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = here .. "../HSLKeypad/?.lua;" .. here .. "?.lua;" .. package.path

local failures, passes = 0, 0
function check(cond, name)
  if cond then
    passes = passes + 1
  else
    failures = failures + 1
    print("FAIL " .. name)
  end
end

for _, file in ipairs({ "test_json", "test_core" }) do
  dofile(here .. file .. ".lua")
end

print(string.format("%d passed, %d failed", passes, failures))
os.exit(failures == 0 and 0 or 1)
