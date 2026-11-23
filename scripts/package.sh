#!/bin/zsh
# Packages the HSL Keypad Control4 agent for Composer Pro
# (Driver → Add or Update Driver or Agent).
#
#   scripts/package.sh                   # production → build/HSLKeypad.c4z
#   scripts/package.sh --dev             # developer  → build/HSLKeypad-dev.c4z
#   scripts/package.sh --legacy          # production → build/HSLKeypad-legacy.c4z
#   scripts/package.sh --legacy --dev    # developer  → build/HSLKeypad-legacy-dev.c4z
#
# Production builds leave out devtools.lua and the driver.xml block between
# DEV:BEGIN / DEV:END (Developer Mode), then check the package to prove it.
# Until 1.0, GitHub releases use the --dev build; from 1.0, production builds.
#
# --legacy builds the standalone package for OS 3.3.x from the same source:
# minimum OS 3.3.0, named "HSL Keypad (Legacy)", with legacy/flavor.lua as
# flavor.lua (so it only follows HSLKeypad-legacy.c4z releases) and
# legacy/note.html in the documentation. Control4 tells drivers apart by file
# name, so install it as HSLKeypad-legacy.c4z — a separate agent from
# HSLKeypad.c4z.
#
# Checks first: the Lua tests pass, every Lua file compiles, and driver.xml
# is well-formed. Needs luajit (brew install luajit) and xmllint (macOS).
set -euo pipefail

ROOT=${0:A:h:h}
SRC="$ROOT/HSLKeypad"
DEV=false
LEGACY=false
for arg in "$@"; do
  case "$arg" in
    --dev) DEV=true ;;
    --legacy) LEGACY=true ;;
    *) echo "usage: scripts/package.sh [--dev] [--legacy]" >&2; exit 2 ;;
  esac
done

NAME=HSLKeypad
MIN_OS=3.4.0
ASSET=HSLKeypad.c4z
if $LEGACY; then NAME="$NAME-legacy"; MIN_OS=3.3.0; ASSET=HSLKeypad-legacy.c4z; fi
if $DEV; then NAME="$NAME-dev"; fi
OUT="$ROOT/build/$NAME.c4z"

cd "$ROOT"
luajit tests/run.lua
for f in "$SRC"/*.lua "$ROOT"/legacy/*.lua; do luajit -bl "$f" >/dev/null; done
xmllint --noout "$SRC/driver.xml"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp "$SRC"/*.lua "$STAGE"/
cp -R "$SRC"/www "$STAGE"/www
cp "$SRC"/driver.xml "$STAGE"/driver.xml
find "$STAGE" -name .DS_Store -delete
if ! $DEV; then
  rm -f "$STAGE"/devtools.lua
  perl -0pi -e 's/[ \t]*<!-- DEV:BEGIN.*?<!-- DEV:END -->\n//gs' "$STAGE"/driver.xml
fi
if $LEGACY; then
  cp "$ROOT"/legacy/flavor.lua "$STAGE"/flavor.lua
  perl -pi -e '
    s{<minimum_os_version>3\.4\.0</minimum_os_version>}{<minimum_os_version>3.3.0</minimum_os_version>};
    s{<name>HSL Keypad</name>}{<name>HSL Keypad (Legacy)</name>};
    s{Runs on OS 3\.4\.x and X4:}{Legacy package for OS 3.3.x:};
  ' "$STAGE"/driver.xml
  NOTE="$ROOT/legacy/note.html" perl -0pi -e '
    BEGIN { local $/; open my $f, "<", $ENV{NOTE} or die "legacy/note.html: $!"; $note = <$f> }
    s/OS 3\.4\.x and X4/OS 3.3.x · legacy package/;
    s/<!-- LEGACY-NOTE -->\n/$note/;
  ' "$STAGE"/www/documentation.html
fi
xmllint --noout "$STAGE"/driver.xml

mkdir -p "$ROOT/build"
rm -f "$OUT"
# -X: no macOS extended attributes; -D: no directory entries.
(cd "$STAGE" && zip -q -X -r -D "$OUT" driver.xml *.lua www)

fail() {
  echo "ERROR: $1" >&2
  rm -f "$OUT"
  exit 1
}

if ! $DEV; then
  # Prove the developer tools are absent from the production package.
  if unzip -l "$OUT" | grep -q "devtools.lua" || unzip -p "$OUT" driver.xml | grep -q "Developer Mode"; then
    fail "developer tools leaked into the production package"
  fi
  echo "Verified: no developer tools in the production package"
fi

# Prove the package is the flavor that was asked for.
unzip -p "$OUT" driver.xml | grep -q "<minimum_os_version>$MIN_OS</minimum_os_version>" \
  || fail "driver.xml doesn't declare minimum OS $MIN_OS"
unzip -p "$OUT" flavor.lua | grep -q "asset = \"$ASSET\"" \
  || fail "flavor.lua doesn't name $ASSET"
if $LEGACY; then
  unzip -p "$OUT" driver.xml | grep -q "<name>HSL Keypad (Legacy)</name>" \
    || fail "driver.xml isn't named HSL Keypad (Legacy)"
  unzip -p "$OUT" www/documentation.html | grep -q "Legacy package for OS 3.3.x" \
    || fail "the legacy note is missing from the documentation"
  echo "Verified: legacy package (minimum OS $MIN_OS, follows $ASSET)"
else
  if unzip -p "$OUT" driver.xml www/documentation.html | grep -qi "legacy package"; then
    fail "legacy text leaked into the standard package"
  fi
  echo "Verified: standard package (minimum OS $MIN_OS, follows $ASSET)"
fi

echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
unzip -l "$OUT" | tail -n +2
