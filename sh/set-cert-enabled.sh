#!/system/bin/sh
MODDIR=${0%/sh/*}
. "$MODDIR/sh/runtime.sh"
init_paths || exit 1
digest=${1:-}
enabled=${2:-}
printf '%s\n' "$digest" | grep -Eq '^[0-9a-f]{64}$' || exit 1
case "$enabled" in 0|1) ;; *) exit 1 ;; esac
lock_state || exit 1
validate_selections || exit 1
[ -f "$MANIFEST" ] && [ "$(cat "$MODDIR/state/boot_id")" = "$BOOT_ID" ] || exit 1
# Native CAs are protected. Only validated additional certificates can be toggled.
awk -F '\t' -v d="$digest" '$1 == d && ($4 == "pending" || $4 == "disabled" || $4 == "excluded") {found=1} END {exit !found}' "$MANIFEST" || exit 1
work=$(mktemp -d "$MODDIR/.stage.XXXXXX") || exit 1
trap 'remove_stage "$work"' EXIT
if [ -f "$SELECTION_PATH" ]; then
    awk -F '\t' -v d="$digest" '$1 != d' "$SELECTION_PATH" > "$work/selections" || exit 1
else
    : > "$work/selections"
fi
printf '%s\t%s\n' "$digest" "$enabled" >> "$work/selections" || exit 1
chmod 600 "$work/selections" && mv "$work/selections" "$SELECTION_PATH" || exit 1
print_log "Selected migration=$enabled fingerprint=$digest; reboot required (input preserved)"
