#!/system/bin/sh
MODDIR=${0%/sh/*}
. "$MODDIR/sh/runtime.sh"
init_paths && load_runtime_mode || exit 1
if [ "$CURRENT_MODE" = compatible ]; then
    prepare_mount_source && mount_in_current_namespace "$TEMP_DIR"
else
    verify_cert_mount "$SYSTEM_SOURCE" builtin
fi
