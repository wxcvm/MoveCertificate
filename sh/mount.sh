#!/system/bin/sh
MODDIR=${0%/sh/*}
. "$MODDIR/sh/runtime.sh"
init_paths || exit 1
load_runtime_mode || exit 1
mount_in_current_namespace /proc/1/root/mnt/movecertificate
