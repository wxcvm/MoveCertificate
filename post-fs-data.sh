#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/sh/runtime.sh"
init_paths || exit 1
lock_state || exit 1
printf '[MoveCertificate] Starting boot %s SDK=%s\n' "$BOOT_ID" "$SDK" > "$LOG_PATH"
chmod 600 "$LOG_PATH"
trap 'cp -f "$LOG_PATH" /data/local/tmp/MoveCertificate.log; chmod 600 /data/local/tmp/MoveCertificate.log' EXIT
# A saved builtin choice may fall back after an Android upgrade.
if [ "$CURRENT_MODE" = compatible ]; then
    touch "$MODDIR/skip_mount" || exit 1
else
    rm -f "$MODDIR/skip_mount" || exit 1
fi
write_runtime preparing || exit 1
print_log "Configured=$CONFIGURED_MODE effective=$CURRENT_MODE reason=$MODE_REASON"
if ! prepare_cert_store; then
    write_runtime failed preparation_failed
    print_log 'ERROR: preparation failed; native trust store preserved'
    exit 1
fi
if [ "$CURRENT_MODE" = builtin ]; then
    if ! prepare_builtin; then
        clean_builtin_outputs
        write_runtime failed builtin_preparation_failed
        exit 1
    fi
    write_runtime prepared waiting_for_module_mount
else
    clean_builtin_outputs || { write_runtime failed cleanup_failed; exit 1; }
    write_runtime prepared || exit 1
    if ! ns_run 1 /system/bin/sh "$MODDIR/sh/activate.sh"; then
        write_runtime failed initial_mount_failed
        print_log 'ERROR: initial mount failed; no installation success claimed'
        exit 1
    fi
    print_log 'Initial mount verified; final process verification will run after boot'
fi
