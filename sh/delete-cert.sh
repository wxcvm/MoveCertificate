#!/system/bin/sh
MODDIR=${0%/sh/*}
. "$MODDIR/sh/runtime.sh"
init_paths || exit 1
digest=${1:-}
printf '%s\n' "$digest" | grep -Eq '^[0-9a-f]{64}$' || exit 1
[ -f "$MANIFEST" ] || exit 1
# Serialize deletion against preparation. Only input copies are removed; native
# CAs and live mounts are left intact until reboot.
lock_state || exit 1
[ "$(cat "$MODDIR/state/boot_id" 2>/dev/null)" = "$BOOT_ID" ] || exit 1
work=$(mktemp -d "$MODDIR/.stage.XXXXXX") || exit 1
trap 'remove_stage "$work"' EXIT
awk -F '\t' -v d="$digest" '$1 == d' "$MANIFEST" > "$work/rows"
[ -s "$work/rows" ] || exit 1
# Validate every recorded input before deleting any of them. Recheck each
# file immediately before removal; filesystem errors can still prevent completion.
validate_input() {
    local source="$1" status="$2" origin actual
    printf '%s\n' "$source" | grep -Eq '^/data/misc/user/0/cacerts-added/[0-9a-f]{8}\.[0-9]+$|^/data/local/tmp/cert/[A-Za-z0-9][A-Za-z0-9_.-]*$' || return 1
    [ ! -L "$source" ] || return 1
    [ -e "$source" ] || return 0
    [ -f "$source" ] || return 1
    origin=user
    case "$source" in /data/local/tmp/cert/*) origin=custom ;; esac
    if [ "$status" = unverified ]; then
        actual=$(file_digest "$source")
    else
        cert_to_der "$source" "$work/current.der" "$origin" || return 1
        actual=$(file_digest "$work/current.der")
    fi
    [ "$actual" = "$digest" ] || return 1
    return 0
}
while IFS="$(printf '\t')" read -r fingerprint target source status; do
    validate_input "$source" "$status" || exit 1
done < "$work/rows"
while IFS="$(printf '\t')" read -r fingerprint target source status; do
    validate_input "$source" "$status" || exit 1
    [ -e "$source" ] || continue
    rm -f "$source" && [ ! -e "$source" ] || exit 1
done < "$work/rows"
awk -F '\t' -v OFS='\t' -v d="$digest" '{if ($1 == d) $4="removed"; print}' "$MANIFEST" > "$work/manifest"
chmod 600 "$work/manifest" && mv "$work/manifest" "$MANIFEST" || exit 1
print_log "Removed input copies for fingerprint $digest; reboot required"
