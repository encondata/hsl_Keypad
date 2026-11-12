# Control4 notes — what controllers actually do

A field reference for the parts of Control4 the HSL Keypad agent relies on that
the public DriverWorks documentation doesn't cover, or covers differently from
what a controller does. Each finding says where it was confirmed. Everything was
worked out with the agent's developer tools (`scripts/c4dev`) on a live
controller unless noted.

**Controllers tested so far:** Control4 X4, OS **4.3.0** (Lua 5.1). Nothing has
been run on OS 3.4 yet — see *OS 3.4* at the end.

## How to find things out

The fastest method, by far: **read the project's own programming.** Composer
stores every programmed command as XML, and `C4:GetAllCodeItems()` returns all of
it. If a project already does something (runs a macro, activates a scene), the
exact command name and parameter spelling are in there.

```sh
scripts/c4dev eval '
local t = DEV.json.encode(C4:GetAllCodeItems())
for s in t:gmatch("()<command>EXECUTE_MACRO</command>") do print(t:sub(s - 80, s + 260)) end'
```

Other useful read-only probes:

| Want | Call |
|---|---|
| A device's variables (names, IDs, values) | `C4:GetDeviceVariables(id)` |
| A device's capabilities / setup | `C4:SendUIRequest(id, "GET_CAPABILITIES" \| "GET_SETUP" \| "GET_STATE", {})` |
| Agents and their state | `C4:GetProjectItems("AGENTS", "NO_ROOT_TAGS")` |
| Rooms and their Navigator data | `C4:GetProjectItems("LOCATIONS", "NO_ROOT_TAGS")` |
| Proxies' project data | `C4:GetProjectItems("PROXIES", "NO_ROOT_TAGS")` |
| Names for a set of devices | `C4:GetDevices({ DeviceIds = "12,34,56" })` |

`SendUIRequest` returns `nil` (not an error) for request names a device doesn't
know, so probing is safe. Project items' `<state>` is **escaped XML** inside XML
(`&lt;…&gt;`) — unescape before matching.

## Advanced Lighting scenes

- Agent: item `Advanced Lighting`, driver file `control4_agent_adv_lighting.c4i`
  (not `…advanced_lighting…`). Found by name as a fallback.
- **List:** `SendUIRequest(alAgent, "GET_SCENE_LIST", {})` →

  ```xml
  <scene_list>
    <scene_info><scene_id>0</scene_id><name>All Interior Lights</name>
      <ramp_capable>True</ramp_capable><is_active>False</is_active>…</scene_info>
    …
  </scene_list>
  ```
  `GET_SCENES` and `GET_ALL_SCENES` return nothing. Scene IDs start at **0** and
  may have gaps.
- **Initial state:** `<is_active>True|False</is_active>` in the list.
- **Live state:** device events on the AL agent: `5·id` = activated,
  `5·id+1` = deactivated (`5·id+4` also exists; unused). Matches the docs.
- **Commands:** `ACTIVATE_SCENE {SCENE_ID = id}` — confirmed as the form Composer
  programming uses; `DEACTIVATE_SCENE`, `TOGGLE_SCENE` per the docs.

## Macros

- Agent: item `Macros`, driver file `control4_agent_macros.c4i`.
- **List:** `SendUIRequest(macroAgent, "GET_MACROS", {})` →
  `<macros><macro><id>1</id><name>…</name></macro>…</macros>`. The same list is
  in the agent's project state (`<agent_macro><macros>…`).
- **Run:** `SendToDevice(macroAgent, "EXECUTE_MACRO", { id = <macro id> })` —
  **lowercase `id`**, an integer. `MACRO_ID` / `ID` are silently ignored (this is
  why macros didn't run in 0.0.4). Confirmed from Composer's programming
  (`<param><name>id</name><value type="INTEGER">…`) and by running a test macro
  and watching its light change.
- A macro's ID is also the Macros agent's **event ID**; the macro's body is the
  programming attached to that event (`GetAllCodeItems`: `deviceid` = Macros
  agent, `eventid` = macro ID). Macros have no state to report.

## Rooms and Watch / Listen sources

- Rooms: `GetProjectItems("LOCATIONS")` items with `<type>8</type>`. Room data is
  in the item's `<state>` as escaped `<RoomDeviceData>`.
- Room-level `GET_VIDEO_DEVICES` / `GET_AUDIO_DEVICES`-style UI requests return
  nothing — the lists aren't exposed that way.
- **Sources** are Navigator's per-room lists inside `RoomDeviceData`:
  `<OrderedWatchList>`, `<OrderedListenList>` (also Movie, TV, Music, Radio,
  Light, Comfort, Security, Camera… lists). **Every** device appears in every
  list:

  ```xml
  <device><deviceid>217</deviceid><order>1</order><hidden>0</hidden></device>
  <device><deviceid>209</deviceid><order>4294967295</order><hidden>1</hidden></device>
  ```
  - `hidden 0` = shown in that room's menu; that's the source list.
  - `order` is Navigator's order; `4294967295` = unordered (keep document order).
  - IDs near 2³² (e.g. `4294966295`) are Navigator's built-in entries, not devices.
  - `<RoomHidden>True</RoomHidden>` rooms (e.g. "Purchased Drivers") are hidden in
    Navigator; skip their sources.
  - **One device can be in both lists of a room** (an Apple TV is a Watch and a
    Listen source). Don't key sources by room + device alone.
- **Names:** `GetDeviceDisplayName(id)` returns **nothing** on X4. Use
  `GetDevices({ DeviceIds = "a,b,c" })[id].deviceName` (one call for all).
- **State:** room variables `1001` CURRENT_AUDIO_DEVICE and `1002`
  CURRENT_VIDEO_DEVICE (0 = none). Selecting a **video** source sets both to that
  device; selecting an **audio** source sets 1002 to 0 and 1001 to the device.
  So Listen is "active" only when 1002 is 0.
- **Commands:** `SendToDevice(room, "SELECT_VIDEO_DEVICE" | "SELECT_AUDIO_DEVICE",
  { deviceid = id })`, `SendToDevice(room, "ROOM_OFF")` (also the form Composer
  programming uses).

## Fans

- Discovered via `GetDevices({ C4iNames = "fan.c4i" })` (proxy driver `fan.c4i`).
- **Variables on X4** (names differ from the docs):

  | ID | Name | Meaning |
  |---|---|---|
  | 1000 | `IS_ON` | 0/1 |
  | 1001 | `CURRENT_SPEED` | 0 = off, 1…n |
  | 1002 | `IS_REVERSED` | 0/1 |
  | 1003 | `PRESET_SPEED` | speed used by "on" |

  The docs' "Is On" / "Current Selected Speed" never matched on X4 (fan state was
  missing until 0.0.6). Match by name, accepting both.
- **Speed count and names:** `SendUIRequest(fan, "GET_SETUP", {})` →

  ```xml
  <fan_setup><speeds_count>4</speeds_count>
    <speed_names>Low,Medium,Medium High,High</speed_names>
    <can_reverse>False</can_reverse><can_set_preset>True</can_set_preset>
    <preset_speed>4</preset_speed></fan_setup>
  ```
  `GET_CAPABILITIES` has `<discrete_levels>` as well. Fans are not all 3-speed.
- **Commands:** `ON`, `OFF`, `TOGGLE`, `SET_SPEED {SPEED = n}` (0 = off).
- A fan often has a companion `keypad_proxy` item ("… Fan Keypad") whose button
  engravings repeat the speed names.

## Lights (light_v2)

- Variables: `1000` light state, `1001` brightness percent.
- Commands used: `TOGGLE`; `BUTTON_ACTION {BUTTON_ID = 0|1, ACTION = 1|2|0}`
  (0 = top/on, 1 = bottom/off; action 1 press, 2 release after click, 0 release
  after hold — used for press-and-hold dimming); `SET_BRIGHTNESS_TARGET`.
- Not yet found: a reliable dimmer-vs-switch flag (every light is published as
  dimmable).

## Agents, packaging and Composer

- `<agent>true</agent>` + `<combo>true</combo>` and a single proxy makes a `.c4z`
  install under Composer's **Agents** tab via *Add or Update Driver or Agent*.
- Composer replaces an installed agent only when `driver.xml` `<version>` is
  higher — bump it every release.
- Control4 only auto-updates drivers hosted in its own database; GitHub releases
  are installed by hand.
- `C4:GetDriverConfigInfo("version")` reads the `<version>` at runtime.

## System and environment

- `C4:GetVersionInfo().version` → e.g. `4.3.0.766029-res`; `_VERSION` is `Lua 5.1`.
- Project-change system events used: `OnItemAdded`, `OnItemRemoved`,
  `OnItemNameChanged`, `OnItemMoved` (looked up in `C4SystemEvents`).
- `C4:CreateServer` / `ServerSend` / `ServerCloseClient` (3.3.0+) for the TCP
  listener; `C4:url()` (2.8.1+) for HTTPS to GitHub.

## OS 3.4

Every documented call the agent uses is available from OS 3.3.0 or earlier
(`ServerCloseClient` and `GetAllCodeItems` are the newest, 3.3.0). The
undocumented pieces above — `GET_SCENE_LIST`, `GET_MACROS`, the room Navigator
lists, fan `GET_SETUP` and variable names — are confirmed on OS 4.3 only. The
agent tolerates their absence (empty lists, generic 3-speed fans), and on 3.4
`GetDeviceDisplayName` may well work. To confirm: install a developer build on a
3.4 controller, turn on Developer Mode, pair, and repeat the probes in this file.
