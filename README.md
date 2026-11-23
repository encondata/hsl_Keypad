<p align="center"><img src="HSLKeypad/www/icons/device/experience_300.png" width="120" alt="HackSpaceLabs H"></p>

# HSL Keypad — Control4 agent

A Control4 **agent** that lets the **HSL Toolbar** Mac app show 12-button
keypads for a project's lights, fans, Advanced Lighting scenes, macros, and each
room's Watch and Listen sources. The Mac assigns the buttons; the agent
publishes what can be assigned, runs commands, and reports state live.

- Runs on **Control4 OS 3.4.x and X4**: one `.c4z`, no LuaSocket, no `io.popen`.
- **OS 3.3.x** has its own standalone package, `HSLKeypad-legacy.c4z` — see
  [Legacy package](#legacy-package-os-33x).
- Installed once per project from Composer Pro's **Agents** tab.
- Local network only (or over a VPN to it). Each Mac pairs once with a
  6-digit code; five wrong codes lock pairing for a minute.

> **Status: 0.0.7 developer build (alpha).** On a Control4 X4: pairing, lights, fans,
> rooms, macros (listed and run), Advanced Lighting scenes and each room's Watch / Listen
> sources are found. New in 0.0.7: the legacy package for OS 3.3.x, not yet run on a
> 3.3 controller — see [TESTING.md](TESTING.md).

## Install

1. Download `HSLKeypad.c4z` from [Releases](../../releases).
2. Composer Pro → Driver → **Add or Update Driver or Agent** → choose the file.
3. Agents → add **HSL Keypad**. Note its **Pairing Code** property.
4. In HSL Toolbar on the Mac: Settings → **Control4** → **+** → the controller's
   IP, port **8751**, and the pairing code → **Pair & Connect**.

## Legacy package (OS 3.3.x)

`HSLKeypad-legacy.c4z` is the same agent built for controllers still on OS 3.3.x
(minimum OS 3.3.0). It installs the same way and shows up on the Agents tab as
**HSL Keypad (Legacy)**; its **Agent Version** ends in `· legacy`.

- Control4 tells drivers apart by file name, so it is a **separate agent** from
  `HSLKeypad.c4z`. Keep the file name, and install only one of the two in a project
  (both listen on port 8751).
- Its update check only counts releases that include `HSLKeypad-legacy.c4z`, and
  upgrades are always that file.
- It keeps working if the controller is later upgraded to 3.4 or X4. Moving to the
  standard package means removing the legacy agent, adding **HSL Keypad**, and
  pairing the Macs again.
- **Not yet run on a 3.3 controller.** Every documented call the agent uses exists
  in 3.3.0, but scenes, macros, Watch / Listen sources and fan speed names rely on
  requests confirmed on X4 only. If any are missing, **Log Project Info** shows why.

## What 0.0.7 does

| | |
|---|---|
| Lights | on, off, toggle, set level, press-and-hold dimming, live level |
| Fans | on, off, toggle, any speed, live speed; each fan's own speed count and names (e.g. Low, Medium, Medium High, High) |
| Advanced Lighting scenes | toggle or activate, live active state |
| Macros | run |
| Watch / Listen | select a room's source, toggle (selected → room off), room off, live state |
| Project changes | devices added, removed, renamed or moved are republished automatically |
| Updates | checks GitHub daily (and on demand) for a newer release; shown in Composer and in the Mac app with a download link |
| Composer | properties: Agent Version, Update Status, Automatic Update Check, Site Name, Port, Pairing Code, Paired Macs, Status, Debug Mode · actions: New Pairing Code, Unpair All Macs, Refresh Devices, Check for Updates, Log Project Info |

Not yet: dimmer-vs-switch detection. Scenes come from the
Advanced Lighting agent (`GET_SCENE_LIST`), macros from the Macros agent (`GET_MACROS`,
run with `EXECUTE_MACRO {id}` — the command Composer's own programming uses), and
Watch / Listen sources from each room's Navigator lists (rooms hidden in Navigator are
skipped). If anything is missing on a controller, **Log Project Info** shows why.

To upgrade, add the new `HSLKeypad.c4z` in Composer the same way — its higher
version number replaces the installed agent in place.
Control4 only auto-updates drivers hosted in its own driver database, so
updates from GitHub are installed by hand.

## Repository

| Path | What |
|---|---|
| `HSLKeypad/` | The agent: `driver.xml`, `driver.lua` (Control4 layer), `project.lua` (discovery), `updates.lua` (GitHub release check), `flavor.lua` (standard or legacy package), `core.lua` (protocol), `json.lua`, `www/` (icons, documentation with the logo) |
| `tests/` | Lua tests — `luajit tests/run.lua` |
| `emulator/` | Runs the real agent on a Mac behind a TCP port (`bridge.swift` + a fake Control4 API in `emulator.lua`) |
| `legacy/` | What differs in the OS 3.3.x package: its `flavor.lua` and documentation note |
| `scripts/package.sh` | Tests, then builds `build/HSLKeypad.c4z` (`--legacy` → `build/HSLKeypad-legacy.c4z`) |
| `scripts/run-emulator.sh` | Starts the emulator for the Mac app to pair with |
| `scripts/c4dev` | Developer commands to an agent (developer builds only) |
| [PROTOCOL.md](PROTOCOL.md) | The app ↔ agent protocol |
| [TESTING.md](TESTING.md) | First-load checklist for a real controller |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the agent is built, and why |
| [docs/CONTROL4-NOTES.md](docs/CONTROL4-NOTES.md) | What Control4 controllers really do (undocumented requests, data shapes) |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Emulator, debugging on a controller, versioning, releases |

## Developer builds

`scripts/package.sh --dev` builds `build/HSLKeypad-dev.c4z` with `devtools.lua` and a
**Developer Mode** property (it switches itself off after 7 days). With it on, a paired
Mac running HSL Toolbar (Settings → Control4 → Developer relay) lets `scripts/c4dev` call
Control4 APIs, run Lua and read logs on the controller — for working out undocumented
calls. The normal `scripts/package.sh` leaves all of this out and verifies it.

**Until 1.0, GitHub releases are developer builds** (Developer Mode is off until you turn
it on, and turns itself off after 7 days). From 1.0, releases will be production builds.

Development needs macOS with the Xcode command-line tools and
[LuaJIT](https://luajit.org) (`brew install luajit`).

---

Copyright © 2026 HackSpaceLabs. All rights reserved.
