local Project = require("project")

-- Project items (GetProjectItems XML)
-- Room state as X4 stores it: escaped XML; every device in each Ordered*List
-- with a hidden flag, plus Navigator's built-in entries (IDs near 2^32).
local function dev(id, order, hidden)
  return "&lt;device&gt;&lt;deviceid&gt;" .. id .. "&lt;/deviceid&gt;&lt;order&gt;" .. order
    .. "&lt;/order&gt;&lt;hidden&gt;" .. hidden .. "&lt;/hidden&gt;&lt;/device&gt;"
end
local xml = [[
<item><id>1</id><name>Home</name><type>2</type><itemdata/><subitems>
  <item><id>12</id><name>Kitchen &amp; Dining</name><type>8</type><itemdata><config_data_file>roomdevice.c4i</config_data_file></itemdata><state>&lt;RoomDeviceData&gt;&lt;OrderedWatchList&gt;]]
  .. dev(209, 4294967295, 1) .. dev(224, 2, 0) .. dev(217, 1, 0) .. dev(4294966295, 0, 0)
  .. [[&lt;/OrderedWatchList&gt;&lt;OrderedListenList&gt;]] .. dev(268, 4294967295, 0) .. dev(224, 4294967295, 0)
  .. [[&lt;/OrderedListenList&gt;&lt;/RoomDeviceData&gt;</state></item>
  <item><id>14</id><name>Living Room</name><type>8</type><itemdata/><state>&lt;RoomDeviceData/&gt;</state></item>
</subitems></item>]]
local items = Project.items(xml)
check(#items == 3 and items[2].id == 12 and items[2].type == 8, "project items parsed in order")
check(items[2].name == "Kitchen & Dining", "item names unescaped")
local watch = Project.orderedSources(items[2].data, Project.WATCH_LIST)
check(#watch == 2 and watch[1] == 217 and watch[2] == 224, "watch sources: visible only, Navigator order, no built-ins")
local listen = Project.orderedSources(items[2].data, Project.LISTEN_LIST)
check(#listen == 2 and listen[1] == 268 and listen[2] == 224, "unordered sources keep document order")
check(#Project.orderedSources(items[3].data, Project.WATCH_LIST) == 0, "room with no lists → no sources")
check(#Project.orderedSources(nil, Project.WATCH_LIST) == 0, "no room data → no sources")
local hiddenRoom = "<state>&lt;RoomDeviceData&gt;&lt;RoomHidden&gt;True&lt;/RoomHidden&gt;&lt;OrderedWatchList&gt;" .. dev(217, 1, 0) .. "&lt;/OrderedWatchList&gt;&lt;/RoomDeviceData&gt;</state>"
check(Project.roomHidden(hiddenRoom) and #Project.orderedSources(hiddenRoom, Project.WATCH_LIST) == 0, "rooms hidden in Navigator publish no sources")
check(not Project.roomHidden(items[2].data), "visible room not hidden")
check(#Project.items(nil) == 0 and #Project.items("<nothing/>") == 0, "empty input")

-- X4 Advanced Lighting reply (GET_SCENE_LIST)
local alReply = "<scene_list><scene_info><scene_id>0</scene_id><name>All Interior Lights</name><is_active>False</is_active></scene_info>"
  .. "<scene_info><scene_id>2</scene_id><name>Guest Bath &amp; Day</name><ramp_capable>True</ramp_capable><is_active>True</is_active></scene_info></scene_list>"
local alScenes = Project.records(alReply, { "scene_info", "scene", "item" })
check(#alScenes == 2 and alScenes[1].id == 0 and alScenes[2].name == "Guest Bath & Day", "X4 scene_info records, scene 0 included")
check(alScenes[1].active == false and alScenes[2].active == true, "scene is_active read")
-- X4 Macros agent reply (GET_MACROS)
local mReply = "<macros><macro><id>1</id><name>KPD Office</name></macro><macro><id>15</id><name>Test Macro</name></macro></macros>"
local mRecs = Project.records(mReply, { "macro", "item" })
check(#mRecs == 2 and mRecs[2].id == 15 and mRecs[2].active == nil, "X4 macro records")

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
  if request == "GET_SCENES" then return true, "<scenes><scene><id>9</id><name>Sunset</name></scene></scenes>" end
  return true, "<error/>"
end
local found, log, worked = Project.probe(fakeCall, 100, Project.SCENE_REQUESTS, { "scene" })
check(#found == 1 and found[1].name == "Sunset" and worked == "GET_SCENES", "probe finds the request that works")
check(#log == 2 and log[1].request == "GET_SCENE_LIST", "probe logs each attempt")
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

-- Scenes/macros kept in an agent's own project item data
local agentsXml = [[<item><id>100</id><name>Advanced Lighting</name><type>9</type><itemdata><scenes><scene><scene_id>5</scene_id><name>Evening</name></scene></scenes></itemdata></item><item><id>101</id><name>Macros</name><type>9</type><itemdata><macro id="9" name="Away"/></itemdata></item>]]
local agentItems = Project.items(agentsXml)
local fromData = Project.fromItemData(agentItems, 100, { "scene" })
check(#fromData == 1 and fromData[1].id == 5 and fromData[1].name == "Evening", "scenes from the agent's item data (scene_id)")
check(Project.fromItemData(agentItems, 101, { "macro" })[1].name == "Away", "macros from the agent's item data")
check(#Project.fromItemData(agentItems, 999, { "scene" }) == 0, "unknown agent → nothing")
