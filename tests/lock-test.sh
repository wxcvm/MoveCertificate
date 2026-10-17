#!/bin/sh
# Run with the host shell and with Android /system/bin/sh. Do not mock flock:
# mksh closes persistent descriptors on exec unless explicitly redirected.
ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
WORK=$(mktemp -d) || exit 1
holder=''
cleanup() {
    [ -z "$holder" ] || kill "$holder" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT
mkdir "$WORK/module" || exit 1
cat > "$WORK/holder.sh" <<'SCRIPT'
. "$1/sh/runtime.sh"
MODDIR=$2
lock_state || exit 1
touch "$MODDIR/ready"
while [ ! -e "$MODDIR/release" ]; do sleep 0.1; done
SCRIPT
sh "$WORK/holder.sh" "$ROOT" "$WORK/module" &
holder=$!
attempt=0
while [ ! -e "$WORK/module/ready" ]; do
    kill -0 "$holder" 2>/dev/null || { echo 'FAIL: lock holder exited' >&2; exit 1; }
    attempt=$((attempt + 1))
    [ "$attempt" -lt 50 ] || { echo 'FAIL: lock acquisition timed out' >&2; exit 1; }
    sleep 0.1
done
cat > "$WORK/contender.sh" <<'SCRIPT'
exec 9> "$1"
for binary in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox; do
    [ ! -x "$binary" ] || { "$binary" flock -n 9 9>&9; exit $?; }
done
flock -n 9 9>&9
SCRIPT
if sh "$WORK/contender.sh" "$WORK/module/state.lock"; then
    echo 'FAIL: lock released when flock exited' >&2; exit 1
fi
touch "$WORK/module/release"
wait "$holder" || exit 1
holder=''
sh "$WORK/contender.sh" "$WORK/module/state.lock" || exit 1
echo 'PASS: actual lock persists in shell, excludes a second process and releases on exit'
