#!/system/bin/sh
# Read-only collection: no mounts, repairs, mode changes or certificate dumps.
MODDIR=${0%/sh/*}
. "$MODDIR/sh/runtime.sh"
init_paths && load_runtime_mode || exit 1
namespace_script=$(cat "$MODDIR/sh/namespace.sh") || exit 1
expected_namespace_store=$(namespace_store_manifest) || exit 1
printf 'MoveCertificate namespace diagnostic\nboot_id=%s sdk=%s mode=%s\n' "$BOOT_ID" "$SDK" "$CURRENT_MODE"
seen=' '
for pid in 1 $(pidof zygote zygote64 webview_zygote) $(ps -A -o PID,NAME | awk '$2 ~ /_zygote$/ {print $1}'); do
    namespace=$(readlink "/proc/$pid/ns/mnt" 2>/dev/null) || continue
    case "$seen" in *" $namespace "*) continue ;; esac
    seen="$seen$namespace "
    name=$(process_name "$pid")
    printf '\npid=%s name=%s namespace=%s\n' "$pid" "$name" "$namespace"
    ns_run "$pid" /system/bin/sh -c "$namespace_script" diagnostic \
        verify "$SYSTEM_SOURCE" "$expected_namespace_store" "$CURRENT_MODE" "$namespace"
    printf 'verification_status=%s\n' "$?"
done
