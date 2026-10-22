#!/system/bin/sh
# KernelSU/APatch: recheck after the module mount provider has finished.
MODDIR=${0%/*}
. "$MODDIR/sh/runtime.sh"
init_paths && load_runtime_mode || exit 1
[ "$(sed -n 's/^state=//p' "$RUNTIME")" = prepared ] || exit 1
lock_state || exit 1
if ! ns_run 1 /system/bin/sh "$MODDIR/sh/activate.sh"; then
    write_runtime failed post_mount_failed
    print_log 'ERROR: mount verification after module mounting failed'
    exit 1
fi
