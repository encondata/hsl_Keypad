#!/bin/zsh
# Runs the HSL Keypad agent's real Lua code on a Mac as a fake Control4
# controller, so the HSL Toolbar app can pair with it.
#
#   scripts/run-emulator.sh [port]      # default 28771
#
# In HSL Toolbar: Settings → Control4 → + → address 127.0.0.1, the port above,
# and the pairing code printed below. Type commands here to simulate the
# project (try "help"), e.g. "level 345 50", "rename 346 Island", "action UnpairAll".
set -euo pipefail

ROOT=${0:A:h:h}
PORT=${1:-28771}
BIN="$ROOT/build/emulator-bridge"

mkdir -p "$ROOT/build"
if [[ ! -x "$BIN" || "$ROOT/emulator/bridge.swift" -nt "$BIN" ]]; then
  swiftc -swift-version 5 -O -o "$BIN" "$ROOT/emulator/bridge.swift"
fi

HSL_EMU_PORT=$PORT exec "$BIN" "$(command -v luajit)" "$ROOT/emulator/emulator.lua"
