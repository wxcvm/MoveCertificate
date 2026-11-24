#!/system/bin/sh
# KernelSU/APatch: recheck after the module mount provider has finished.
MODDIR=${0%/*}
. "$MODDIR/sh/runtime.sh"
init_paths && lock_state && load_runtime_mode || exit 1
state=$(sed -n 's/^state=//p' "$RUNTIME")
reason=$(sed -n 's/^reason=//p' "$RUNTIME")
case "$state:$reason" in
    prepared:*) ;;
    failed:initial_mount_failed|failed:post_mount_failed)
        print_log "Retrying early mount failure after module mounting: $reason"
        ;;
    *) exit 1 ;;
esac
if [ "$(cat "$MODDIR/state/boot_id" 2>/dev/null)" != "$BOOT_ID" ]; then
    write_runtime failed prepared_boot_mismatch
    print_log 'ERROR: prepared certificate store does not belong to this boot'
    exit 1
fi
if ! ns_run 1 /system/bin/sh "$MODDIR/sh/activate.sh"; then
    write_runtime failed post_mount_failed
    print_log 'ERROR: mount verification after module mounting failed'
    exit 1
fi
# This is not final success: service.sh still verifies the launcher namespaces.
write_runtime prepared || exit 1
print_log 'Post-mount verification passed; final process verification pending'
