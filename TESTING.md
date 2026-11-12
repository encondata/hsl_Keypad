# HSL Keypad agent — first load on a controller

Start with the **X4** controller, then repeat on **3.4**. Don't upgrade the 3.4
test controller to X4 (going back from 3.4.3+ needs a factory reset).

Download `HSLKeypad.c4z` from the GitHub release (or build it with
`scripts/package.sh`) and copy it to the Windows machine.

## 1. Load it (Composer Pro)

1. Driver → **Add or Update Driver or Agent** → choose `HSLKeypad.c4z`.
2. Open **Agents** → add **HSL Keypad**.
   - Expected: it appears on the Agents tab with the striped **H** icon.
3. Select it and look at **Properties**:
   - **Pairing Code**: six digits.
   - **Status**: `Listening on port 8751 · 0 Macs connected · N lights, M fans`,
     where N and M roughly match the project.
4. Set **Debug Mode** to **On** and keep the **Lua** output tab open.

## 2. Pair the Mac

1. On the Mac: HSL Toolbar → Settings → **Control4** → **+**.
2. Enter the controller's IP address, port **8751**, and the pairing code.
3. Click **Pair & Connect**.
   - Expected: "Connected · agent 0.0.1". **Paired Macs** in Composer shows the
     Mac's name. **Published by the agent** shows rooms, lights and fans.

## 3. Try the keypad

On the Mac, open the H → **Smart Home**. A "Main" page exists. Click **Edit**
and assign:

- a **dimmer**: click (toggle), hold (should ramp, and stop on release),
  right-click (level slider);
- a **switch** light: click;
- a **fan** (if the project has one): click, then check its speed shows.

Also try:

- Change one of those lights from a real keypad or the Control4 app. The
  Mac's button should update within a second.
- Rename a light in Composer. Within a few seconds it should show the new name
  in the Mac's button picker.

## 4. Send back

- The **Status** property text, and whether the **H** icon showed.
- Anything that failed, with the Lua output around it.
- Run the agent's **Log Project Info** action and copy the whole Lua output
  between `==== HSL Keypad: project info ====` and `==== end ====`. It shows
  what this controller exposes for scenes, macros, fan speeds, and
  dimmer-vs-switch, which the public docs don't cover.

## Known limits in 0.0.1

- No Advanced Lighting scenes or macros yet (they need the Log Project Info
  output).
- Every light is treated as dimmable; fans are assumed to have 3 speeds.
- The site name comes from the **Site Name** property, not the project.
