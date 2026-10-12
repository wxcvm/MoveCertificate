#!/system/bin/sh
MODDIR=${0%/sh/*}
. "$MODDIR/sh/runtime.sh"
fail() { printf 'MoveCertificate: %s\n' "$1" >&2; exit 1; }
init_paths || fail 'Cannot read module paths or Android version'
digest=${1:-}
enabled=${2:-}
printf '%s\n' "$digest" | grep -Eq '^[0-9a-f]{64}$' || fail 'Invalid certificate fingerprint'
case "$enabled" in 0|1) ;; *) fail 'Selection must be 0 or 1' ;; esac
lock_state || fail 'Cannot acquire module state lock'
validate_selections || fail 'Saved certificate selections are invalid'
[ -f "$MANIFEST" ] && [ "$(cat "$MODDIR/state/boot_id")" = "$BOOT_ID" ] || fail 'Current boot certificate records unavailable; reboot required'
# Native CAs are protected. Only validated additional certificates can be toggled.
awk -F '\t' -v d="$digest" '$1 == d && ($4 == "pending" || $4 == "disabled" || $4 == "excluded") {found=1} END {exit !found}' "$MANIFEST" || fail 'Certificate is absent or protected from migration changes'
work=$(mktemp -d "$MODDIR/.stage.XXXXXX") || fail 'Cannot create temporary selection file'
trap 'remove_stage "$work"' EXIT
if [ -f "$SELECTION_PATH" ]; then
    awk -F '\t' -v d="$digest" '$1 != d' "$SELECTION_PATH" > "$work/selections" || fail 'Cannot read saved selections'
else
    : > "$work/selections"
fi
printf '%s\t%s\n' "$digest" "$enabled" >> "$work/selections" || fail 'Cannot write selection'
chmod 600 "$work/selections" && mv "$work/selections" "$SELECTION_PATH" || fail 'Cannot publish selection'
print_log "Selected migration=$enabled fingerprint=$digest; reboot required (input preserved)"
