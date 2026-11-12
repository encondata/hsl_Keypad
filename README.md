<p align="center"><img src="HSLKeypad/www/icons/device/experience_300.png" width="120" alt="HackSpaceLabs H"></p>

# HSL Keypad — Control4 agent

A Control4 **agent** that lets the **HSL Toolbar** Mac app show a 12-button
keypad for a project's lights and fans. The Mac assigns the buttons; the agent
publishes what can be assigned, runs commands, and reports state live.

- Runs on **Control4 OS 3.4.x and X4**: one `.c4z`, no LuaSocket, no `io.popen`.
- Installed once per project from Composer Pro's **Agents** tab.
- Local network only (or over a VPN to it). Each Mac pairs once with a
  6-digit code; five wrong codes lock pairing for a minute.

> **Status: 0.0.1, first test build.** Developed and tested on a Mac against an
> emulator running the real agent code. It hasn't been loaded on a real
> controller yet — see [TESTING.md](TESTING.md).

## Install

1. Download `HSLKeypad.c4z` from [Releases](../../releases).
2. Composer Pro → Driver → **Add or Update Driver or Agent** → choose the file.
3. Agents → add **HSL Keypad**. Note its **Pairing Code** property.
4. In HSL Toolbar on the Mac: Settings → **Control4** → **+** → the controller's
   IP, port **8751**, and the pairing code → **Pair & Connect**.

## What 0.0.1 does

| | |
|---|---|
| Lights | on, off, toggle, set level, press-and-hold dimming, live level |
| Fans | on, off, toggle, speed, live speed |
| Project changes | devices added, removed, renamed or moved are republished automatically |
| Composer | properties: Site Name, Port, Pairing Code, Paired Macs, Status, Debug Mode · actions: New Pairing Code, Unpair All Macs, Refresh Devices, Log Project Info |

Not yet: Advanced Lighting scenes and macros, dimmer-vs-switch detection, fan
speed counts. Running **Log Project Info** on a real controller collects what's
needed for these.

## Repository

| Path | What |
|---|---|
| `HSLKeypad/` | The agent: `driver.xml`, `driver.lua` (Control4 layer), `core.lua` (protocol), `json.lua`, `www/` (icons, documentation) |
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
