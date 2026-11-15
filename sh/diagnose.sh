#!/system/bin/sh
# Read-only collection: no mounts, repairs, mode changes or certificate dumps.
# Optional numeric PIDs include real application processes in the check.
MODDIR=${0%/sh/*}
. "$MODDIR/sh/runtime.sh"
init_paths && load_runtime_mode || exit 1
[ "$(cat "$MODDIR/state/boot_id" 2>/dev/null)" = "$BOOT_ID" ] || {
    printf 'reason=prepared_boot_mismatch\n' >&2
    exit 1
}
namespace_script=$(cat "$MODDIR/sh/namespace.sh") || exit 1
expected_namespace_store=$(namespace_store_manifest) || exit 1
printf 'MoveCertificate namespace diagnostic\nboot_id=%s sdk=%s mode=%s\n' "$BOOT_ID" "$SDK" "$CURRENT_MODE"
printf 'boot_state=%s uptime=%s\n' "$(sed -n 's/^state=//p' "$RUNTIME")" "$(cut -d' ' -f1 /proc/uptime)"
# Report both candidate directories; a Java per-process property can still
# select the legacy store, which a root shell cannot conclusively infer.
report_system_store_paths
seen=' '
result=0
# Preserve the default launcher survey, or examine the requested application
# processes alongside init. Explicit PIDs are never silently deduplicated.
if [ "$#" -eq 0 ]; then
    primary=$(pidof zygote zygote64 2>/dev/null)
    if [ -z "$primary" ]; then
        printf 'reason=primary_zygote_unavailable\n'
        result=1
    fi
    set -- 1 $primary $(pidof webview_zygote 2>/dev/null) $(ps -A -o PID,NAME | awk '$2 ~ /_zygote$/ {print $1}')
    explicit=0
else
    explicit=1
    for pid in "$@"; do
        case "$pid" in ''|0|*[!0-9]*) printf 'reason=invalid_pid\n' >&2; exit 2 ;; esac
    done
    set -- 1 "$@"
fi
for pid in "$@"; do
    namespace=$(readlink "/proc/$pid/ns/mnt" 2>/dev/null) || {
        printf '\npid=%s reason=namespace_unavailable\n' "$pid"
        result=1
        continue
    }
    if [ "$explicit" -eq 0 ]; then
        case "$seen" in *" $namespace "*) continue ;; esac
        seen="$seen$namespace "
    fi
    name=$(process_name "$pid")
    printf '\npid=%s name=%s namespace=%s\n' "$pid" "$name" "$namespace"
    ns_run "$pid" /system/bin/sh -c "$namespace_script" diagnostic \
        verify "$SYSTEM_SOURCE" "$expected_namespace_store" "$CURRENT_MODE" "$namespace"
    status=$?
    printf 'verification_status=%s\n' "$status"
    [ "$status" -eq 0 ] || result=1
done
# This checks the process mount view as root, not its TrustManager/SELinux
# access. A successful result is not proof that an application accepts TLS.
printf '\nnamespace_check_status=%s\n' "$result"
check_certificate_sources
source_result=$?
printf 'source_check_status=%s\n' "$source_result"
# 0 = consistent; 1 = namespace failure or changed inputs; 2 = incomplete check.
[ "$source_result" -ne 2 ] || exit 2
[ "$source_result" -eq 0 ] || result=1
exit "$result"
