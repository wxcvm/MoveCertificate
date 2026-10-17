#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/sh/runtime.sh"
init_paths && load_runtime_mode || exit 1
trap 'cp -f "$LOG_PATH" /data/local/tmp/MoveCertificate.log; chmod 600 /data/local/tmp/MoveCertificate.log' EXIT
# Runtime configuration is a snapshot of this boot, not a newly selected mode.
state=$(sed -n 's/^state=//p' "$RUNTIME")
[ "$state" = prepared ] || [ "$state" = ready ] || exit 1
attempt=0
while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$attempt" -lt 60 ]; do
    sleep 2
    attempt=$((attempt + 1))
done
lock_state || exit 1
if [ "$(getprop sys.boot_completed)" != 1 ]; then
    write_runtime failed boot_timeout
    print_log 'ERROR: boot completion timed out'
    exit 1
fi
if verify_processes; then
    write_runtime ready
    print_log 'Certificates verified in init and zygote namespaces'
else
    write_runtime failed process_verification_failed
    print_log 'ERROR: final namespace verification failed'
    exit 1
fi
