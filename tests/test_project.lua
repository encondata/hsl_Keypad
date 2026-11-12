local Project = require("project")

-- Project items (GetProjectItems XML)
local xml = [[
<item><id>1</id><name>Home</name><type>2</type><itemdata/><subitems>
  <item><id>12</id><name>Kitchen &amp; Dining</name><type>8</type><itemdata><video_devices><id>200</id><id>201</id></video_devices></itemdata></item>
  <item><id>14</id><name>Living Room</name><type>8</type><itemdata><audio_devices><device id="210"/></audio_devices></itemdata></item>
</subitems></item>]]
local items = Project.items(xml)
check(#items == 3 and items[2].id == 12 and items[2].type == 8, "project items parsed in order")
check(items[2].name == "Kitchen & Dining", "item names unescaped")
check(#Project.roomDevices(items[2].data, { "video_devices" }) == 2, "room video devices from <id> children")
check(Project.roomDevices(items[3].data, { "audio_devices" })[1] == 210, "room audio devices from id attributes")
check(#Project.roomDevices(items[3].data, { "video_devices" }) == 0, "no video devices listed")
check(#Project.items(nil) == 0 and #Project.items("<nothing/>") == 0, "empty input")

-- Records in UI request replies
local scenes = Project.records("<scenes><scene><id>3</id><name>Movie Time</name></scene><scene><name>All Off</name><id>4</id></scene></scenes>", { "scene" })
check(#scenes == 2 and scenes[1].id == 3 and scenes[2].name == "All Off", "element records, either field order")
local macros = Project.records('<macros><macro id="7" name="Goodnight"/><macro id="8" name="Leave &amp; Lock"/></macros>', { "macro" })
check(#macros == 2 and macros[2].name == "Leave & Lock", "attribute records")
local dup = Project.records('<x><scene><id>3</id><name>A</name></scene><scene id="3" name="A"/></x>', { "scene" })
check(#dup == 1, "records deduplicated by id")
check(#Project.records("<scene><id>x</id></scene>", { "scene" }) == 0, "records need a numeric id and a name")

-- Probing: first request that returns records wins; every attempt logged
local calls = {}
local fakeCall = function(name, id, request)
  calls[#calls + 1] = request
  if request == "GET_ALL_SCENES" then return true, "<scenes><scene><id>9</id><name>Sunset</name></scene></scenes>" end
  return true, "<error/>"
end
local found, log, worked = Project.probe(fakeCall, 100, Project.SCENE_REQUESTS, { "scene" })
check(#found == 1 and found[1].name == "Sunset" and worked == "GET_ALL_SCENES", "probe finds the request that works")
check(#log == 2 and log[1].request == "GET_SCENES", "probe logs each attempt")
local none = Project.probe(fakeCall, nil, Project.SCENE_REQUESTS)
check(#none == 0, "no agent → nothing")

-- Agent lookup: by driver file first, then by name
local byFile = Project.findAgent(function(name, file) return true, file == "control4_agent_macros.c4i" and { 101 } or {} end,
  Project.MACRO_FILES, "macro", {})
check(byFile == 101, "agent found by driver file (list form)")
local byMap = Project.findAgent(function() return true, { [102] = "Macros" } end, Project.MACRO_FILES, "macro", {})
check(byMap == 102, "agent found by driver file (map form)")
local byName = Project.findAgent(function() return true, {} end, Project.AL_FILES, "advanced lighting",
  { { id = 5, name = "Scheduler" }, { id = 100, name = "Advanced Lighting" } })
check(byName == 100, "agent found by name")

-- Source IDs
local id = Project.sourceId(14, 210)
local room, device = Project.splitSourceId(id)
check(id == 1400210 and room == 14 and device == 210, "source id round trip")
