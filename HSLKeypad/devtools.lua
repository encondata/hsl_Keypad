-- HSL Keypad agent: DEVELOPER TOOLS — developer builds only.
--
-- scripts/package.sh leaves this file (and the Developer Mode properties) out
-- of production packages and checks they're gone; only `--dev` builds have it.
--
-- With the agent's "Developer Mode" property On (it turns itself Off after 7
-- days), an already-paired Mac can send {"type":"dev", "op": …}:
--   ping                         → agent version
--   call  {fn, args}             → C4:<fn>(args…) — any Control4 API
--   eval  {code}                 → run Lua on the controller (print output captured)
--   logs  {count}                → the agent's recent log lines
-- Results come back as {"type":"devResult", "ref", "ok", …}.

local json = require("json")

local Dev = {
  WEEK = 7 * 24 * 60 * 60,
  MAX_LOG = 500,
  MAX_STRING = 256 * 1024,
  lines = {},
  ctx = nil,   -- { store, now, update, version }
}

-- Log ring buffer ------------------------------------------------------------------

function Dev.record(line)
  Dev.lines[#Dev.lines + 1] = os.date("%H:%M:%S ") .. tostring(line)
  if #Dev.lines > Dev.MAX_LOG then table.remove(Dev.lines, 1) end
end

-- Developer Mode (7-day limit) --------------------------------------------------------

function Dev.attach(ctx)
  Dev.ctx = ctx
  Dev.checkExpiry()
end

local function untilText(t) return t and os.date("%Y-%m-%d %H:%M", t) or "Off" end

--- Property changed in Composer: On starts a fresh 7-day window, Off ends it.
function Dev.modeChanged()
  local ctx = Dev.ctx
  if Properties["Developer Mode"] == "On" then
    local untilTime = ctx.now() + Dev.WEEK
    ctx.store.set("devUntil", untilTime)
    ctx.update("Developer Mode Until", untilText(untilTime))
    print("HSL Keypad: Developer Mode on until " .. untilText(untilTime))
  else
    ctx.store.set("devUntil", false)
    ctx.update("Developer Mode Until", "Off")
  end
end

--- Turns Developer Mode off once its week is up. Returns true if it's on.
function Dev.checkExpiry()
  local ctx = Dev.ctx
  if not ctx then return false end
  local untilTime = ctx.store.get("devUntil")
  local on = Properties["Developer Mode"] == "On"
  if on and (type(untilTime) ~= "number" or ctx.now() >= untilTime) then
    if type(untilTime) == "number" then print("HSL Keypad: Developer Mode expired") end
    Properties["Developer Mode"] = "Off"
    ctx.update("Developer Mode", "Off")
    ctx.store.set("devUntil", false)
    ctx.update("Developer Mode Until", "Off")
    return false
  end
  if on then ctx.update("Developer Mode Until", untilText(untilTime)) end
  return on
end

-- Results that always encode as JSON ----------------------------------------------------

local function safe(v, depth, seen)
  local kind = type(v)
  if v == nil or v == json.null then return json.null end
  if kind == "string" then
    return #v > Dev.MAX_STRING and (v:sub(1, Dev.MAX_STRING) .. "…(truncated)") or v
  end
  if kind == "number" then return (v ~= v or v == math.huge or v == -math.huge) and tostring(v) or v end
  if kind == "boolean" then return v end
  if kind ~= "table" then return tostring(v) end
  if depth > 8 then return "…(too deep)" end
  if seen[v] then return "…(cycle)" end
  seen[v] = true
  local n, isArray = 0, true
  for k in pairs(v) do
    n = n + 1
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then isArray = false end
  end
  local out
  if isArray and n > 0 and n == #v then
    out = json.array({})
    for i = 1, n do out[i] = safe(v[i], depth + 1, seen) end
  else
    out = json.object({})
    for k, val in pairs(v) do out[tostring(k)] = safe(val, depth + 1, seen) end
  end
  seen[v] = nil
  return out
end
Dev.safe = function(v) return safe(v, 0, {}) end

local function pack(...) return { n = select("#", ...), ... } end

local function results(packed, first)
  local out = json.array({})
  for i = first, packed.n do out[#out + 1] = Dev.safe(packed[i]) end
  return out
end

-- Requests ------------------------------------------------------------------------------

--- Handles one {"type":"dev"} message; returns the reply table.
function Dev.request(msg)
  if not Dev.checkExpiry() then
    return { ok = false, error = "Developer Mode is off. Turn it on in the agent's properties in Composer." }
  end
  local op = msg.op
  if op == "ping" then
    return { ok = true, version = Dev.ctx.version, developerModeUntil = untilText(Dev.ctx.store.get("devUntil")) }
  end

  if op == "call" then
    local fn = type(msg.fn) == "string" and C4 and C4[msg.fn]
    if type(fn) ~= "function" then return { ok = false, error = "C4:" .. tostring(msg.fn) .. " doesn't exist on this OS." } end
    local args = {}
    local list = type(msg.args) == "table" and msg.args or {}
    local count = #list
    for i = 1, count do args[i] = list[i] ~= json.null and list[i] or nil end
    local r = pack(pcall(fn, C4, unpack(args, 1, count)))
    if not r[1] then return { ok = false, error = tostring(r[2]) } end
    return { ok = true, results = results(r, 2) }
  end

  if op == "eval" then
    if type(msg.code) ~= "string" then return { ok = false, error = "eval needs code" } end
    local chunk, err = loadstring(msg.code, "=dev")
    if not chunk then return { ok = false, error = tostring(err) } end
    local printed, oldPrint = {}, print
    print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
      printed[#printed + 1] = table.concat(parts, "\t")
      oldPrint(...)
    end
    local r = pack(pcall(chunk))
    print = oldPrint
    if not r[1] then return { ok = false, error = tostring(r[2]), printed = json.array(printed) } end
    return { ok = true, results = results(r, 2), printed = json.array(printed) }
  end

  if op == "logs" then
    local count = math.min(tonumber(msg.count) or 100, Dev.MAX_LOG)
    local out = json.array({})
    for i = math.max(1, #Dev.lines - count + 1), #Dev.lines do out[#out + 1] = Dev.lines[i] end
    return { ok = true, lines = out }
  end

  return { ok = false, error = "Unknown dev op “" .. tostring(op) .. "” (ping, call, eval, logs)." }
end

return Dev
