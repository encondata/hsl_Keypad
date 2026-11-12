-- HSL Keypad agent: checks GitHub for a newer release.
--
-- Control4 only auto-installs drivers hosted in its own driver database, so
-- this only *reports* updates (Composer property + the Mac app); installing is
-- still Driver → Add or Update Driver or Agent in Composer.
--
-- Uses the documented C4:url() interface (OS 2.10.5+):
--   C4:url():OnDone(fn(transfer, responses, errCode, errMsg)):SetOptions({...}):Get(url, headers)

local json = require("json")

local Updates = {}

Updates.REPO = "encondata/hsl_Keypad"
Updates.API = "https://api.github.com/repos/" .. Updates.REPO .. "/releases?per_page=20"
Updates.PAGE = "https://github.com/" .. Updates.REPO .. "/releases"

--- "v0.0.3" / "0.0.3" / "0.0.3-beta" → { 0, 0, 3 } (nil if not a version)
function Updates.parse(text)
  local a, b, c = tostring(text or ""):match("^v?(%d+)%.(%d+)%.?(%d*)")
  if not a then return nil end
  return { tonumber(a), tonumber(b), tonumber(c) or 0 }
end

--- true if version string `a` is newer than `b`
function Updates.newer(a, b)
  local va, vb = Updates.parse(a), Updates.parse(b)
  if not va or not vb then return false end
  for i = 1, 3 do
    if va[i] ~= vb[i] then return va[i] > vb[i] end
  end
  return false
end

--- From a GitHub releases list (decoded JSON), the newest published release
--- (pre-releases included, drafts skipped) as { version, url, name, c4z }.
function Updates.latest(releases)
  local best
  for _, r in ipairs(type(releases) == "table" and releases or {}) do
    if type(r) == "table" and r.draft ~= true and Updates.parse(r.tag_name) then
      local version = tostring(r.tag_name):gsub("^v", "")
      if not best or Updates.newer(version, best.version) then
        local c4z
        for _, asset in ipairs(type(r.assets) == "table" and r.assets or {}) do
          if type(asset) == "table" and tostring(asset.name):match("%.c4z$") then c4z = asset.browser_download_url end
        end
        best = { version = version, url = r.html_url or Updates.PAGE, name = r.name, c4z = c4z }
      end
    end
  end
  return best
end

--- Fetches the releases and calls done(result, err) where result is
--- { latest = {...} or nil, available = bool } — `available` when newer than `current`.
function Updates.check(current, done)
  if not C4 or type(C4.url) ~= "function" then
    done(nil, "This OS has no C4:url() web interface.")
    return
  end
  local ok, err = pcall(function()
    C4:url()
      :OnDone(function(_, responses, errCode, errMsg)
        if errCode ~= 0 then
          done(nil, errCode == -1 and "Check cancelled." or ("Couldn't reach GitHub (" .. tostring(errMsg or errCode) .. ")."))
          return
        end
        local last = responses and responses[#responses]
        if not last or tonumber(last.code) ~= 200 then
          done(nil, "GitHub answered " .. tostring(last and last.code or "nothing") .. ".")
          return
        end
        local decoded, releases = pcall(json.decode, tostring(last.body or ""))
        if not decoded then
          done(nil, "Couldn't read GitHub's reply.")
          return
        end
        local latest = Updates.latest(releases)
        done({ latest = latest, available = latest ~= nil and Updates.newer(latest.version, current) })
      end)
      :SetOptions({ fail_on_error = false, timeout = 30, connect_timeout = 10 })
      :Get(Updates.API, {
        ["User-Agent"] = "HSL-Keypad-Agent/" .. tostring(current),  -- GitHub requires one
        ["Accept"] = "application/vnd.github+json",
      })
  end)
  if not ok then done(nil, "Update check failed: " .. tostring(err)) end
end

return Updates
