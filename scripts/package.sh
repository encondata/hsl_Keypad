#!/bin/zsh
# Packages the HSL Keypad Control4 agent into build/HSLKeypad.c4z for
# Composer Pro (Driver → Add or Update Driver or Agent).
#
#   scripts/package.sh
#
# Checks first: the Lua tests pass, every Lua file compiles, and driver.xml
# is well-formed. Needs luajit (brew install luajit) and xmllint (macOS).
set -euo pipefail

ROOT=${0:A:h:h}
SRC="$ROOT/HSLKeypad"
OUT="$ROOT/build/HSLKeypad.c4z"

cd "$ROOT"
luajit tests/run.lua
for f in "$SRC"/*.lua; do luajit -bl "$f" >/dev/null; done
xmllint --noout "$SRC/driver.xml"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp "$SRC"/driver.xml "$SRC"/*.lua "$STAGE"/
cp -R "$SRC"/www "$STAGE"/www
find "$STAGE" -name .DS_Store -delete

mkdir -p "$ROOT/build"
rm -f "$OUT"
# -X: no macOS extended attributes; -D: no directory entries.
(cd "$STAGE" && zip -q -X -r -D "$OUT" driver.xml *.lua www)
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
unzip -l "$OUT" | tail -n +2
