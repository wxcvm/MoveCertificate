#!/bin/sh
# Execute the actual launcher in isolated directories, with every mount mocked.
ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
sed '/^MODDIR=/d' "$ROOT/driver-fix/post-fs-data.sh" > "$WORK/launcher.sh"
mount() { echo unexpected-mount >&2; return 99; }
mkdir "$WORK/off" "$WORK/on"
cp "$ROOT/driver-fix/driver.conf" "$WORK/off/driver.conf"
( MODDIR="$WORK/off"; . "$WORK/launcher.sh" ) || exit 1
printf 'enable_global=1\n' > "$WORK/on/driver.conf"
if ( MODDIR="$WORK/on"; . "$WORK/launcher.sh" ); then
    echo 'FAIL: missing binary accepted' >&2; exit 1
fi
grep -q 'OEM driver preserved' "$WORK/on/driver.log" || exit 1
sh "$ROOT/driver-fix/uninstall.sh" || exit 1
printf 'PASS: PanVK defaults to OEM; missing optional binary fails; uninstall is inert\n'
