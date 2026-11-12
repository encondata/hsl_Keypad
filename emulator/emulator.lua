-- A fake Control4 controller that runs the real HSL Keypad agent
-- (../HSLKeypad/driver.lua) on a Mac. Started by bridge.swift, which owns
-- the TCP port and timers; see the protocol at the top of bridge.swift.
--
-- Environment:
--   HSL_EMU_PRODUCTION  act like a production package (no developer tools)
--   HSL_EMU_PORT      agent Port property (default 8751)
--   HSL_EMU_CODEFILE  write the current pairing code here (for tests)
--   HSL_EMU_OS        reported OS version (default 3.4.3.0)
--
-- Console commands (type into the bridge): help, props, level <id> <0-100>,
-- fan <id> <speed>, scene <id> on|off, watch|listen <room> <device>,
-- roomoff <room>, rename <id> <name>, add <light|fan> <roomId> <name>,
-- remove <id>, action <ActionCommand>, set <Property> <value>

local here = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = here .. "../HSLKeypad/?.lua;" .. package.path
local json = require("json")

local out = io.stdout
local function emit(line) out:write(line, "\n"); out:flush() end

-- print() inside the agent goes to the bridge log, not the protocol stream.
print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  emit("LOG " .. table.concat(parts, " "))
end

-- Simulated project ------------------------------------------------------------

local rooms = { [12] = "Kitchen", [14] = "Living Room" }
local devicesById = {}
local function addDevice(id, kind, room, name, extra)
  local d = { id = id, kind = kind, roomId = room, name = name, vars = {} }
  if kind == "light" then
    d.vars[1000] = { name = "LIGHT_STATE", value = "0" }
    d.vars[1001] = { name = "Brightness Percent", value = "0" }
    d.dimmer = extra ~= false
  else
    d.vars[1100] = { name = "Is On", value = "0" }
    d.vars[1101] = { name = "Current Selected Speed", value = "0" }
  end
  devicesById[id] = d
  return d
end
addDevice(345, "light", 12, "Cans")
addDevice(346, "light", 12, "Pendants")
addDevice(350, "light", 14, "Lamps", false)
addDevice(402, "fan", 14, "Family Fan")
local nextDeviceId = 500

-- Agents, scenes, macros, rooms and media sources.
local AL_AGENT, MACRO_AGENT = 100, 101
local scenes = { [3] = { name = "Movie Time", active = false }, [4] = { name = "All Off", active = false } }
local macros = { [7] = "Goodnight", [8] = "Leave & Lock" }
local mediaNames = { [200] = "Apple TV", [201] = "Cable Box", [210] = "Spotify", [211] = "Sonos" }
rooms[16] = "Office"
local roomMedia = { [12] = { [1001] = "0", [1002] = "0" }, [14] = { [1001] = "0", [1002] = "0" }, [16] = { [1001] = "0", [1002] = "0" } }
local deviceEvents = {}

-- Properties from driver.xml defaults ----------------------------------------------

Properties = {}
local driverXml
do
  local f = assert(io.open(here .. "../HSLKeypad/driver.xml"))
  driverXml = f:read("*a")
  f:close()
  for block in driverXml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    if name then Properties[name] = block:match("<default>(.-)</default>") or "" end
  end
end
Properties["Port"] = os.getenv("HSL_EMU_PORT") or Properties["Port"]

-- Fake C4 API ----------------------------------------------------------------------

C4 = {}
C4SystemEvents = { OnItemAdded = 1, OnItemRemoved = 2, OnItemNameChanged = 3, OnItemMoved = 12 }

local persisted, listeners, systemEvents = {}, {}, {}
local timers, nextTimer = {}, 1
local serverPort
local buffers = {}  -- handle -> partial data (real C4 delivers whole delimited messages)

function C4:PersistGetValue(name) return persisted[name] end
function C4:PersistSetValue(name, value) persisted[name] = value end

function C4:UpdateProperty(name, value)
  Properties[name] = value
  if name == "Pairing Code" and os.getenv("HSL_EMU_CODEFILE") then
    local f = io.open(os.getenv("HSL_EMU_CODEFILE"), "w")
    if f then f:write(value); f:close() end
  end
  emit("LOG property " .. name .. " = " .. tostring(value))
end

function C4:SetTimer(ms, fn, repeating)
  local id = tostring(nextTimer)
  nextTimer = nextTimer + 1
  local timer = { id = id }
  function timer:Cancel()
    timers[id] = nil
    emit("CANCEL " .. id)
  end
  timers[id] = { fn = fn, ms = ms, repeating = repeating, obj = timer }
  emit("TIMER " .. id .. " " .. math.max(0, math.floor(ms)))
  return timer
end

function C4:CreateServer(port, delimiter)
  serverPort = tonumber(port)
  emit("LISTEN " .. serverPort)
  return true
end
function C4:DestroyServer() serverPort = nil end
function C4:ServerSend(handle, data) emit("SEND " .. handle .. " " .. json.encode(data)) end
function C4:ServerCloseClient(handle) emit("CLOSE " .. handle) end

function C4:GetDeviceID() return 9001 end

-- driver.xml root-level values, like the real GetDriverConfigInfo.
function C4:GetDriverConfigInfo(tag)
  return driverXml:match("<" .. tag .. ">(.-)</" .. tag .. ">")
end

-- C4:url() with a canned GitHub releases reply. HSL_EMU_LATEST sets the newest
-- published version (default 0.0.9); "offline" simulates a network error.
function C4:url()
  local transfer = {}
  function transfer:OnDone(fn) self.done = fn; return self end
  function transfer:SetOptions() return self end
  function transfer:Get(url, headers)
    local latest = os.getenv("HSL_EMU_LATEST") or "0.0.9"
    C4:SetTimer(50, function()
      if latest == "offline" then
        self.done(self, {}, 6, "Couldn't resolve host name")
        return
      end
      local base = "https://github.com/encondata/hsl_Keypad/releases"
      local body = json.encode(json.array({
        { tag_name = "v" .. latest, name = "HSL Keypad " .. latest, draft = false, prerelease = true,
          html_url = base .. "/tag/v" .. latest,
          assets = json.array({ { name = "HSLKeypad.c4z", browser_download_url = base .. "/download/v" .. latest .. "/HSLKeypad.c4z" } }) },
        { tag_name = "v0.0.1", draft = false, html_url = base .. "/tag/v0.0.1", assets = json.array({}) },
      }))
      self.done(self, { { code = 200, body = body, headers = {} } }, 0, nil)
    end, false)
    return self
  end
  return transfer
end
function C4:GetVersionInfo() return { version = os.getenv("HSL_EMU_OS") or "3.4.3.0" } end
function C4:GetControllerNetworkAddress() return "127.0.0.1" end
local function xmlEscape(s) return (s:gsub("&", "&amp;"):gsub("<", "&lt;")) end
function C4:GetProjectItems(filter)
  if filter == "LOCATIONS" then
    -- Kitchen answers SendUIRequest; Living Room only lists sources in its data.
    return "<item><id>1</id><name>Home</name><type>2</type><itemdata/><subitems>"
      .. "<item><id>12</id><name>Kitchen</name><type>8</type><itemdata/></item>"
      .. "<item><id>14</id><name>Living Room</name><type>8</type><itemdata><video_devices><id>201</id></video_devices><audio_devices><id>211</id></audio_devices></itemdata></item>"
      .. "<item><id>16</id><name>Office</name><type>8</type><itemdata/></item>"
      .. "</subitems></item>"
  end
  return "<item><id>100</id><name>Advanced Lighting</name><type>9</type><itemdata/></item>"
    .. "<item><id>101</id><name>Macros</name><type>9</type><itemdata/></item>"
end

function C4:GetDevicesByC4iName() return {} end  -- force the by-name fallback

function C4:GetDeviceDisplayName(id)
  id = tonumber(id)
  return mediaNames[id] or (devicesById[id] and devicesById[id].name) or ("Device " .. tostring(id))
end

function C4:SendUIRequest(id, request)
  id = tonumber(id)
  if id == AL_AGENT and request == "GET_SCENES" then
    local parts = {}
    for sid, s in pairs(scenes) do parts[#parts + 1] = "<scene><id>" .. sid .. "</id><name>" .. xmlEscape(s.name) .. "</name></scene>" end
    return "<scenes>" .. table.concat(parts) .. "</scenes>"
  end
  if id == MACRO_AGENT and request == "GET_ALL_MACROS" then  -- the 2nd name the agent tries
    local parts = {}
    for mid, name in pairs(macros) do parts[#parts + 1] = '<macro id="' .. mid .. '" name="' .. xmlEscape(name) .. '"/>' end
    return "<macros>" .. table.concat(parts) .. "</macros>"
  end
  if id == 12 and request == "GET_VIDEO_DEVICES" then return "<devices><device><id>200</id><name>Apple TV</name></device></devices>" end
  if id == 12 and request == "GET_AUDIO_DEVICES" then return '<devices><device id="210" name="Spotify"/></devices>' end
  return "<error>unknown request</error>"
end

function C4:RegisterDeviceEvent(id, eventId) deviceEvents[tonumber(id) .. ":" .. tonumber(eventId)] = true end
function C4:RegisterSystemEvent(eventId, deviceId) systemEvents[eventId] = true end

function C4:GetDevices(filter)
  local files = (filter and filter.C4iNames) or ""
  local result = {}
  for id, d in pairs(devicesById) do
    local file = d.kind == "light" and "light_v2.c4i" or "fan.c4i"
    if files:find(d.kind == "light" and "light_v2" or "fan", 1, true) then
      result[id] = { deviceName = d.name, driverFileName = file, roomId = d.roomId, roomName = rooms[d.roomId] }
    end
  end
  return result
end

function C4:GetDeviceVariables(id)
  local d = devicesById[id]
  if not d then return nil end
  local out = {}
  for varId, v in pairs(d.vars) do out[varId] = { name = v.name, value = v.value } end
  return out
end

function C4:GetDeviceVariable(id, varId)
  id, varId = tonumber(id), tonumber(varId)
  if roomMedia[id] then return roomMedia[id][varId] end
  local d = devicesById[id]
  return d and d.vars[varId] and d.vars[varId].value or nil
end

local function later(ms, fn) return C4:SetTimer(ms, function() fn() end, false) end

function C4:RegisterVariableListener(id, varId)
  listeners[id .. ":" .. varId] = true
  -- Docs: fires once right after registering with the current value.
  later(0, function()
    local value = C4:GetDeviceVariable(id, varId)
    if value ~= nil and OnWatchedVariableChanged then OnWatchedVariableChanged(id, varId, value) end
  end)
end
function C4:UnregisterVariableListener(id, varId) listeners[id .. ":" .. varId] = nil end

local function setVar(d, varId, value)
  value = tostring(value)
  if d.vars[varId].value == value then return end
  d.vars[varId].value = value
  if listeners[d.id .. ":" .. varId] and OnWatchedVariableChanged then
    OnWatchedVariableChanged(d.id, varId, value)
  end
end

local function setLevel(d, level)
  level = math.max(0, math.min(100, math.floor(level)))
  if not d.dimmer then level = level > 0 and 100 or 0 end
  setVar(d, 1001, level)
  setVar(d, 1000, level > 0 and "1" or "0")
end

local function setFan(d, speed)
  setVar(d, 1101, speed)
  setVar(d, 1100, speed > 0 and "1" or "0")
end

-- light_v2 button handling: click = on/off, hold = ramp until released.
local held = {}  -- deviceId -> { button, holdTimer, rampTimer }
local function setRoom(room, varId, value)
  value = tostring(value)
  if roomMedia[room][varId] == value then return end
  roomMedia[room][varId] = value
  if listeners[room .. ":" .. varId] and OnWatchedVariableChanged then OnWatchedVariableChanged(room, varId, value) end
end

local function setScene(sceneId, active)
  local scene = scenes[sceneId]
  if not scene then return end
  scene.active = active
  local event = sceneId * 5 + (active and 0 or 1)
  if deviceEvents[AL_AGENT .. ":" .. event] and OnDeviceEvent then OnDeviceEvent(AL_AGENT, event) end
end

function C4:SendToDevice(id, command, params)
  id = tonumber(id)
  params = params or {}
  if id == AL_AGENT then
    local sceneId = tonumber(params.SCENE_ID)
    local scene = scenes[sceneId]
    if not scene then return end
    if command == "ACTIVATE_SCENE" then setScene(sceneId, true)
    elseif command == "DEACTIVATE_SCENE" then setScene(sceneId, false)
    elseif command == "TOGGLE_SCENE" then setScene(sceneId, not scene.active)
    end
    return
  end
  if id == MACRO_AGENT then
    local macroId = tonumber(params.MACRO_ID or params.ID)
    if command == "EXECUTE_MACRO" and macros[macroId] then print("macro " .. macroId .. " (" .. macros[macroId] .. ") ran") end
    return
  end
  if roomMedia[id] then
    local device = tonumber(params.deviceid or params.DEVICEID) or 0
    if command == "SELECT_VIDEO_DEVICE" then setRoom(id, 1002, device); setRoom(id, 1001, device)
    elseif command == "SELECT_AUDIO_DEVICE" then setRoom(id, 1002, 0); setRoom(id, 1001, device)
    elseif command == "ROOM_OFF" then setRoom(id, 1002, 0); setRoom(id, 1001, 0)
    end
    return
  end
  local d = devicesById[id]
  if not d then return end
  if d.kind == "light" then
    local level = tonumber(d.vars[1001].value) or 0
    if command == "TOGGLE" then setLevel(d, level > 0 and 0 or 100)
    elseif command == "SET_BRIGHTNESS_TARGET" then setLevel(d, tonumber(params.LIGHT_BRIGHTNESS_TARGET or params.LEVEL) or level)
    elseif command == "SET_BRIGHTNESS_STOP" then
      if held[d.id] and held[d.id].rampTimer then held[d.id].rampTimer:Cancel() end
    elseif command == "BUTTON_ACTION" then
      local button, action = tonumber(params.BUTTON_ID), tonumber(params.ACTION)
      local h = held[d.id]
      if action == 1 then  -- press: start ramping after a short hold
        if h and h.rampTimer then h.rampTimer:Cancel() end
        h = { button = button }
        held[d.id] = h
        h.holdTimer = later(300, function()
          h.holdTimer = nil
          h.rampTimer = C4:SetTimer(100, function()
            local current = tonumber(d.vars[1001].value) or 0
            setLevel(d, current + (button == 0 and 5 or -5))
          end, true)
        end)
      elseif action == 2 then  -- release after click
        if h and h.holdTimer then h.holdTimer:Cancel() end
        if h and h.rampTimer then h.rampTimer:Cancel() end
        held[d.id] = nil
        setLevel(d, button == 0 and 100 or 0)
      elseif action == 0 then  -- release after hold
        if h and h.holdTimer then h.holdTimer:Cancel() end
        if h and h.rampTimer then h.rampTimer:Cancel() end
        held[d.id] = nil
      end
    end
  else
    local speed = tonumber(d.vars[1101].value) or 0
    if command == "ON" then setFan(d, speed > 0 and speed or 2)
    elseif command == "OFF" then setFan(d, 0)
    elseif command == "TOGGLE" then setFan(d, speed > 0 and 0 or 2)
    elseif command == "SET_SPEED" then setFan(d, tonumber(params.SPEED) or speed)
    end
  end
end

-- Load the real agent -----------------------------------------------------------

-- HSL_EMU_PRODUCTION=1 behaves like a production package (no devtools.lua).
if os.getenv("HSL_EMU_PRODUCTION") then
  package.preload["devtools"] = function() error("not in production packages") end
end
dofile(here .. "../HSLKeypad/driver.lua")
if OnDriverInit then OnDriverInit("DIT_ADDED") end
if OnDriverLateInit then OnDriverLateInit("DIT_ADDED") end

-- Console -------------------------------------------------------------------------

local function projectChanged(eventName)
  if OnSystemEvent and systemEvents[C4SystemEvents[eventName]] then OnSystemEvent(eventName) end
end

local function console(text)
  local cmd, rest = text:match("^(%S+)%s*(.*)$")
  if cmd == "help" then
    print("commands: props | level <id> <0-100> | fan <id> <speed> | scene <id> on|off | watch <room> <device> | listen <room> <device> | roomoff <room> | rename <id> <name> | add <light|fan> <roomId> <name> | remove <id> | action <Command> | set <Property> <value>")
  elseif cmd == "props" then
    local names = {}
    for k in pairs(Properties) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do print(k .. " = " .. tostring(Properties[k])) end
  elseif cmd == "level" then
    local id, v = rest:match("^(%d+)%s+(%d+)$")
    local d = devicesById[tonumber(id)]
    if d and d.kind == "light" then setLevel(d, tonumber(v)) end
  elseif cmd == "fan" then
    local id, v = rest:match("^(%d+)%s+(%d+)$")
    local d = devicesById[tonumber(id)]
    if d and d.kind == "fan" then setFan(d, tonumber(v)) end
  elseif cmd == "rename" then
    local id, name = rest:match("^(%d+)%s+(.+)$")
    local d = devicesById[tonumber(id)]
    if d then d.name = name; projectChanged("OnItemNameChanged") end
  elseif cmd == "add" then
    local kind, room, name = rest:match("^(%a+)%s+(%d+)%s+(.+)$")
    if kind == "light" or kind == "fan" then
      addDevice(nextDeviceId, kind, tonumber(room), name)
      print("added " .. kind .. " " .. nextDeviceId)
      nextDeviceId = nextDeviceId + 1
      projectChanged("OnItemAdded")
    end
  elseif cmd == "remove" then
    local id = tonumber(rest)
    if devicesById[id] then devicesById[id] = nil; projectChanged("OnItemRemoved") end
  elseif cmd == "scene" then  -- scene <id> on|off   (e.g. from a wall keypad)
    local id, state = rest:match("^(%d+)%s+(%a+)$")
    setScene(tonumber(id), state == "on")
  elseif cmd == "watch" or cmd == "listen" then  -- watch <room> <device>
    local room, device = rest:match("^(%d+)%s+(%d+)$")
    room, device = tonumber(room), tonumber(device)
    if roomMedia[room] then
      C4:SendToDevice(room, cmd == "watch" and "SELECT_VIDEO_DEVICE" or "SELECT_AUDIO_DEVICE", { deviceid = device })
    end
  elseif cmd == "roomoff" then
    local room = tonumber(rest)
    if roomMedia[room] then C4:SendToDevice(room, "ROOM_OFF") end
  elseif cmd == "action" then
    if ExecuteCommand then ExecuteCommand("LUA_ACTION", { ACTION = rest }) end
  elseif cmd == "set" then
    local name, value = rest:match("^(.-)%s*=%s*(.*)$")
    if not name then name, value = rest:match("^(%S+)%s+(.*)$") end
    if name then
      Properties[name] = value
      if OnPropertyChanged then OnPropertyChanged(name) end
    end
  else
    print("unknown command: " .. text .. " (try help)")
  end
end

-- Event loop: one line per event from the bridge ----------------------------------

for line in io.stdin:lines() do
  local kind, rest = line:match("^(%S+)%s*(.*)$")
  local ok, err = pcall(function()
    if kind == "CONNECT" then
      local handle, address = rest:match("^(%d+)%s*(.*)$")
      handle = tonumber(handle)
      buffers[handle] = ""
      OnServerConnectionStatusChanged(handle, serverPort, "ONLINE", address)
    elseif kind == "DATA" then
      local handle, payload = rest:match("^(%d+)%s+(.*)$")
      handle = tonumber(handle)
      buffers[handle] = (buffers[handle] or "") .. json.decode(payload)
      while true do
        local nl = buffers[handle]:find("\n", 1, true)
        if not nl then break end
        local message = buffers[handle]:sub(1, nl)  -- delimiter included, like C4
        buffers[handle] = buffers[handle]:sub(nl + 1)
        OnServerDataIn(handle, message, "127.0.0.1", serverPort)
      end
    elseif kind == "DISCONNECT" then
      local handle = tonumber(rest)
      buffers[handle] = nil
      OnServerConnectionStatusChanged(handle, serverPort, "OFFLINE")
    elseif kind == "FIRE" then
      local t = timers[rest]
      if t then
        if t.repeating then emit("TIMER " .. rest .. " " .. math.max(1, math.floor(t.ms))) else timers[rest] = nil end
        t.fn(t.obj)
      end
    elseif kind == "CONSOLE" then
      console(rest)
    end
  end)
  if not ok then emit("LOG emulator error: " .. tostring(err)) end
end
