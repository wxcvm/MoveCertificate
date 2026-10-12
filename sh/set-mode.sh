#!/system/bin/sh
MODDIR=${0%/sh/*}
. "$MODDIR/sh/runtime.sh"
init_paths || exit 1
mode=${1:-}
case "$mode" in compatible|builtin) ;; *) exit 1 ;; esac
if [ "$mode" = builtin ] && [ "$SDK" -ge 36 ]; then
    echo 'builtin is unsupported on Android 16 and newer' >&2
    exit 1
fi
lock_state || exit 1
had_skip=0
[ ! -e "$MODDIR/skip_mount" ] || had_skip=1
if [ "$mode" = compatible ]; then
    touch "$MODDIR/skip_mount" || exit 1
else
    rm -f "$MODDIR/skip_mount" || exit 1
fi
printf 'mode=%s\n' "$mode" > "$MODDIR/mode.conf.tmp" && \
    chmod 600 "$MODDIR/mode.conf.tmp" && mv "$MODDIR/mode.conf.tmp" "$MODDIR/mode.conf" && exit 0
# Roll the framework flag back if publishing the configuration failed.
if [ "$had_skip" -eq 1 ]; then touch "$MODDIR/skip_mount"; else rm -f "$MODDIR/skip_mount"; fi
exit 1
