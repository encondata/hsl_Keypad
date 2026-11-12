local Updates = require("updates")
local json = require("json")

check(Updates.newer("0.0.3", "0.0.2") and Updates.newer("v0.1.0", "0.0.9") and Updates.newer("1.0", "0.9.9"), "newer versions")
check(not Updates.newer("0.0.2", "0.0.2") and not Updates.newer("0.0.1", "0.0.2"), "same or older isn't newer")
check(not Updates.newer("nightly", "0.0.2"), "non-versions ignored")
check(Updates.parse("v0.0.3-beta")[3] == 3, "suffixes tolerated")

local releases = json.decode([[
[
  {"tag_name":"v0.0.2","name":"HSL Keypad 0.0.2","draft":false,"prerelease":true,"html_url":"https://github.com/encondata/hsl_Keypad/releases/tag/v0.0.2",
   "assets":[{"name":"HSLKeypad.c4z","browser_download_url":"https://github.com/encondata/hsl_Keypad/releases/download/v0.0.2/HSLKeypad.c4z"}]},
  {"tag_name":"v0.0.9","draft":true,"html_url":"x","assets":[]},
  {"tag_name":"v0.0.4","name":"HSL Keypad 0.0.4","draft":false,"prerelease":true,"html_url":"https://github.com/encondata/hsl_Keypad/releases/tag/v0.0.4",
   "assets":[{"name":"notes.txt","browser_download_url":"n"},{"name":"HSLKeypad.c4z","browser_download_url":"https://github.com/encondata/hsl_Keypad/releases/download/v0.0.4/HSLKeypad.c4z"}]},
  {"tag_name":"v0.0.1","draft":false,"html_url":"y","assets":[]}
]
]])
local latest = Updates.latest(releases)
check(latest.version == "0.0.4", "highest non-draft release wins (draft 0.0.9 skipped)")
check(latest.url:match("/tag/v0%.0%.4$") ~= nil and latest.c4z:match("v0%.0%.4/HSLKeypad%.c4z$") ~= nil, "release page and .c4z link")
check(Updates.latest({}) == nil and Updates.latest(nil) == nil and Updates.latest({ "junk" }) == nil, "nothing usable → nil")

-- check() through a fake C4:url()
local function fakeUrl(code, body, errCode)
  return function()
    local t = {}
    function t:OnDone(fn) self.done = fn; return self end
    function t:SetOptions() return self end
    function t:Get(url, headers)
      self.url, self.headers = url, headers
      self.done(self, code and { { code = code, body = body, headers = {} } } or {}, errCode or 0, errCode and "boom" or nil)
      return self
    end
    return t
  end
end
local savedC4 = C4
C4 = { url = fakeUrl(200, json.encode(releases)) }
local result, err
Updates.check("0.0.3", function(r, e) result, err = r, e end)
check(result and result.available == true and result.latest.version == "0.0.4" and err == nil, "check finds 0.0.4 over 0.0.3")
Updates.check("0.0.4", function(r) result = r end)
check(result.available == false, "up to date")
C4 = { url = fakeUrl(403, "{}") }
Updates.check("0.0.3", function(r, e) result, err = r, e end)
check(result == nil and err == "GitHub answered 403.", "HTTP error reported")
C4 = { url = fakeUrl(nil, nil, 6) }
Updates.check("0.0.3", function(r, e) result, err = r, e end)
check(result == nil and err:find("Couldn't reach GitHub") ~= nil, "network error reported")
C4 = {}
Updates.check("0.0.3", function(r, e) result, err = r, e end)
check(result == nil and err:find("no C4:url") ~= nil, "missing API reported")
C4 = savedC4
