# Developing HSL Keypad

Building, testing, debugging on a real controller, and releasing. Design is in
[ARCHITECTURE.md](ARCHITECTURE.md); controller behaviour in
[CONTROL4-NOTES.md](CONTROL4-NOTES.md); the wire format in
[PROTOCOL.md](../PROTOCOL.md).

## Requirements

- macOS with the Xcode command-line tools (Swift, `xmllint`, `codesign`).
- [LuaJIT](https://luajit.org) — `brew install luajit` (Lua 5.1, same as Control4).
- `gh` (GitHub CLI) for releases.
- Composer Pro on Windows for installing on a controller.
- The HSL Toolbar Mac app (separate, private repository) to pair with the agent.
  Its repo links this one as `Control4/`.

## Layers of testing

| Layer | Command | What it covers |
|---|---|---|
| Unit | `luajit tests/run.lua` | `json`, `core` (pairing, lockout, catalog, watch, commands), `project` (X4 reply/project-XML shapes), `updates` |
| Emulator | `scripts/run-emulator.sh [port]` | The **real** `driver.lua` + `core.lua` against a fake Control4 API, on a TCP port the Mac app can pair with |
| End-to-end | `Scripts/c4-e2e.sh` in the Mac app repo (`Tools/c4-e2e`) | Pairing, catalog, live state, every command kind, project changes, update notice |
| Controller | developer build + `scripts/c4dev` | What Control4 really does (see below) |

`scripts/package.sh` runs the unit tests, compiles every Lua file, and validates
`driver.xml` before it builds anything.

## The emulator

`emulator/bridge.swift` owns the TCP port and timers; `emulator/emulator.lua`
fakes the `C4` API, a small project (3 rooms, lights, a 4-speed fan, an Advanced
Lighting agent, a Macros agent, Watch/Listen sources) and loads the agent's real
files. Its replies copy the **X4 shapes** in CONTROL4-NOTES.md (escaped room
state, `scene_info`, lowercase macro `id`, fan `GET_SETUP`, `IS_ON` names,
`GetDeviceDisplayName` returning nothing).

```sh
scripts/run-emulator.sh            # port 28771; prints the pairing code
```

Pair from HSL Toolbar → Settings → Control4 → **+** → `127.0.0.1`, port `28771`.
Then type into the emulator to simulate the project:

| Command | Effect |
|---|---|
| `level <id> <0-100>` / `fan <id> <speed>` | change a light / fan as if from a wall keypad |
| `scene <id> on\|off` | fire the AL scene event |
| `watch\|listen <room> <device>` / `roomoff <room>` | change a room's source |
| `rename <id> <name>` / `add light\|fan <room> <name>` / `remove <id>` | project changes |
| `action <Command>` / `set <Property> <value>` | Composer actions and properties |
| `eval <lua>` | run Lua inside the emulated agent (e.g. `eval print(Agent.roomMedia[12].video)`) |
| `props`, `help` | |

Environment: `HSL_EMU_PORT`, `HSL_EMU_OS` (reported OS, default 3.4.3.0),
`HSL_EMU_LATEST` (fake latest GitHub release), `HSL_EMU_PRODUCTION` (behave like a
production package), `HSL_EMU_LEGACY` (behave like the legacy package), `HSL_EMU_CODEFILE` (write the pairing code to a file, for
tests).

## Debugging on a real controller

1. Install a **developer build** (`scripts/package.sh --dev`, or any pre-1.0
   GitHub release) and set the agent's **Developer Mode** property to **On**
   (it turns itself off after 7 days).
2. Pair the Mac app with the controller, and turn on Settings → Control4 →
   **Developer relay on this Mac** (listens on 127.0.0.1:8760 only).
3. Use `scripts/c4dev` (builds itself on first run):

```sh
scripts/c4dev list                                   # paired controllers
scripts/c4dev ping                                   # version, Developer Mode expiry
scripts/c4dev call GetVersionInfo                    # any C4: function; args are JSON
scripts/c4dev call SendUIRequest 3 GET_SCENE_LIST '{}'
scripts/c4dev eval 'return DEV.agent.probes'         # Lua on the controller
scripts/c4dev eval - < probe.lua                     # longer scripts from stdin
scripts/c4dev logs 100                               # recent agent log lines
scripts/c4dev -c "Site name" ping                    # pick a controller by name/ID/address
```

`DEV` in `eval` holds `agent` (the `Agent` table: lights, fans, scenes, macros,
sources, probes…), `project`, `updates`, `core`, `json`, and `call`.

Rules of thumb:

- **Read before you write.** Probe with variables, `GetProjectItems`,
  `SendUIRequest`, and `GetAllCodeItems` (the project's own programming shows
  exact command spellings) before sending any command.
- **Anything that changes the house** (running a macro, activating a scene,
  switching a source) — agree on the exact device first, and verify the effect
  by reading state rather than guessing.
- Try new parsing code live before releasing: paste the new `project.lua` into an
  `eval` (wrap it in a function), run it against real replies, compare counts.
- Never put site names, addresses or other private details in this repository.

## Packaging

```sh
scripts/package.sh                   # production → build/HSLKeypad.c4z (no developer tools; verified)
scripts/package.sh --dev             # developer  → build/HSLKeypad-dev.c4z
scripts/package.sh --legacy          # production → build/HSLKeypad-legacy.c4z (OS 3.3.x)
scripts/package.sh --legacy --dev    # developer  → build/HSLKeypad-legacy-dev.c4z
```

A `.c4z` is a zip of `driver.xml`, the Lua files and `www/`. The production
build removes `devtools.lua` and the `DEV:BEGIN…DEV:END` block from
`driver.xml`, then fails if either is still in the package.

### The legacy package (OS 3.3.x)

`--legacy` builds a standalone package for OS 3.3.x from the **same source**.
Nothing in `HSLKeypad/` is forked; the script changes four things in the staged
copy and then checks each one in the finished package:

| What | Standard | Legacy |
|---|---|---|
| `driver.xml` `<minimum_os_version>` | `3.4.0` | `3.3.0` |
| `driver.xml` `<name>` | HSL Keypad | HSL Keypad (Legacy) |
| `flavor.lua` | `HSLKeypad/flavor.lua` | `legacy/flavor.lua` (`legacy = true`, `asset = "HSLKeypad-legacy.c4z"`) |
| `www/documentation.html` | as written | OS line changed; `legacy/note.html` replaces `<!-- LEGACY-NOTE -->` |

`flavor.lua` is the only thing the Lua code looks at: it adds `· legacy` to
**Agent Version** and tells the update check which release file is this
package's. The legacy package ignores releases without `HSLKeypad-legacy.c4z`.

Control4 identifies a driver by its **file name**, so the legacy package must be
installed as `HSLKeypad-legacy.c4z` every time (rename the `-dev` build before
copying it to Composer, as with the standard one). It is a different agent from
`HSLKeypad.c4z`: separate pairings, and only one of them per project.

To try it in the emulator: `HSL_EMU_LEGACY=1 HSL_EMU_OS=3.3.1.0 scripts/run-emulator.sh`.

## Versioning

Two numbers, both bumped every release:

| Where | Example | Purpose |
|---|---|---|
| `HSLKeypad/core.lua` `Core.VERSION` | `0.0.6` | Semantic version: shown in **Agent Version**, sent to the app, compared with GitHub releases |
| `HSLKeypad/driver.xml` `<version>` | `6` | Integer build: Composer only replaces an installed agent with a **higher** one |

Also update the version text in `www/documentation.html`, `README.md` and the
status section of `PROTOCOL.md`.

## Releasing (pre-1.0)

Until 1.0 every release is a **developer build** and a GitHub **prerelease**.

1. Bump both versions; update README, PROTOCOL status, documentation.html.
2. `luajit tests/run.lua`, then the Mac app's `Scripts/c4-e2e.sh` against the
   emulator (update the expected Agent Version string in `Tools/c4-e2e/main.swift`).
3. `scripts/package.sh` (proves production stripping still works),
   `scripts/package.sh --dev` and `scripts/package.sh --legacy --dev`.
4. Check the repo for private details.
5. Commit to `main`, push.
6. Publish, uploading the **developer** packages under the plain names (a
   release without `HSLKeypad-legacy.c4z` is invisible to legacy agents):

   ```sh
   cp build/HSLKeypad-dev.c4z /tmp/rel/HSLKeypad.c4z
   cp build/HSLKeypad-legacy-dev.c4z /tmp/rel/HSLKeypad-legacy.c4z
   gh release create vX.Y.Z /tmp/rel/HSLKeypad.c4z /tmp/rel/HSLKeypad-legacy.c4z --target main --prerelease \
     --title "HSL Keypad X.Y.Z (developer build)" --notes-file notes.md
   ```
7. Confirm with `scripts/c4dev eval 'DEV.agent.checkForUpdates()'` and the
   **Update Status** property that installed agents see it.

The update check uses GitHub's **public** API without credentials, so it only
works while this repository is public.

From 1.0: production packages, normal releases.
