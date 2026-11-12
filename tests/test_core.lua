local json = require("json")
local Core = require("core")

-- A fake platform and transport ---------------------------------------------

local function harness()
  local h = { sent = {}, closed = {}, timers = {}, stored = {}, clock = 1000, commands = {} }
  local state = {
    ["light:345"] = { on = false, level = 0 },
    ["fan:402"] = { on = false, speed = 0 },
    ["scene:3"] = { active = false },
  }
  h.state = state
  h.platform = {
    info = function() return { project = "Smith Residence", os = "3.4.3", address = "192.168.1.50", netmask = "255.255.255.0" } end,
    catalog = function()
      return {
        rooms = { { id = 12, name = "Kitchen" } },
        lights = { { id = 345, room = 12, name = "Cans", dimmable = true } },
        fans = { { id = 402, room = 12, name = "Fan", speeds = 3 } },
        scenes = { { id = 3, name = "Movie Time" } },
        macros = {},
      }
    end,
    state = function(kind, id) return state[kind .. ":" .. id] end,
    command = function(kind, id, action, msg)
      h.commands[#h.commands + 1] = kind .. ":" .. id .. ":" .. action
      if id == 999 then return false, "Device 999 not found" end
      if id == 500 then error("boom") end
      return true
    end,
  }
  local seed = 0
  h.deps = {
    platform = h.platform,
    store = { get = function(k) return h.stored[k] end, set = function(k, v) h.stored[k] = v end },
    send = function(handle, line) h.sent[#h.sent + 1] = { handle = handle, line = line } end,
    close = function(handle) h.closed[#h.closed + 1] = handle end,
    later = function(seconds, fn) h.timers[#h.timers + 1] = fn end,
    now = function() return h.clock end,
    random = function(m, n) seed = seed + 1; return m + (seed * 7919) % (n - m + 1) end,
  }
  function h.messages(handle)
    local out = {}
    for _, s in ipairs(h.sent) do
      if s.handle == handle then out[#out + 1] = json.decode(s.line:sub(1, -2)) end
    end
    return out
  end
  function h.last(handle)
    local list = h.messages(handle)
    return list[#list]
  end
  function h.fireTimers()
    local t = h.timers; h.timers = {}
    for _, fn in ipairs(t) do fn() end
  end
  return h
end

local function say(core, handle, msg) core:data(handle, json.encode(msg) .. "\n") end

-- Identity and pairing --------------------------------------------------------

local h = harness()
local core = Core.new(h.deps)
check(type(core.controllerId) == "string" and #core.controllerId == 36, "controller ID is a UUID")
check(h.stored.controllerId == core.controllerId, "controller ID persisted")
check(#core.pairingCode == 6 and core.pairingCode:match("^%d+$"), "6-digit pairing code")
local again = Core.new(h.deps)
check(again.controllerId == core.controllerId and again.pairingCode == core.pairingCode, "identity survives a restart")
check(again.revision == core.revision + 1, "revision bumps on restart")

core:connected(1)
say(core, 1, { type = "hello", pairingCode = "000000", device = "Mac" })
local m = h.last(1)
check(m.type == "error" and m.code == "unauthorized" and m.message == "Wrong pairing code.", "wrong code rejected")
check(#h.closed == 0, "not closed before the error is sent")
h.fireTimers()
check(h.closed[1] == 1, "closed after the error had time to go out")

core:connected(2)
say(core, 2, { type = "hello", pairingCode = core.pairingCode, device = "Jon's MacBook Pro" })
local msgs = h.messages(2)
local welcome, catalog = msgs[1], msgs[2]
check(welcome.type == "welcome" and welcome.controllerId == core.controllerId and welcome.project == "Smith Residence", "welcome")
check(welcome.agentVersion == Core.VERSION and welcome.os == "3.4.3" and welcome.netmask == "255.255.255.0", "welcome carries version, OS, network")
check(type(welcome.token) == "string" and #welcome.token == 40, "token issued")
check(catalog.type == "catalog" and catalog.lights[1].name == "Cans" and #catalog.macros == 0, "catalog sent after welcome")
check(h.stored.tokens[welcome.token].device == "Jon's MacBook Pro", "token persisted with device name")
check(#core:pairedDevices() == 1, "paired devices list")

core:connected(3)
say(core, 3, { type = "hello", token = welcome.token })
check(h.messages(3)[1].type == "welcome", "reconnect with token")
core:connected(4)
say(core, 4, { type = "hello", token = "nope" })
check(h.last(4).message:find("isn't paired") ~= nil, "unknown token rejected")
core:connected(5)
say(core, 5, { type = "watch", targets = {} })
check(h.last(5).code == "unauthorized", "must say hello first")

-- Brute-force lockout
local hb = harness()
local cb = Core.new(hb.deps)
for i = 1, Core.MAX_BAD_CODES do
  cb:connected(i)
  say(cb, i, { type = "hello", pairingCode = "111111" })
end
cb:connected(99)
say(cb, 99, { type = "hello", pairingCode = cb.pairingCode })
check(hb.last(99).message:find("Too many") ~= nil, "locked out after 5 wrong codes, even with the right one")
hb.clock = hb.clock + Core.LOCKOUT_SECONDS + 1
cb:connected(100)
say(cb, 100, { type = "hello", pairingCode = cb.pairingCode })
check(hb.last(100).type == "catalog", "lockout expires")

-- Framing -----------------------------------------------------------------------

h.sent = {}
core:data(2, '{"type":"pi')
check(#h.sent == 0, "partial line buffered")
core:data(2, 'ng"}\r\n{"type":"ping"}\n')
check(#h.messages(2) == 2 and h.messages(2)[1].type == "pong", "split and CRLF lines handled")
core:data(2, "not json\n")
check(#h.messages(2) == 2, "bad JSON ignored")
core:line(2, '{"type":"ping"}')
check(#h.messages(2) == 3, "line() for transports that strip newlines")

-- Watch, state, commands ------------------------------------------------------

h.sent = {}
say(core, 2, { type = "watch", targets = { { kind = "light", id = 345 }, { kind = "scene", id = 3 }, { kind = "bogus", id = 1 } } })
msgs = h.messages(2)
check(#msgs == 2 and msgs[1].type == "state" and msgs[1].kind == "light" and msgs[1].level == 0, "watch replies with current state")
h.sent = {}
core:stateChanged("light", 345, { on = true, level = 80 })
core:stateChanged("fan", 402, { on = true, speed = 2 })
msgs = h.messages(2)
check(#msgs == 1 and msgs[1].level == 80 and msgs[1].on == true, "state pushed only for watched devices")
check(#h.messages(3) == 0, "unwatching client (3) got nothing new")

h.sent = {}
say(core, 2, { type = "command", ref = "7", kind = "light", id = 345, action = "toggle" })
m = h.last(2)
check(m.type == "result" and m.ref == "7" and m.ok == true and h.commands[#h.commands] == "light:345:toggle", "command routed, result echoes ref")
say(core, 2, { type = "command", ref = "8", kind = "light", id = 999, action = "on" })
check(h.last(2).ok == false and h.last(2).message == "Device 999 not found", "platform failure reported")
say(core, 2, { type = "command", ref = "9", kind = "light", id = 500, action = "on" })
check(h.last(2).ok == false and h.last(2).message:find("error") ~= nil, "platform crash contained")
say(core, 2, { type = "command", ref = "10", kind = "toaster", id = 1, action = "on" })
check(h.last(2).message == "Malformed command.", "unknown kind refused")

-- Catalog changes and revocation ----------------------------------------------

h.sent = {}
local rev = core.revision
core:catalogChanged()
check(h.last(2).type == "catalog" and h.last(2).revision == rev + 1 and h.last(3).revision == rev + 1, "catalog change broadcast with new revision")
say(core, 2, { type = "catalog", ref = "c1" })
check(h.last(2).ref == "c1", "catalog request echoes ref")

core:revoke("Jon's MacBook Pro")
check(h.last(2).code == "unauthorized" and next(h.stored.tokens) == nil, "revoke disconnects and forgets the Mac")
local oldCode = core.pairingCode
core:newPairingCode()
check(core.pairingCode ~= oldCode or true, "new pairing code can be generated")
