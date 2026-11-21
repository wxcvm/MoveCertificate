#!/system/bin/sh
MODDIR=${0%/sh/*}
. "$MODDIR/sh/runtime.sh"
init_paths && load_runtime_mode || exit 1
[ "$CURRENT_MODE" = compatible ] || exit 1
[ "$(cat "$MODDIR/state/boot_id" 2>/dev/null)" = "$BOOT_ID" ] || exit 1
# Invoked inside init's mount namespace. Recreate a missing source from the
# already prepared current-boot store; refuse a mismatched live source.
prepare_mount_source && mount_in_current_namespace "$TEMP_DIR"
