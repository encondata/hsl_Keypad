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
local Project = require("project")
local Updates = require("updates")
-- Developer builds only: devtools.lua isn't in production packages.
local hasDev, Dev = pcall(require, "devtools")
if not hasDev then Dev = nil end

local UPDATE_FIRST_CHECK_MS = 60 * 1000          -- a minute after startup
local UPDATE_INTERVAL_MS = 24 * 60 * 60 * 1000   -- then daily

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
  alAgent = nil,      -- Advanced Lighting agent device ID
  macroAgent = nil,   -- Macros agent device ID
  scenes = {},        -- sceneId -> { name, active }
  macros = {},        -- macroId -> { name }
  sources = {},       -- catalog id -> { kind = "watch"|"listen", room, device, name }
  roomMedia = {},     -- roomId -> { audio = deviceId, video = deviceId }
  sceneEvents = {},   -- registered scene event IDs
  probes = {},        -- what discovery tried, for Log Project Info
  update = nil,       -- { version, url } when GitHub has a newer release
  updateTimers = {},  -- first-check and daily timers
}

-- Helpers ------------------------------------------------------------------------

local function log(message)
  if Dev then Dev.record(message) end
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

  -- Scenes, macros and Watch/Listen rely on undocumented replies; if their
  -- discovery fails, log it and keep lights and fans working.
  local okExtras, scenes, macros, watch, listen = pcall(Agent.discoverExtras, rooms, roomList)
  if not okExtras then
    print("HSL Keypad: scene/macro/source discovery failed: " .. tostring(scenes))
    scenes, macros, watch, listen = {}, {}, {}, {}
  end

  local catalog = {
    rooms = roomList, lights = lights, fans = fans,
    scenes = scenes, macros = macros, watch = watch, listen = listen,
  }
  local changed = Agent.catalog == nil or json.encode(catalog) ~= json.encode(Agent.catalog)
  Agent.catalog = catalog
  return changed
end

--- Scenes, macros, and Watch/Listen sources. Adds any rooms it finds to
--- `rooms`/`roomList`; registers for scene events and room media variables.
function Agent.discoverExtras(rooms, roomList)
  local probes = {}
  local okA, agentsXml = call("GetProjectItems", "AGENTS", "NO_ROOT_TAGS")
  local agentItems = Project.items(okA and agentsXml or nil)
  local okL, locationsXml = call("GetProjectItems", "LOCATIONS", "NO_ROOT_TAGS")
  local roomItems = {}
  for _, item in ipairs(Project.items(okL and locationsXml or nil)) do
    if item.type == Project.ROOM_TYPE then
      roomItems[#roomItems + 1] = item
      if not rooms[item.id] then
        rooms[item.id] = true
        roomList[#roomList + 1] = { id = item.id, name = item.name }
      end
    end
  end
  table.sort(roomList, function(a, b) return (a.name or "") < (b.name or "") end)

  -- Advanced Lighting scenes
  Agent.alAgent = Project.findAgent(call, Project.AL_FILES, "advanced lighting", agentItems)
  local foundScenes, sceneLog, sceneRequest = Project.probe(call, Agent.alAgent, Project.SCENE_REQUESTS, { "scene_info", "scene", "item" })
  if #foundScenes == 0 and Agent.alAgent then
    foundScenes = Project.fromItemData(agentItems, Agent.alAgent, { "scene_info", "scene" })
    if #foundScenes > 0 then sceneRequest = "project item data" end
  end
  probes.scenes = { agent = Agent.alAgent, request = sceneRequest, log = sceneLog }
  local scenes, newScenes = {}, {}
  for _, s in ipairs(foundScenes) do
    local old = Agent.scenes[s.id] or {}
    local active = old.active
    if active == nil then active = s.active end
    newScenes[s.id] = { name = s.name, active = active }
    scenes[#scenes + 1] = { id = s.id, name = s.name }
    for _, event in ipairs({ s.id * 5, s.id * 5 + 1 }) do
      if not Agent.sceneEvents[event] then
        call("RegisterDeviceEvent", Agent.alAgent, event)
        Agent.sceneEvents[event] = true
      end
    end
  end
  Agent.scenes = newScenes

  -- Macros
  Agent.macroAgent = Project.findAgent(call, Project.MACRO_FILES, "macro", agentItems)
  local foundMacros, macroLog, macroRequest = Project.probe(call, Agent.macroAgent, Project.MACRO_REQUESTS, { "macro", "item" })
  if #foundMacros == 0 and Agent.macroAgent then
    foundMacros = Project.fromItemData(agentItems, Agent.macroAgent, { "macro" })
    if #foundMacros > 0 then macroRequest = "project item data" end
  end
  probes.macros = { agent = Agent.macroAgent, request = macroRequest, log = macroLog }
  local macros, newMacros = {}, {}
  for _, m in ipairs(foundMacros) do
    newMacros[m.id] = { name = m.name }
    macros[#macros + 1] = { id = m.id, name = m.name }
  end
  Agent.macros = newMacros

  -- Watch / Listen sources per room: the visible entries of each room's
  -- OrderedWatchList / OrderedListenList (what Navigator shows).
  local watch, listen, newSources = {}, {}, {}
  probes.rooms = {}
  local perRoom, allIds, seenIds = {}, {}, {}
  for _, room in ipairs(roomItems) do
    local entry = { room = room,
                    watch = Project.orderedSources(room.data, Project.WATCH_LIST),
                    listen = Project.orderedSources(room.data, Project.LISTEN_LIST) }
    perRoom[#perRoom + 1] = entry
    for _, kind in ipairs({ "watch", "listen" }) do
      for _, id in ipairs(entry[kind]) do
        if not seenIds[id] then seenIds[id] = true; allIds[#allIds + 1] = id end
      end
    end
  end
  -- One lookup for every source's name (GetDeviceDisplayName isn't on every OS).
  local names = {}
  if #allIds > 0 then
    local ok, devices = call("GetDevices", { DeviceIds = table.concat(allIds, ",") })
    if ok and type(devices) == "table" then
      for id, d in pairs(devices) do names[tonumber(id)] = type(d) == "table" and d.deviceName or nil end
    end
  end
  local function deviceName(id)
    if names[id] then return names[id] end
    local ok, name = call("GetDeviceDisplayName", id)
    return ok and type(name) == "string" and name ~= "" and name or ("Device " .. id)
  end
  for _, entry in ipairs(perRoom) do
    local room = entry.room
    for _, kind in ipairs({ "watch", "listen" }) do
      local list = kind == "watch" and watch or listen
      for _, deviceId in ipairs(entry[kind]) do
        local id = Project.sourceId(room.id, deviceId)
        if not newSources[id] then
          local name = deviceName(deviceId)
          newSources[id] = { kind = kind, room = room.id, device = deviceId, name = name }
          list[#list + 1] = { id = id, room = room.id, device = deviceId, name = name }
        end
      end
    end
    probes.rooms[#probes.rooms + 1] = { id = room.id, name = room.name, watch = #entry.watch, listen = #entry.listen }
  end
  -- Listen to each room that has sources (current audio/video device).
  for id, source in pairs(newSources) do
    if not Agent.roomMedia[source.room] then
      Agent.roomMedia[source.room] = {}
      call("RegisterVariableListener", source.room, Project.ROOM_AUDIO_VAR)
      call("RegisterVariableListener", source.room, Project.ROOM_VIDEO_VAR)
    end
  end
  Agent.sources = newSources
  Agent.probes = probes

  local byName = function(a, b) return (a.name or "") < (b.name or "") end
  table.sort(scenes, byName)
  table.sort(macros, byName)
  table.sort(watch, byName)
  table.sort(listen, byName)
  return scenes, macros, watch, listen
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

local function sceneState(id)
  local scene = Agent.scenes[id]
  return scene and { active = scene.active == true } or nil
end

local function sourceState(id)
  local source = Agent.sources[id]
  if not source then return nil end
  local media = Agent.roomMedia[source.room] or {}
  local current = source.kind == "watch" and media.video or media.audio
  return { active = current == source.device }
end

--- A room's current audio/video device changed: update its Watch/Listen buttons.
local function roomMediaChanged(roomId)
  if not Agent.core then return end
  for id, source in pairs(Agent.sources) do
    if source.room == roomId then Agent.core:stateChanged(source.kind, id, sourceState(id)) end
  end
end

--- Advanced Lighting scene events: Activated = id*5, Deactivated = id*5+1.
function OnDeviceEvent(firingDeviceId, eventId)
  firingDeviceId, eventId = tonumber(firingDeviceId), tonumber(eventId)
  if firingDeviceId ~= Agent.alAgent or not eventId then return end
  local sceneId, which = math.floor(eventId / 5), eventId % 5
  local scene = Agent.scenes[sceneId]
  if not scene or (which ~= 0 and which ~= 1) then return end
  scene.active = which == 0
  if Agent.core then Agent.core:stateChanged("scene", sceneId, sceneState(sceneId)) end
end

function OnWatchedVariableChanged(idDevice, idVariable, strValue)
  idDevice, idVariable = tonumber(idDevice), tonumber(idVariable)
  local media = Agent.roomMedia[idDevice]
  if media and (idVariable == Project.ROOM_AUDIO_VAR or idVariable == Project.ROOM_VIDEO_VAR) then
    local device = tonumber(strValue)
    if device == 0 then device = nil end
    if idVariable == Project.ROOM_AUDIO_VAR then media.audio = device else media.video = device end
    roomMediaChanged(idDevice)
    return
  end
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

local function sceneCommand(id, action)
  if not Agent.alAgent then return false, "No Advanced Lighting agent found in this project." end
  if not Agent.scenes[id] then return false, "Scene " .. id .. " isn't in this project." end
  local command = ({ activate = "ACTIVATE_SCENE", toggle = "TOGGLE_SCENE", off = "DEACTIVATE_SCENE" })[action]
  if not command then return false, "Scenes can't do “" .. tostring(action) .. "”." end
  return send(Agent.alAgent, command, { SCENE_ID = id })
end

local function macroCommand(id, action)
  if not Agent.macroAgent then return false, "No Macros agent found in this project." end
  if not Agent.macros[id] then return false, "Macro " .. id .. " isn't in this project." end
  if action ~= "run" then return false, "Macros can only run." end
  -- Confirmed on X4 (0.0.5): the same command Composer's "Execute Macro"
  -- programming sends — EXECUTE_MACRO with a lowercase `id` (INTEGER).
  log("running macro " .. id)
  return send(Agent.macroAgent, "EXECUTE_MACRO", { id = id })
end

local function sourceCommand(kind, id, action)
  local source = Agent.sources[id]
  if not source or source.kind ~= kind then return false, "That source isn't in this project." end
  local select = kind == "watch" and "SELECT_VIDEO_DEVICE" or "SELECT_AUDIO_DEVICE"
  if action == "select" or action == "on" then
    return send(source.room, select, { deviceid = source.device })
  elseif action == "roomOff" or action == "off" then
    return send(source.room, "ROOM_OFF")
  elseif action == "toggle" then
    if sourceState(id).active then return send(source.room, "ROOM_OFF") end
    return send(source.room, select, { deviceid = source.device })
  end
  return false, "Sources can't do “" .. tostring(action) .. "”."
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
    update = Agent.update,
  }
end

-- Version and updates ---------------------------------------------------------------

--- "0.0.3 (build 3)": the release version plus driver.xml's <version>, which
--- is what Composer compares when installing over an older package.
function Agent.versionText()
  local ok, build = call("GetDriverConfigInfo", "version")
  build = ok and tostring(build or ""):match("%d+") or nil
  return Core.VERSION .. (build and (" (build " .. build .. ")") or "") .. (Dev and " · developer build" or "")
end

--- Asks GitHub for a newer release; updates "Update Status" and tells Macs.
function Agent.checkForUpdates()
  update("Update Status", "Checking…")
  Updates.check(Core.VERSION, function(result, err)
    if not result then
      update("Update Status", "Couldn't check: " .. tostring(err))
      return
    end
    if result.available then
      Agent.update = { version = result.latest.version, url = result.latest.url }
      update("Update Status", result.latest.version .. " available — install it in Composer from " .. Updates.PAGE)
      if Agent.core then
        Agent.core:broadcast({ type = "update", version = Agent.update.version, url = Agent.update.url })
      end
    else
      Agent.update = nil
      update("Update Status", "Up to date (" .. Core.VERSION .. ")")
    end
  end)
end

--- A first check a minute after startup, then daily — unless turned off.
function Agent.scheduleUpdateChecks()
  for _, timer in pairs(Agent.updateTimers) do pcall(function() timer:Cancel() end) end
  Agent.updateTimers = {}
  if Properties["Automatic Update Check"] == "Off" then
    if not Agent.update then update("Update Status", "Automatic checks off") end
    return
  end
  local ok1, first = call("SetTimer", UPDATE_FIRST_CHECK_MS, function() Agent.checkForUpdates() end, false)
  local ok2, daily = call("SetTimer", UPDATE_INTERVAL_MS, function() Agent.checkForUpdates() end, true)
  if ok1 and first then Agent.updateTimers.first = first end
  if ok2 and daily then Agent.updateTimers.daily = daily end
end

function platform.catalog()
  if not Agent.catalog then Agent.refresh() end
  return Agent.catalog
end

function platform.state(kind, id)
  if kind == "light" then return lightState(id) end
  if kind == "fan" then return fanState(id) end
  if kind == "scene" then return sceneState(id) end
  if kind == "watch" or kind == "listen" then return sourceState(id) end
  return nil
end

function platform.command(kind, id, action, msg)
  if kind == "light" then
    local ok, message = lightCommand(id, action, msg)
    return ok and true or false, message or (ok and nil or "Control4 didn't accept that command.")
  end
  local ok, message
  if kind == "fan" then ok, message = fanCommand(id, action, msg)
  elseif kind == "scene" then ok, message = sceneCommand(id, action)
  elseif kind == "macro" then ok, message = macroCommand(id, action)
  elseif kind == "watch" or kind == "listen" then ok, message = sourceCommand(kind, id, action)
  else return false, "This agent version doesn't support " .. tostring(kind) .. " yet."
  end
  return ok and true or false, message or (ok and nil or "Control4 didn't accept that command.")
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
  local catalog = Agent.catalog or {}
  local function n(list) return #(list or {}) end
  update("Status", string.format("%s on port %s · %d Mac%s connected · %d lights, %d fans, %d scenes, %d macros, %d watch, %d listen",
    Agent.port and "Listening" or "Not listening", tostring(Agent.port or Properties["Port"]),
    count, count == 1 and "" or "s", n(catalog.lights), n(catalog.fans),
    n(catalog.scenes), n(catalog.macros), n(catalog.watch), n(catalog.listen)))
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
    -- {"type":"dev"} from a paired Mac → developer tools (developer builds only).
    extension = function(msg)
      if msg.type ~= "dev" then return nil end
      if not Dev then return { ok = false, error = "This is a production build; developer tools aren't included." } end
      log("dev " .. tostring(msg.op) .. (msg.fn and (" " .. tostring(msg.fn)) or ""))
      return Dev.request(msg)
    end,
  })
  Agent.refresh()

  -- Project changes (devices added, removed, renamed, moved) → refresh.
  if type(C4SystemEvents) == "table" then
    for _, name in ipairs({ "OnItemAdded", "OnItemRemoved", "OnItemNameChanged", "OnItemMoved" }) do
      if C4SystemEvents[name] then call("RegisterSystemEvent", C4SystemEvents[name], 0) end
    end
  end

  startServer()
  update("Agent Version", Agent.versionText())
  if Dev then
    Dev.attach({
      store = {
        get = function(key) local ok, v = call("PersistGetValue", "hsl." .. key); return ok and v or nil end,
        set = function(key, value) call("PersistSetValue", "hsl." .. key, value) end,
      },
      now = os.time, update = update, version = Agent.versionText(),
    })
    -- Handy names for `eval` while debugging.
    DEV = { agent = Agent, project = Project, updates = Updates, core = Agent.core, json = json, call = call }
    -- Turn Developer Mode off when its week is up, even if nobody uses it.
    call("SetTimer", 60 * 60 * 1000, function() Dev.checkExpiry() end, true)
  end
  Agent.scheduleUpdateChecks()
end

function OnSystemEvent(data)
  log("project changed: " .. tostring(data))
  scheduleRefresh()
end

function OnPropertyChanged(strName)
  if strName == "Port" then startServer()
  elseif strName == "Site Name" then Agent.updateStatus()
  elseif strName == "Automatic Update Check" then Agent.scheduleUpdateChecks()
  elseif strName == "Developer Mode" and Dev then Dev.modeChanged()
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
  elseif action == "CheckForUpdates" then
    Agent.checkForUpdates()
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

  local function chunk(label, text)
    text = tostring(text or "")
    if text == "" then print(label .. ": (empty)"); return end
    for i = 1, math.min(#text, 12000), 3000 do print(label .. ": " .. text:sub(i, i + 2999)) end
  end
  local okL, locations = call("GetProjectItems", "LOCATIONS", "NO_ROOT_TAGS")
  chunk("locations", okL and locations or nil)

  -- What scene / macro / Watch-Listen discovery tried, and what came back.
  local p = Agent.probes or {}
  local function probeLog(label, probe)
    probe = probe or {}
    print(string.format("%s: agent/room %s, worked: %s", label, tostring(probe.agent or probe.id), tostring(probe.request or "none")))
    for _, entry in ipairs(probe.log or {}) do chunk("  " .. entry.request, entry.reply) end
  end
  probeLog("scenes", p.scenes)
  probeLog("macros", p.macros)
  for i, room in ipairs(p.rooms or {}) do
    print(string.format("room %s %s: %s watch, %s listen", tostring(room.id), tostring(room.name), tostring(room.watch), tostring(room.listen)))
    for var = 1000, 1012 do
      if i > 3 then break end
      local ok, value = call("GetDeviceVariable", room.id, var)
      if ok and value ~= nil then print(string.format("  room var %d = %s", var, tostring(value))) end
    end
  end
  local okC, codeItems = call("GetAllCodeItems")
  if okC and codeItems ~= nil then
    chunk("code items", type(codeItems) == "table" and json.encode(codeItems) or codeItems)
  end
  print(string.format("published: %d scenes, %d macros, %d watch, %d listen",
    #(Agent.catalog and Agent.catalog.scenes or {}), #(Agent.catalog and Agent.catalog.macros or {}),
    #(Agent.catalog and Agent.catalog.watch or {}), #(Agent.catalog and Agent.catalog.listen or {})))
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
