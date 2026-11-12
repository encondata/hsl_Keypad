<p align="center"><img src="HSLKeypad/www/icons/device/experience_300.png" width="120" alt="HackSpaceLabs H"></p>

# HSL Keypad — Control4 agent

A Control4 **agent** that lets the **HSL Toolbar** Mac app show 12-button
keypads for a project's lights, fans, Advanced Lighting scenes, macros, and each
room's Watch and Listen sources. The Mac assigns the buttons; the agent
publishes what can be assigned, runs commands, and reports state live.

- Runs on **Control4 OS 3.4.x and X4**: one `.c4z`, no LuaSocket, no `io.popen`.
- Installed once per project from Composer Pro's **Agents** tab.
- Local network only (or over a VPN to it). Each Mac pairs once with a
  6-digit code; five wrong codes lock pairing for a minute.

> **Status: 0.0.3 test build.** Lights and fans are confirmed on a Control4 X4
> controller. Scenes, macros and Watch/Listen (0.0.2) and update checks (0.0.3)
> are tested against the emulator only — see [TESTING.md](TESTING.md).

## Install

1. Download `HSLKeypad.c4z` from [Releases](../../releases).
2. Composer Pro → Driver → **Add or Update Driver or Agent** → choose the file.
3. Agents → add **HSL Keypad**. Note its **Pairing Code** property.
4. In HSL Toolbar on the Mac: Settings → **Control4** → **+** → the controller's
   IP, port **8751**, and the pairing code → **Pair & Connect**.

## What 0.0.3 does

| | |
|---|---|
| Lights | on, off, toggle, set level, press-and-hold dimming, live level |
| Fans | on, off, toggle, speed, live speed |
| Advanced Lighting scenes | toggle or activate, live active state |
| Macros | run |
| Watch / Listen | select a room's source, toggle (selected → room off), room off, live state |
| Project changes | devices added, removed, renamed or moved are republished automatically |
| Updates | checks GitHub daily (and on demand) for a newer release; shown in Composer and in the Mac app with a download link |
| Composer | properties: Agent Version, Update Status, Automatic Update Check, Site Name, Port, Pairing Code, Paired Macs, Status, Debug Mode · actions: New Pairing Code, Unpair All Macs, Refresh Devices, Check for Updates, Log Project Info |

Not yet: dimmer-vs-switch detection and fan speed counts. Scenes, macros and
sources are *listed* using request names Control4 doesn't document; if any are
missing on a controller, its **Log Project Info** output shows why.

To upgrade, add the new `HSLKeypad.c4z` in Composer the same way — its higher
version number replaces the installed agent in place.
Control4 only auto-updates drivers hosted in its own driver database, so
updates from GitHub are installed by hand.

## Repository

| Path | What |
|---|---|
| `HSLKeypad/` | The agent: `driver.xml`, `driver.lua` (Control4 layer), `project.lua` (discovery), `updates.lua` (GitHub release check), `core.lua` (protocol), `json.lua`, `www/` (icons, documentation with the logo) |
| `tests/` | Lua tests — `luajit tests/run.lua` |
| `emulator/` | Runs the real agent on a Mac behind a TCP port (`bridge.swift` + a fake Control4 API in `emulator.lua`) |
| `scripts/package.sh` | Tests, then builds `build/HSLKeypad.c4z` |
| `scripts/run-emulator.sh` | Starts the emulator for the Mac app to pair with |
| [PROTOCOL.md](PROTOCOL.md) | The app ↔ agent protocol |
| [TESTING.md](TESTING.md) | First-load checklist for a real controller |

Development needs macOS with the Xcode command-line tools and
[LuaJIT](https://luajit.org) (`brew install luajit`).

---

Copyright © 2026 HackSpaceLabs. All rights reserved.
