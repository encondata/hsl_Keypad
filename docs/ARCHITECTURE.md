# HSL Keypad agent — architecture

How the Control4 side of HSL Keypad is put together, and why. For the wire
format see [PROTOCOL.md](../PROTOCOL.md); for what Control4 actually does on a
controller (much of it undocumented) see [CONTROL4-NOTES.md](CONTROL4-NOTES.md);
for building, testing and releasing see [DEVELOPMENT.md](DEVELOPMENT.md).

## The big picture

```
 HSL Toolbar (Mac)                         Control4 controller
 ┌──────────────────────┐   TCP 8751    ┌──────────────────────────────────┐
 │ C4Hub ── C4Connection├──────────────▶│ HSL Keypad agent (.c4z, Lua 5.1) │
 │   pages, buttons,    │  JSON lines   │   core.lua    protocol, pairing  │
 │   assignments        │◀──────────────┤   driver.lua  Control4 layer     │
 └──────────────────────┘ catalog/state │   project.lua discovery parsing  │
                                        │          │ DriverWorks API       │
                                        │          ▼                       │
                                        │ lights, fans, Advanced Lighting, │
                                        │ Macros agent, rooms (Navigator)  │
                                        └──────────────────────────────────┘
```

- **The Mac owns the keypad.** Pages, button slots, labels, icons and click
  behaviour live in the Mac app. The agent stores nothing about buttons.
- **The agent owns the project.** It discovers everything assignable on its own,
  publishes it as a *catalog*, runs commands, and pushes live state. No
  per-device setup in Composer.
- **One agent per project, many Macs per agent, many controllers per Mac.**
  Each controller has a permanent random ID, so a Mac recognises it on the LAN,
  over a site-to-site VPN, or after an IP change.
- **One package for OS 3.4.x and X4 (OS 4.x).** Only DriverWorks' own APIs: no
  LuaSocket, no `io.popen`, JSON in pure Lua. Every Control4 call is
  feature-tolerant (see *Defensive calls*).

## Package layout (`HSLKeypad/`)

| File | Role | Depends on Control4? |
|---|---|---|
| `driver.xml` | Declares the package an **agent** (`<agent>true</agent>`, `<combo>`, one `hsl_keypad` proxy), version/build, properties, actions, icons, documentation. Minimum OS 3.4.0. | — |
| `driver.lua` | The **Control4 layer**: discovery, variable/event listeners, commands, server, properties, lifecycle. Everything that calls `C4:`. | Yes |
| `core.lua` | The **protocol**: clients, pairing, tokens, catalog/state/command messages. Pure Lua; Control4 is injected (`deps`). | No |
| `project.lua` | **Parsing** of project XML and UI-request replies: rooms, scenes, macros, room sources, fan setup. Pure Lua. | No |
| `updates.lua` | GitHub release check: parse, compare versions, pick the latest. HTTP via an injected `C4:url()`. | Injected |
| `devtools.lua` | **Developer builds only**: `ping`, `call`, `eval`, `logs` for a paired Mac while Developer Mode is on. Absent from production packages. | Yes |
| `json.lua` | Small pure-Lua JSON encoder/decoder (`json.array` marks empty arrays). | No |
| `www/` | Composer icons (16/32 px device icons, 70–1024 px experience icons) and `documentation.html` with the full HackSpaceLabs logo. | — |

The split exists so most logic is testable off-controller: `core.lua`,
`project.lua`, `updates.lua` and `json.lua` run under LuaJIT on a Mac with no
Control4 at all (`tests/`), and `driver.lua` runs unmodified in the emulator.

## driver.lua, section by section

### Helpers
- `call(name, ...)` — **every** `C4:` call goes through this. It checks the
  function exists and wraps it in `pcall`; a missing or failing API returns
  `false` and logs (when Debug Mode is on) instead of crashing the agent. This
  is what lets one package run on OS versions with different API sets.
- `update(property, value)` — `C4:UpdateProperty` via `call`.
- `log()` — prints when Debug Mode is On; also feeds the developer log ring.

### Discovery (`Agent.refresh`, `Agent.discoverExtras`)
Runs at startup, on the **Refresh Devices** action, and ~2 s after project-change
system events (`OnItemAdded/Removed/NameChanged/Moved`, coalesced by
`scheduleRefresh`). Returns whether anything changed so the catalog revision
only moves when needed.

| Kind | Source of truth |
|---|---|
| Lights | `GetDevices{C4iNames="light_v2.c4i,…"}`; state from variables 1000 (state) / 1001 (level). |
| Fans | `GetDevices{C4iNames="fan.c4i,…"}`; speed count and names from the fan proxy's `GET_SETUP`; on/speed variables found **by name** (`IS_ON`/`CURRENT_SPEED` on X4, the documented names elsewhere). |
| Rooms | `GetProjectItems("LOCATIONS")`, items of type 8. |
| Scenes | Advanced Lighting agent → `SendUIRequest(…, "GET_SCENE_LIST")` → `<scene_info>`; initial on/off from `is_active`, then AL events. |
| Macros | Macros agent → `SendUIRequest(…, "GET_MACROS")`. |
| Watch / Listen | Each room's Navigator lists (`OrderedWatchList` / `OrderedListenList` in the room's project state), visible entries only, names via one `GetDevices{DeviceIds=…}`. |

Anything not documented by Control4 is **probed**: a list of candidate request
names is tried in order, the first that yields records wins, and every attempt
and reply is kept in `Agent.probes` for **Log Project Info** and the developer
tools. Scene/macro/source discovery is wrapped in its own `pcall` so a surprise
there never takes lights and fans down with it.

### State
- Lights and fans: `RegisterVariableListener` (fires once with the current
  value, then on change) → `OnWatchedVariableChanged`.
- Rooms with sources: listen to room variables 1001 (current audio device) and
  1002 (current video device). Watch is *active* when the room's video device is
  that source; Listen is active when the room has **no** video device and its
  audio device is that source (watching also sets the audio device).
- Scenes: `RegisterDeviceEvent` on the AL agent for events `5·id` (activated)
  and `5·id+1` (deactivated) → `OnDeviceEvent`.
- Changes go to `core:stateChanged(kind, id, state)`, which pushes only to Macs
  that watch that item.

### Commands
`platform.command(kind, id, action, msg)` dispatches to:

| Kind | Sends |
|---|---|
| light | `TOGGLE`; on/off as a top/bottom `BUTTON_ACTION` press + release; hold-to-dim as a press, then release on `rampStop`; `SET_BRIGHTNESS_TARGET` for a level |
| fan | `ON`, `OFF`, `TOGGLE`, `SET_SPEED {SPEED}` |
| scene | `ACTIVATE_SCENE` / `DEACTIVATE_SCENE` / `TOGGLE_SCENE {SCENE_ID}` to the AL agent |
| macro | `EXECUTE_MACRO {id}` to the Macros agent |
| watch / listen | `SELECT_VIDEO_DEVICE` / `SELECT_AUDIO_DEVICE {deviceid}` or `ROOM_OFF` to the room |

Results go back as `result` messages; a command never throws past `core.lua`.

### Identifiers
- Lights, fans: the proxy device ID. Scenes: AL scene ID. Macros: macro ID
  (= the Macros agent's event ID).
- Sources: `room × 100000 + device`, so one device in two rooms is two buttons.
  The **same** ID can be both a Watch and a Listen source; internally sources are
  keyed by `kind:id`, and the app keys everything by `(kind, id)`.

### Server, properties, lifecycle
- `C4:CreateServer` on the **Port** property (default 8751); one Lua string per
  connection handle is buffered into lines by `core.lua`.
- `OnDriverLateInit` builds `Core` with injected dependencies (persistence,
  send/close, timers, clock, RNG, log), refreshes, registers project-change
  events, starts the server, sets **Agent Version**, schedules update checks,
  and (developer builds) attaches devtools.
- **Status** property: listening port, connected Macs, and counts of every kind.
- Actions: New Pairing Code, Unpair All Macs, Refresh Devices, Check for Updates,
  Log Project Info.

## core.lua — the protocol engine

- **Clients** keyed by server handle; each must `hello` first.
- **Pairing**: a 6-digit code (shown in Composer) → a 40-hex-char token, stored
  per Mac (`{device, paired}`) in persistence. Five wrong codes lock pairing for
  60 s. Tokens are revocable (**Unpair All**). Rejections are sent *before* the
  connection closes, so the app can show "unauthorized" instead of retrying.
- **Controller ID**: a UUID made on first run and persisted (`hsl.controllerId`).
- **Catalog**: full catalog after `welcome` and whenever discovery reports a
  change; `revision` increases (and restarts bump it) so the app can spot gaps.
- **Watch**: each Mac sends the set of `(kind, id)` on its buttons; the agent
  replies with current state, then pushes changes.
- **Extension hook**: unknown message types go to `deps.extension` — used only by
  developer builds for `{"type":"dev"}`.

Persistence keys (`C4:PersistSetValue`, all prefixed `hsl.`): `controllerId`,
`tokens`, `pairingCode`, `revision`, and `devUntil` (Developer Mode expiry).

## Updates

`updates.lua` asks `api.github.com/repos/<repo>/releases` (no auth) once a minute
after startup and then daily (property **Automatic Update Check**), picks the
highest non-draft release (pre-releases count; its `.c4z` asset is the download), and compares it with
`Core.VERSION`. The result shows in **Update Status**, in `welcome.update`, and as
a live `update` message to connected Macs. Control4 only auto-installs drivers
from its own database, so installs are manual (Composer → Add or Update Driver
or Agent). Versioning: `Core.VERSION` (semantic, e.g. 0.0.6) plus
`driver.xml` `<version>` (an integer build that must increase every release so
Composer replaces the installed agent).

## Developer tools (developer builds only)

A back door for working out what Control4 doesn't document, designed to be safe
to ship in alpha builds:

- Present only in packages built with `scripts/package.sh --dev`; the production
  build strips `devtools.lua` and the `DEV:BEGIN…DEV:END` block of `driver.xml`,
  and the package script verifies they're gone.
- Off by default (**Developer Mode** property); turning it on sets **Developer
  Mode Until** to 7 days later, and an hourly timer turns it off after that.
- Reachable only by **already-paired** Macs, over their authenticated
  connection, and only from the Mac app's **localhost-only** relay
  (127.0.0.1:8760), which `scripts/c4dev` talks to. Nothing new listens on the
  controller's network.
- Ops: `ping`, `call` (any `C4:` function with JSON arguments), `eval` (Lua, with
  a `DEV` table of handy references), `logs` (recent agent log lines). Results are
  made JSON-safe (depth-limited, cycle-safe).

Until 1.0, GitHub releases are developer builds; from 1.0 they'll be production
builds.

## Defensive design, in short

- Every `C4:` call via `call()`; discovery of undocumented things in `pcall`.
- Candidate request names tried in order; replies parsed loosely (element or
  attribute forms, several field spellings).
- Variables matched by name, not fixed IDs, where Control4 doesn't fix them.
- Nothing X4-only is required; OS 3.4 features are the floor.
- Watch out for Lua's `a and b or c` when `b` can be `nil`/`false` — it silently
  picks `c` (this caused a real Watch/Listen state bug).
