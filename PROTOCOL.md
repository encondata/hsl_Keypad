# HSL Keypad — app ↔ Control4 agent protocol (draft 5)

See also [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (how the agent is built),
[docs/CONTROL4-NOTES.md](docs/CONTROL4-NOTES.md) (what controllers really do) and
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) (testing, debugging, releasing).

The Mac app owns the keypad: pages, button assignments, labels and icons are
stored in the app. On each Control4 project, the **HSL Keypad agent** (a `.c4z` added in
Composer Pro and listed under **Agents**) **discovers everything assignable on its own and
publishes it**; it runs commands and pushes state. It stores nothing about
buttons. The app can be connected to **several controllers at once**.

Status: **draft for review.** Items marked *(SDK)* must be confirmed against the
DriverWorks SDK before we rely on them.

## Implementation status (agent 0.0.6)

Source in `HSLKeypad/` (`driver.xml`; `driver.lua` = Control4 layer;
`project.lua` = room/scene/macro/source discovery; `core.lua` = this protocol;
`json.lua`); package with `scripts/package.sh` → `build/HSLKeypad.c4z`.
Tested with Lua unit tests (`luajit tests/run.lua`) and the real agent code in
the emulator (`scripts/run-emulator.sh`) against the app's C4Hub.

- **Confirmed on X4 (0.0.1):** pairing, lights and fans, live state, project
  changes, the H icon.
- **New in 0.0.2, not yet confirmed on a controller:** Advanced Lighting
  scenes, macros, Watch/Listen sources, every room listed, documentation with
  the full HackSpaceLabs logo. Scene and source *commands and state* use
  documented calls; *listing* scenes, macros and room sources uses undocumented
  `SendUIRequest` names and project XML, tried in order (see `project.lua`).
  **Log Project Info** prints every attempt and reply.
- **On X4 (0.0.3):** 31 rooms, 46 lights, 4 fans, 14 macros listed; 0 scenes and
  0 Watch/Listen sources; running a macro (`EXECUTE_MACRO`) didn't work.
- **Fixed in 0.0.6 (found on X4):** fan variables are `IS_ON` / `CURRENT_SPEED` (live fan
  state never matched before); speed count and names come from the fan proxy's
  `GET_SETUP` (`<speeds_count>`, `<speed_names>`) and are published as `speeds` +
  `speedNames`; a device in both a room's Watch and Listen lists keeps both entries
  (sources keyed by kind + id); Listen is active only for an audio-only session.
- **Confirmed on X4 (0.0.5, via the developer tools):** scenes — `SendUIRequest(AL agent,
  "GET_SCENE_LIST")` → `<scene_list><scene_info><scene_id>…<name>…<is_active>`; AL events
  are 5·id (activated), 5·id+1 (deactivated); `ACTIVATE_SCENE {SCENE_ID}` (as Composer
  programs it). Macros — `GET_MACROS` → `<macros><macro><id>…<name>`; run with
  `EXECUTE_MACRO {id}` (lowercase, INTEGER; macro id = Macros agent event id).
  Watch / Listen — each room item's `<state>` (escaped XML) has `<OrderedWatchList>` /
  `<OrderedListenList>` of `<device><deviceid><order><hidden>`; visible entries (hidden 0)
  are the sources, IDs near 2^32 are Navigator built-ins, rooms with `<RoomHidden>True`
  are skipped. Names come from `GetDevices{DeviceIds}` (`GetDeviceDisplayName` returns
  nothing on X4). On a test project: 12 scenes, 15 macros, 20 watch / 79 listen.
- **New in 0.0.4 (developer build):** `devtools.lua` — `{"type":"dev"}` with ops
  `ping`, `call` (any C4 API), `eval` (Lua), `logs`; only for paired Macs, only
  with **Developer Mode** On (7-day limit). The Mac app relays it from
  127.0.0.1:8760 for `scripts/c4dev`. Status counts every kind; scenes/macros
  also read from the agents' project item data. Pre-1.0 releases are developer
  builds.
- **New in 0.0.3:** **Agent Version** property (`Core.VERSION` + `driver.xml`
  build via `C4:GetDriverConfigInfo`), GitHub update check (`updates.lua`,
  `C4:url()`), **Update Status** / **Automatic Update Check** properties,
  **Check for Updates** action; the app is told in `welcome.update` and live
  `update` messages.
- Not yet: dimmer vs switch detection (all lights report dimmable), netmask (not exposed; the app uses the Mac's), project
  name (the **Site Name** property instead), self-update (Control4 only
  auto-updates drivers hosted in its own driver database).

## Agent

- **A Control4 agent, not a room driver**: one per project, installed with
  "Add or Update Driver or Agent" and shown on Composer's Agents tab, like
  third-party agents already on the market. It is still a DriverWorks `.c4z`;
  only its declaration differs. *(SDK: the exact `driver.xml` element that
  makes a package an agent — from the DriverWorks XML Reference or an existing
  agent's package.)*
- No per-device setup in Composer. The only properties: Port, Pairing Code,
  Paired Macs (revocable), Debug.
- **Targets OS 3.4.x and X4 (OS 4) with one `.c4z`.** Rules that keep it
  working on both: networking only through DriverWorks' own APIs
  (`C4:CreateServer` and friends), **never LuaSocket** (X4 ships an updated
  LuaSocket and Control4 says it will be removed) and **never `io.popen`**
  (removed in X4); JSON via a small pure-Lua encoder bundled in the agent
  unless the SDK confirms a built-in one on both; anything X4-only is
  feature-detected at runtime, never required. `driver.xml` declares 3.4 as
  the minimum OS. Test on both before calling it done.

## Transport

- TCP, LAN only — other sites over the site-to-site VPN. The agent listens on
  its Port property (default **8751**).
- Single-line JSON messages, newline-terminated (UTF-8).
- `{"type":"ping"}` ↔ `{"type":"pong"}`; the app pings every 30 s, treats two
  missed pongs as offline, and reconnects with backoff (1, 2, 5, 10, 30 s).
- Requests carry `"ref"`; the reply echoes it.

## Pairing and controller identity

The agent creates a random **controller ID** (UUID) on first run and keeps it
in persistent storage, so the app recognises the same controller whether it is
reached on the LAN, over the VPN, or after an IP change.

```json
→ {"type":"hello","app":"HSLToolbar","version":"0.4.0","device":"Jon's MacBook Pro","pairingCode":"482913"}
← {"type":"welcome","controllerId":"6f1c…","project":"Smith Residence",
   "agentVersion":"0.0.1","token":"b9c1…","address":"192.168.1.50","netmask":"255.255.255.0"}
```

`welcome` also carries `"os"`, and `"update":{"version":"0.0.4","url":"https://github.com/…/releases/tag/v0.0.4"}`
when the agent knows of a newer release; when it finds one later it sends
`{"type":"update","version":…,"url":…}` to every connected Mac.

The app keys pages and tokens by `controllerId`; the token goes in the Keychain
(shared "HSL Toolbar API keys" entry). Later connections send `"token"`
instead of `"pairingCode"`. Bad code/token → `{"type":"error","code":"unauthorized","message":"…"}`,
then the agent closes the connection — **only after that line has been sent**,
otherwise the app just sees a dropped connection and keeps retrying. `address`/`netmask` are the controller's own
LAN settings, used for "this network" detection (below). *(SDK: reading the
controller's IP/netmask.)*

## Published catalog (dynamic)

Right after `welcome` the agent sends the full catalog unprompted, and sends it
again (or a delta) whenever the project changes — devices added, removed,
renamed, moved between rooms, scenes or macros edited. The app never has to ask,
but may: `{"type":"catalog","ref":"1"}`.

```json
← {"type":"catalog","revision":17,
   "rooms":  [{"id":12,"name":"Kitchen","floor":"Main"}],
   "lights": [{"id":345,"room":12,"name":"Cans","dimmable":true,"color":false}],
   "fans":   [{"id":402,"room":20,"name":"Family Fan","speeds":4,"speedNames":["Low","Medium","Medium High","High"]}],
   "scenes": [{"id":3,"name":"Movie Time"}],
   "macros": [{"id":7,"name":"Goodnight"}],
   "watch":  [{"id":1200200,"room":12,"device":200,"name":"Apple TV"}],
   "listen": [{"id":1200210,"room":12,"device":210,"name":"Spotify"}]}

← {"type":"catalogDelta","revision":18,
   "upsert":{"lights":[{"id":351,"room":12,"name":"Island","dimmable":true,"color":false}]},
   "remove":{"macros":[7]}}
```

- `revision` increases with every change; if the app sees a gap it requests the
  full catalog.
- Discovery *(SDK)*: lights = devices on the `light_v2` proxy; fans = `fan`
  proxy; scenes from the Advanced Lighting agent; macros from the Macros agent;
  change hooks via project/device events.
- Removed items that are still on a button show as "missing" in the app rather
  than disappearing silently.
- `watch` / `listen` are the sources in each room's Watch and Listen menus. A
  source's `id` is `room × 100000 + device`, so the same device in two rooms is
  two buttons.

## State

The app subscribes, per controller, to what is on its buttons (all pages):

```json
→ {"type":"watch","targets":[{"kind":"light","id":345},{"kind":"fan","id":402},{"kind":"scene","id":3}]}
← {"type":"state","kind":"light","id":345,"on":true,"level":80}
← {"type":"state","kind":"fan","id":402,"on":true,"speed":2}
← {"type":"state","kind":"scene","id":3,"active":true}
← {"type":"state","kind":"watch","id":1200200,"active":true}
```

`watch` replaces the previous subscription; the agent replies with current
state for every target, then sends `state` on each change. Macros have no state.
Scene state comes from Advanced Lighting events (Activated = id×5,
Deactivated = id×5+1); a source is `active` while its room's current video
(Watch) or audio (Listen) device is that source.

## Commands

```json
→ {"type":"command","ref":"9","kind":"light","id":345,"action":"toggle"}
← {"type":"result","ref":"9","ok":true}
```

| kind  | action        | extra                         | Notes |
|-------|---------------|-------------------------------|-------|
| light | `on` `off` `toggle` | —                       | |
| light | `level`       | `"value": 0–100`              | right-click slider, "Set level" click action |
| light | `rampStart`   | `"direction": "up" \| "down"` | press-and-hold *(SDK)* |
| light | `rampStop`    | —                             | on release; app sends after 15 s max as a safety |
| fan   | `on` `off` `toggle` | —                       | |
| fan   | `speed`       | `"value": 0…speeds`           | 0 = off |
| scene | `activate` `toggle` `off` | —                 | |
| macro | `run`         | —                             | |
| watch, listen | `select`  | —                             | `SELECT_VIDEO_DEVICE` / `SELECT_AUDIO_DEVICE` in that room |
| watch, listen | `roomOff` | —                             | `ROOM_OFF` for that room |
| watch, listen | `toggle`  | —                             | room off if this source is active, else select it |

## App side: controllers, sites, pages

**Controllers** (Settings → Control4): a list, each with name (from `project`),
address, port, colour, and the `controllerId` learned at pairing. The app keeps
a connection open to every controller that has buttons on any page, so the
"All sites" page works.

**Pages** belong to one controller (a *site page*) or to **All sites** (a
*mixed page*). Every button stores its controller explicitly, so a mixed page
can hold buttons from any site:

```json
{"pages":[
  {"id":"main","name":"Main","site":"6f1c…","buttons":[
    {"slot":1,"controller":"6f1c…","kind":"light","id":345,"label":"Kitchen Cans",
     "icon":"light.recessed.fill","click":"toggle","hold":"dim","rightClick":"slider"}]},
  {"id":"fav","name":"Favorites","site":null,"buttons":[
    {"slot":2,"controller":"a90e…","kind":"light","id":88,"label":"Dock Lights","click":"toggle"}]}]}
```

**Which pages load first.** When the panel opens:

1. If Settings → Control4 → *Open first* is set to a site, use that site.
2. Otherwise (*Automatic*), find the controller on **this network**: any Mac
   IPv4 address that is in the same subnet as a controller's
   `address`/`netmask`. Its pages are listed first and its first page opens.
3. Otherwise, open the last page used.

The page menu groups pages by site — this network first, then other sites
(reachable over VPN), offline sites dimmed, then *All sites* pages. On mixed
pages each button shows a small site badge; buttons from an offline controller
are dimmed and show their last known state.

## Decisions so far

- **Sites run a mix of OS 3.4.x and X4**, so both are required, not optional:
  every release of the agent is tested on one 3.4 controller and one X4
  controller before it's installed anywhere else. The `welcome` message adds
  `"os":"3.4.3"` / `"4.0.x"` so the app can show each site's OS and we can
  tell which side a bug report comes from. Don't upgrade the 3.4 test
  controller to X4 — going back from 3.4.3+ needs a factory reset.

- **This network = IP match only.** All sites share one Wi-Fi name, so SSIDs
  are never used here. The app reads its own IPv4 addresses and netmasks and
  compares them with each controller's `address`/`netmask` from `welcome`
  (assume /24 until the agent has reported a netmask).
- **Pages are dynamic.** Start with one page ("Main", on the first paired
  controller). *New Page* asks for a name and a site: one controller, or
  *All sites*. Pages can be renamed, reordered, moved between sites (buttons
  from other controllers then turn "missing") and deleted.
- **One Mac for now, sync later.** Pages live in one JSON file
  (`~/Library/Application Support/HSL Toolbar/keypad.json`), every page and
  button has a stable ID and a `modified` timestamp, so a later sync (iCloud
  Drive or similar) can merge per page/button without a format change.
  Tokens stay in the Keychain and are not synced.

## Open questions

- The exact `driver.xml` declaration that installs the package as an agent *(SDK)*.
- Ramp support on `light_v2` *(SDK)*.
- Delta vs always-full catalog — full is simpler; deltas matter only for very
  large projects.
- Should one Mac's pages sync to other Macs (iCloud or a file)? Later.
