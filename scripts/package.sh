#!/bin/zsh
# Packages the HSL Keypad Control4 agent for Composer Pro
# (Driver → Add or Update Driver or Agent).
#
#   scripts/package.sh          # production → build/HSLKeypad.c4z
#   scripts/package.sh --dev    # developer  → build/HSLKeypad-dev.c4z
#
# Production builds leave out devtools.lua and the driver.xml block between
# DEV:BEGIN / DEV:END (Developer Mode), then check the package to prove it.
# Until 1.0, GitHub releases use the --dev build; from 1.0, production builds.
#
# Checks first: the Lua tests pass, every Lua file compiles, and driver.xml
# is well-formed. Needs luajit (brew install luajit) and xmllint (macOS).
set -euo pipefail

ROOT=${0:A:h:h}
SRC="$ROOT/HSLKeypad"
DEV=false
[[ "${1:-}" == "--dev" ]] && DEV=true
if $DEV; then OUT="$ROOT/build/HSLKeypad-dev.c4z"; else OUT="$ROOT/build/HSLKeypad.c4z"; fi

cd "$ROOT"
luajit tests/run.lua
for f in "$SRC"/*.lua; do luajit -bl "$f" >/dev/null; done
xmllint --noout "$SRC/driver.xml"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp "$SRC"/*.lua "$STAGE"/
cp -R "$SRC"/www "$STAGE"/www
find "$STAGE" -name .DS_Store -delete
if $DEV; then
  cp "$SRC"/driver.xml "$STAGE"/driver.xml
else
  rm -f "$STAGE"/devtools.lua
  perl -0pe 's/[ \t]*<!-- DEV:BEGIN.*?<!-- DEV:END -->\n//gs' "$SRC"/driver.xml > "$STAGE"/driver.xml
  xmllint --noout "$STAGE"/driver.xml
fi

mkdir -p "$ROOT/build"
rm -f "$OUT"
# -X: no macOS extended attributes; -D: no directory entries.
(cd "$STAGE" && zip -q -X -r -D "$OUT" driver.xml *.lua www)

if ! $DEV; then
  # Prove the developer tools are absent from the production package.
  if unzip -l "$OUT" | grep -q "devtools.lua" || unzip -p "$OUT" driver.xml | grep -q "Developer Mode"; then
    echo "ERROR: developer tools leaked into the production package" >&2
    rm -f "$OUT"
    exit 1
  fi
  echo "Verified: no developer tools in the production package"
fi

echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
unzip -l "$OUT" | tail -n +2
