-- HSL Keypad agent: project discovery beyond lights and fans —
-- rooms, Advanced Lighting scenes, macros, and each room's Watch / Listen
-- sources. Pure parsing + probing; driver.lua wires the results in.
--
-- What's documented (snap-one.github.io DriverWorks docs):
--   * Scene commands ACTIVATE_SCENE / DEACTIVATE_SCENE / TOGGLE_SCENE {SCENE_ID}
--     and scene events (Activated = id*5, Deactivated = id*5+1)
--   * Room commands SELECT_VIDEO_DEVICE / SELECT_AUDIO_DEVICE {deviceid} and
--     room variables 1001 (current audio device) / 1002 (current video device)
--   * C4:SendUIRequest(id, request, params) -> XML reply, C4:GetProjectItems
-- What isn't (so these are probed, and every probe is logged by
-- "Log Project Info"): the request names that list scenes, macros and room
-- sources, the macro run command, and the project XML schema.

local Project = {}

-- XML ------------------------------------------------------------------------------

local function unescape(s)
  return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end
Project.unescape = unescape

local function field(block, ...)
  for _, tag in ipairs({ ... }) do
    local v = block:match("<" .. tag .. "[^>]*>(.-)</" .. tag .. ">")
    if v then return unescape(v) end
    v = block:match("%s" .. tag .. '="([^"]*)"')
    if v then return unescape(v) end
  end
end

--- Project items: every <item> header (id, name, type) in GetProjectItems XML,
--- in document order, with the text up to the next item as `data`.
function Project.items(xml)
  local out = {}
  if type(xml) ~= "string" then return out end
  local pos = 1
  while true do
    local s, e, id, name, kind = xml:find("<item>%s*<id>(%d+)</id>%s*<name>(.-)</name>%s*<type>(%d+)</type>", pos)
    if not s then break end
    local nextItem = xml:find("<item>", e + 1, true) or #xml + 1
    out[#out + 1] = { id = tonumber(id), name = unescape(name), type = tonumber(kind), data = xml:sub(e + 1, nextItem - 1) }
    pos = e + 1
  end
  return out
end

--- Records with an id and a name in any reply XML: <scene><id>3</id><name>…
--- or <macro id="7" name="…"/> and similar. Deduplicated by id.
function Project.records(xml, tags)
  local out, seen = {}, {}
  if type(xml) ~= "string" then return out end
  for _, tag in ipairs(tags or { "scene", "macro", "device", "source", "item", "entry" }) do
    for block in xml:gmatch("<" .. tag .. "[%s>].-</" .. tag .. ">") do
      local id = tonumber(field(block, "id", "scene_id", "sceneid", "SCENE_ID", "macro_id", "deviceid", "device_id"))
      local name = field(block, "name", "scene_name", "NAME", "display_name")
      if id and name and not seen[id] then seen[id] = true; out[#out + 1] = { id = id, name = name } end
    end
    for attrs in xml:gmatch("<" .. tag .. "(%s[^>]-)/?>") do
      local id = tonumber(attrs:match('%sid="(%d+)"'))
      local name = attrs:match('%sname="([^"]*)"')
      if id and name and not seen[id] then seen[id] = true; out[#out + 1] = { id = id, name = unescape(name) } end
    end
  end
  return out
end

-- Discovery --------------------------------------------------------------------------

Project.ROOM_TYPE = 8
Project.AL_FILES = { "control4_agent_advanced_lighting.c4i", "advanced_lighting.c4i" }
Project.MACRO_FILES = { "control4_agent_macros.c4i", "macros.c4i" }
Project.SCENE_REQUESTS = { "GET_SCENES", "GET_ALL_SCENES", "GET_SCENE_LIST" }
Project.MACRO_REQUESTS = { "GET_MACROS", "GET_ALL_MACROS", "GET_MACRO_LIST" }
Project.WATCH_REQUESTS = { "GET_VIDEO_DEVICES", "GET_WATCH_DEVICES" }
Project.LISTEN_REQUESTS = { "GET_AUDIO_DEVICES", "GET_LISTEN_DEVICES" }
Project.ROOM_AUDIO_VAR, Project.ROOM_VIDEO_VAR = 1001, 1002

--- Finds an agent's device ID by its driver file, then by name in the
--- project's AGENTS items.
function Project.findAgent(c4, files, namePattern, agentItems)
  for _, file in ipairs(files) do
    local ok, ids = c4("GetDevicesByC4iName", file)
    if ok and type(ids) == "table" then
      -- Either a list of IDs or a map of ID -> name; accept both.
      for k, v in pairs(ids) do return tonumber(type(v) == "number" and v or k) end
    end
  end
  for _, item in ipairs(agentItems or {}) do
    if item.name:lower():find(namePattern) then return item.id end
  end
end

--- Tries each request in turn; returns the first non-empty list of records,
--- plus a log of what each request returned.
function Project.probe(c4, deviceId, requests, tags)
  local log = {}
  if not deviceId then return {}, log end
  for _, request in ipairs(requests) do
    local ok, reply = c4("SendUIRequest", deviceId, request, {})
    log[#log + 1] = { request = request, reply = ok and reply or nil }
    if ok and type(reply) == "string" then
      local found = Project.records(reply, tags)
      if #found > 0 then return found, log, request end
    end
  end
  return {}, log
end

--- Device IDs listed inside a room's project data under any of `tags`
--- (e.g. <video_devices><id>12</id>…</video_devices>).
function Project.roomDevices(roomData, tags)
  local ids, seen = {}, {}
  for _, tag in ipairs(tags) do
    for inner in (roomData or ""):gmatch("<" .. tag .. "[^>]*>(.-)</" .. tag .. ">") do
      for id in inner:gmatch("<id>(%d+)</id>") do
        id = tonumber(id)
        if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
      end
      for id in inner:gmatch('id="(%d+)"') do
        id = tonumber(id)
        if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
      end
    end
  end
  return ids
end

--- A source's catalog ID: stable, unique per room + device.
function Project.sourceId(room, device) return room * 100000 + device end
function Project.splitSourceId(id) return math.floor(id / 100000), id % 100000 end

return Project
