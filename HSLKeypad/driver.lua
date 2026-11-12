-- HSL Keypad agent for Control4 (OS 3.4.x and X4).
--
-- The Control4 layer around core.lua (protocol) and json.lua: it listens for
-- the HSL Toolbar Mac app, discovers lights and fans, sends their commands,
-- and forwards their state changes. See Control4/PROTOCOL.md.
--
-- Only documented DriverWorks calls are used (see the API notes at the end).
-- Rules for OS 3.4 + X4: no LuaSocket, no io.popen; every C4 call that might
-- differ between versions goes through `call()` so a missing API logs instead
-- of crashing the agent.

local json = require("json")
local Core = require("core")

local LIGHT_FILES = "light_v2.c4i,light_v2.c4z"
local FAN_FILES = "fan.c4i,fan.c4z"            -- (SDK gap) confirm on a real project
local LIGHT_STATE_VAR, LIGHT_LEVEL_VAR = 1000, 1001  -- light_v2: Light State, Brightness Percent
local REFRESH_DELAY_MS = 2000                  -- coalesce bursts of project-change events

Agent = Agent or {
  core = nil,
  catalog = nil,
  lights = {},        -- deviceId -> { name, room, dimmable, on, level }
  fans = {},          -- deviceId -> { name, room, speeds, on, speed, vars = { [varId] = "on"|"speed" } }
  port = nil,
  refreshTimer = nil,
  rampButton = {},    -- deviceId -> BUTTON_ID being held
  connected = 0,
}

-- Helpers ------------------------------------------------------------------------

local function log(message)
  if Properties and Properties["Debug Mode"] == "On" then print("HSL Keypad: " .. tostring(message)) end
end

--- Calls C4:<name>(...) if it exists; returns ok, results...
local function call(name, ...)
  local fn = C4 and C4[name]
  if type(fn) ~= "function" then
    log("C4:" .. name .. " is not available on this OS")
    return false
  end
  local result = { pcall(fn, C4, ...) }
  if not result[1] then log("C4:" .. name .. " failed: " .. tostring(result[2])) end
  return unpack(result)
end

local function update(property, value)
  call("UpdateProperty", property, tostring(value))
end

local function truthy(value)
  local v = tostring(value or ""):lower()
  return v == "1" or v == "true" or v == "on"
end

local function seedRandom()
  -- Several sources: time, CPU clock, memory use, table address, device ID.
  local _, id = call("GetDeviceID")
  local addr = tonumber(tostring({}):match("0x(%x+)") or "0", 16) or 0
  math.randomseed((os.time() * 1000 + math.floor(os.clock() * 1e6) + addr + (tonumber(id) or 0)
    + math.floor(collectgarbage("count") * 1000)) % 2147483647)
  for _ = 1, 10 do math.random() end
end

-- Discovery ---------------------------------------------------------------------

local function devices(files)
  local ok, list = call("GetDevices", { C4iNames = files })
  if ok and type(list) == "table" then return list end
  return {}
end

local function fanVariables(deviceId)
  -- Fan variables are documented by name only; find their IDs at runtime.
  local vars = {}
  local ok, list = call("GetDeviceVariables", deviceId)
  if not ok or type(list) ~= "table" then return vars end
  for key, v in pairs(list) do
    local name = type(v) == "table" and (v.name or v.Name) or nil
    local id = tonumber(type(v) == "table" and (v.id or v.ID) or nil) or tonumber(key)
    if name and id then
      if name == "Is On" then vars[id] = "on" end
      if name == "Current Selected Speed" then vars[id] = "speed" end
    end
  end
  return vars
end

local function listen(deviceId, varId)
  call("RegisterVariableListener", deviceId, varId)
end

--- Rebuilds the catalog; returns true if it changed.
function Agent.refresh()
  local rooms, roomList, lights, fans = {}, {}, {}, {}
  local newLights, newFans = {}, {}

  local function addRoom(id, name)
    if id and not rooms[id] then
      rooms[id] = true
      roomList[#roomList + 1] = { id = tonumber(id), name = name or ("Room " .. id) }
    end
  end

  for id, d in pairs(devices(LIGHT_FILES)) do
    id = tonumber(id)
    if id then
      local old = Agent.lights[id] or {}
      newLights[id] = { name = d.deviceName, room = tonumber(d.roomId), dimmable = true, on = old.on, level = old.level }
      lights[#lights + 1] = { id = id, room = tonumber(d.roomId), name = d.deviceName or ("Light " .. id), dimmable = true }
      addRoom(d.roomId, d.roomName)
    end
  end

  for id, d in pairs(devices(FAN_FILES)) do
    id = tonumber(id)
    if id then
      local old = Agent.fans[id] or {}
      newFans[id] = { name = d.deviceName, room = tonumber(d.roomId), speeds = 3, on = old.on, speed = old.speed,
                      vars = fanVariables(id) }
      fans[#fans + 1] = { id = id, room = tonumber(d.roomId), name = d.deviceName or ("Fan " .. id), speeds = 3 }
      addRoom(d.roomId, d.roomName)
    end
  end

  local byName = function(a, b) return (a.name or "") < (b.name or "") end
  table.sort(lights, byName)
  table.sort(fans, byName)
  table.sort(roomList, byName)

  -- Start listening to anything new (OnWatchedVariableChanged fires right
  -- away with the current value, which fills in the state).
  for id in pairs(newLights) do
    if not Agent.lights[id] then
      listen(id, LIGHT_STATE_VAR)
      listen(id, LIGHT_LEVEL_VAR)
    end
  end
  for id, fan in pairs(newFans) do
    if not Agent.fans[id] then
      for varId in pairs(fan.vars) do listen(id, varId) end
    end
  end
  for id in pairs(Agent.lights) do
    if not newLights[id] then
      call("UnregisterVariableListener", id, LIGHT_STATE_VAR)
      call("UnregisterVariableListener", id, LIGHT_LEVEL_VAR)
    end
  end
  Agent.lights, Agent.fans = newLights, newFans

  local catalog = {
    rooms = roomList, lights = lights, fans = fans,
    -- (SDK gap) Advanced Lighting scenes and macros: the docs don't say how
    -- an agent lists them yet. Use the "Log Project Info" action on a real
    -- controller to find out, then add them here.
    scenes = {}, macros = {},
  }
  local changed = Agent.catalog == nil or json.encode(catalog) ~= json.encode(Agent.catalog)
  Agent.catalog = catalog
  return changed
end

local function scheduleRefresh()
  if Agent.refreshTimer then Agent.refreshTimer:Cancel() end
  local ok, timer = call("SetTimer", REFRESH_DELAY_MS, function()
    Agent.refreshTimer = nil
    if Agent.refresh() and Agent.core then Agent.core:catalogChanged() end
    Agent.updateStatus()
  end, false)
  Agent.refreshTimer = ok and timer or nil
end

-- State -------------------------------------------------------------------------

local function lightState(id)
  local light = Agent.lights[id]
  if not light then return nil end
  if light.on == nil then
    local ok, v = call("GetDeviceVariable", id, LIGHT_STATE_VAR)
    if ok and v ~= nil then light.on = truthy(v) end
  end
  if light.level == nil then
    local ok, v = call("GetDeviceVariable", id, LIGHT_LEVEL_VAR)
    if ok and v ~= nil then light.level = tonumber(v) end
  end
  return { on = light.on == true or (light.level or 0) > 0, level = light.level or 0 }
end

local function fanState(id)
  local fan = Agent.fans[id]
  if not fan then return nil end
  return { on = fan.on == true or (fan.speed or 0) > 0, speed = fan.speed or 0 }
end

function OnWatchedVariableChanged(idDevice, idVariable, strValue)
  idDevice, idVariable = tonumber(idDevice), tonumber(idVariable)
  local light = Agent.lights[idDevice]
  if light then
    if idVariable == LIGHT_STATE_VAR then light.on = truthy(strValue) end
    if idVariable == LIGHT_LEVEL_VAR then light.level = tonumber(strValue) or light.level end
    if Agent.core then Agent.core:stateChanged("light", idDevice, lightState(idDevice)) end
    return
  end
  local fan = Agent.fans[idDevice]
  if fan then
    local field = fan.vars[idVariable]
    if field == "on" then fan.on = truthy(strValue) end
    if field == "speed" then fan.speed = tonumber(strValue) or fan.speed end
    if Agent.core then Agent.core:stateChanged("fan", idDevice, fanState(idDevice)) end
  end
end

-- Commands ----------------------------------------------------------------------

local function send(id, command, params)
  local ok = call("SendToDevice", id, command, params or {})
  return ok
end

--- light_v2 keypad-style button: 0 = top (on/up), 1 = bottom (off/down).
--- ACTION 1 = press, 2 = release after a click, 0 = release after a hold.
local function button(id, which, action)
  return send(id, "BUTTON_ACTION", { BUTTON_ID = which, ACTION = action })
end

local function lightCommand(id, action, msg)
  if not Agent.lights[id] then return false, "Light " .. id .. " isn't in this project." end
  if action == "toggle" then return send(id, "TOGGLE")
  elseif action == "on" then return button(id, 0, 1) and button(id, 0, 2)
  elseif action == "off" then return button(id, 1, 1) and button(id, 1, 2)
  elseif action == "level" then
    local level = math.max(0, math.min(100, tonumber(msg.value) or 0))
    return send(id, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = level, RATE = 0, LEVEL = level, TIME = 0 })
  elseif action == "rampStart" then
    local which = msg.direction == "down" and 1 or 0
    Agent.rampButton[id] = which
    return button(id, which, 1)
  elseif action == "rampStop" then
    local which = Agent.rampButton[id] or 0
    Agent.rampButton[id] = nil
    return button(id, which, 0)
  end
  return false, "Lights can't do “" .. tostring(action) .. "”."
end

local function fanCommand(id, action, msg)
  if not Agent.fans[id] then return false, "Fan " .. id .. " isn't in this project." end
  if action == "on" then return send(id, "ON")
  elseif action == "off" then return send(id, "OFF")
  elseif action == "toggle" then return send(id, "TOGGLE")
  elseif action == "speed" then return send(id, "SET_SPEED", { SPEED = math.max(0, tonumber(msg.value) or 0) })
  end
  return false, "Fans can't do “" .. tostring(action) .. "”."
end

-- Platform for core.lua -----------------------------------------------------------

local platform = {}

function platform.info()
  local _, version = call("GetVersionInfo")
  local _, address = call("GetControllerNetworkAddress")
  local name = Properties["Site Name"]
  return {
    project = (name and name ~= "") and name or "Control4",
    os = type(version) == "table" and version.version or nil,
    address = address,
    netmask = nil,  -- (SDK gap) not exposed; the app falls back to the Mac's netmask
  }
end

function platform.catalog()
  if not Agent.catalog then Agent.refresh() end
  return Agent.catalog
end

function platform.state(kind, id)
  if kind == "light" then return lightState(id) end
  if kind == "fan" then return fanState(id) end
  return nil
end

function platform.command(kind, id, action, msg)
  if kind == "light" then
    local ok, message = lightCommand(id, action, msg)
    return ok and true or false, message or (ok and nil or "Control4 didn't accept that command.")
  end
  if kind == "fan" then
    local ok, message = fanCommand(id, action, msg)
    return ok and true or false, message or (ok and nil or "Control4 didn't accept that command.")
  end
  return false, "This agent version doesn't support " .. tostring(kind) .. "s yet."
end

-- Status properties ---------------------------------------------------------------

function Agent.updateStatus()
  local core = Agent.core
  if not core then return end
  update("Pairing Code", core.pairingCode)
  local names = {}
  for _, info in ipairs(core:pairedDevices()) do names[#names + 1] = info.device end
  update("Paired Macs", #names > 0 and table.concat(names, ", ") or "None")
  local count = 0
  for _, client in pairs(core.clients) do if client.authed then count = count + 1 end end
  local catalog = Agent.catalog or { lights = {}, fans = {} }
  update("Status", string.format("%s on port %s · %d Mac%s connected · %d lights, %d fans",
    Agent.port and "Listening" or "Not listening", tostring(Agent.port or Properties["Port"]),
    count, count == 1 and "" or "s", #catalog.lights, #catalog.fans))
end

-- Server --------------------------------------------------------------------------

local function startServer()
  local port = tonumber(Properties["Port"]) or 8751
  if Agent.port then call("DestroyServer", Agent.port) end
  Agent.port = nil
  local ok, created, err = call("CreateServer", port, "\n")
  if ok and created ~= false then
    Agent.port = port
  else
    update("Status", "Couldn't listen on port " .. port .. (err and (": " .. tostring(err)) or ""))
  end
  Agent.updateStatus()
end

function OnServerStatusChanged(nPort, strStatus)
  log("server " .. tostring(nPort) .. " " .. tostring(strStatus))
end

function OnServerConnectionStatusChanged(nHandle, nPort, strStatus, strAddress)
  if not Agent.core then return end
  if tostring(strStatus):upper() == "ONLINE" then
    Agent.core:connected(nHandle)
    log("Mac connected from " .. tostring(strAddress))
  else
    Agent.core:disconnected(nHandle)
  end
  Agent.updateStatus()
end

function OnServerDataIn(nHandle, strData)
  if not Agent.core then return end
  local wasAuthed = Agent.core.clients[nHandle] and Agent.core.clients[nHandle].authed
  Agent.core:data(nHandle, strData)
  local client = Agent.core.clients[nHandle]
  if (client and client.authed) ~= wasAuthed then Agent.updateStatus() end
end

-- Lifecycle -----------------------------------------------------------------------

function OnDriverLateInit()
  seedRandom()
  Agent.core = Core.new({
    platform = platform,
    store = {
      get = function(key) local ok, v = call("PersistGetValue", "hsl." .. key); return ok and v or nil end,
      set = function(key, value) call("PersistSetValue", "hsl." .. key, value) end,
    },
    send = function(handle, line) call("ServerSend", handle, line) end,
    close = function(handle) call("ServerCloseClient", handle) end,
    later = function(seconds, fn) call("SetTimer", math.floor(seconds * 1000), function() fn() end, false) end,
    now = os.time,
    random = math.random,
    log = log,
    pairingChanged = function() Agent.updateStatus() end,
  })
  Agent.refresh()

  -- Project changes (devices added, removed, renamed, moved) → refresh.
  if type(C4SystemEvents) == "table" then
    for _, name in ipairs({ "OnItemAdded", "OnItemRemoved", "OnItemNameChanged", "OnItemMoved" }) do
      if C4SystemEvents[name] then call("RegisterSystemEvent", C4SystemEvents[name], 0) end
    end
  end

  startServer()
end

function OnSystemEvent(data)
  log("project changed: " .. tostring(data))
  scheduleRefresh()
end

function OnPropertyChanged(strName)
  if strName == "Port" then startServer()
  elseif strName == "Site Name" then Agent.updateStatus()
  end
end

function ExecuteCommand(strCommand, tParams)
  if strCommand ~= "LUA_ACTION" or not Agent.core then return end
  local action = tParams and tParams.ACTION
  if action == "NewPairingCode" then
    Agent.core:newPairingCode()
  elseif action == "UnpairAll" then
    Agent.core:revoke(nil)
  elseif action == "RefreshDevices" then
    if Agent.refresh() then Agent.core:catalogChanged() end
  elseif action == "LogProjectInfo" then
    Agent.logProjectInfo()
  end
  Agent.updateStatus()
end

function OnDriverDestroyed()
  call("DestroyServer")
end

--- Prints what this controller exposes, to fill the documented gaps (scenes,
--- macros, fan variables, light capabilities). Copy the Lua output window.
function Agent.logProjectInfo()
  print("==== HSL Keypad: project info ====")
  local _, version = call("GetVersionInfo")
  print("OS: " .. tostring(type(version) == "table" and version.version or version))
  print("Controller: " .. tostring(select(2, call("GetControllerNetworkAddress"))))
  for label, files in pairs({ lights = LIGHT_FILES, fans = FAN_FILES }) do
    for id, d in pairs(devices(files)) do
      print(string.format("%s %s: %s | room %s %s | %s", label, tostring(id), tostring(d.deviceName),
        tostring(d.roomId), tostring(d.roomName), tostring(d.driverFileName)))
      local ok, vars = call("GetDeviceVariables", id)
      if ok and type(vars) == "table" then
        for k, v in pairs(vars) do
          print("  var " .. tostring(k) .. " = " .. (type(v) == "table" and json.encode(v) or tostring(v)))
        end
      end
    end
  end
  local ok, agents = call("GetProjectItems", "AGENTS", "NO_ROOT_TAGS")
  if ok and agents then
    local text = tostring(agents)
    for i = 1, #text, 3000 do print("agents: " .. text:sub(i, i + 2999)) end
  end
  if type(C4SystemEvents) == "table" then
    local names = {}
    for name in pairs(C4SystemEvents) do names[#names + 1] = name end
    table.sort(names)
    print("system events: " .. table.concat(names, ", "))
  end
  print("==== end ====")
end

--[[ API notes (snap-one.github.io/docs-driverworks-api unless noted)
  CreateServer/OnServerConnectionStatusChanged/OnServerDataIn/ServerSend/
    ServerCloseClient/DestroyServer — Server Socket Interface (2.10+)
  PersistSetValue/PersistGetValue — Persistence Interface (2.10+)
  SetTimer(ms, fn, repeat) → timer:Cancel() — Timer Interface (2.7+)
  GetDevices({C4iNames=...}) → [id]={deviceName, roomId, roomName, ...} (2.10+)
  RegisterVariableListener / OnWatchedVariableChanged — Variable Interface
  light_v2 variables 1000 (state) / 1001 (brightness %), commands TOGGLE,
    SET_BRIGHTNESS_TARGET, BUTTON_ACTION — light_v2 proxy protocol docs
  fan commands ON/OFF/TOGGLE/SET_SPEED — fan proxy protocol docs
  RegisterSystemEvent / OnSystemEvent — Event Interface
  <agent>true</agent> — DriverWorks fundamentals, "DriverWorks Agents" (3.1.3+)
]]
