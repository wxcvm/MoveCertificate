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
work=$(mktemp -d "$MODDIR/.stage.XXXXXX") || exit 1
trap 'remove_stage "$work"' EXIT
awk -F '\t' -v d="$digest" '$1 == d' "$MANIFEST" > "$work/rows"
[ -s "$work/rows" ] || exit 1
result=0
while IFS="$(printf '\t')" read -r fingerprint target source status; do
    printf '%s\n' "$source" | grep -Eq '^/data/misc/user/[0-9]+/cacerts-added/[0-9a-f]{8}\.[0-9]+$|^/data/local/tmp/cert/[A-Za-z0-9][A-Za-z0-9_.-]*$' || { result=1; continue; }
    [ ! -L "$source" ] || { result=1; continue; }
    [ -e "$source" ] || continue
    origin=user
    case "$source" in /data/local/tmp/cert/*) origin=custom ;; esac
    if [ "$status" = unverified ]; then
        actual=$(file_digest "$source")
    else
        cert_to_der "$source" "$work/current.der" "$origin" || { result=1; continue; }
        actual=$(file_digest "$work/current.der")
    fi
    [ "$actual" = "$digest" ] || { result=1; continue; }
    rm -f "$source" && [ ! -e "$source" ] || result=1
done < "$work/rows"
[ "$result" -eq 0 ] || exit 1
awk -F '\t' -v OFS='\t' -v d="$digest" '{if ($1 == d) $4="removed"; print}' "$MANIFEST" > "$work/manifest"
chmod 600 "$work/manifest" && mv "$work/manifest" "$MANIFEST" || exit 1
print_log "Removed input copies for fingerprint $digest; reboot required"
