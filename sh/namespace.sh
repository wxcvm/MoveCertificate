#!/system/bin/sh
# This script is passed to sh -c by the caller. It must not reopen module files:
# a zygote namespace may hide /data/adb or the module provider's overlay.
action=$1
target=$2
expected=$3
mode=$4
expected_namespace=${5:-}
source=${6:-}
legacy_target=${7:-}
case "$legacy_target" in ''|/*) ;; *) echo 'reason=invalid_legacy_target'; exit 1 ;; esac

case "$action:$mode" in verify:builtin|verify:compatible|repair:builtin|repair:compatible) ;; *) exit 1 ;; esac
case "$target" in /*) ;; *) exit 1 ;; esac
[ -n "$expected" ] || { echo 'reason=empty_expected_store'; exit 1; }
if [ -n "$expected_namespace" ] && [ "$(readlink /proc/self/ns/mnt)" != "$expected_namespace" ]; then
    echo 'reason=namespace_changed'
    exit 1
fi

verified_directories=' '
check_store() {
    directory=$1
    [ -d "$directory" ] || { echo "reason=directory_missing path=$directory"; return 1; }
    directory_identity=$(stat -L -c '%d:%i' "$directory") || return 1
    # Active APEX aliases often resolve to the identical certificate directory.
    # Hash that object once per invocation; do not cache across namespaces/boots.
    case "$verified_directories" in *" $directory_identity "*) return 0 ;; esac
    printf '%s\n' "$expected" | while read -r digest name extra; do
        hash=${name%.*}; sequence=${name##*.}
        case "$digest" in ''|*[!0-9a-f]*) echo 'reason=invalid_expected_store'; exit 1 ;; esac
        case "$hash" in ''|*[!0-9a-f]*) echo 'reason=invalid_expected_store'; exit 1 ;; esac
        case "$sequence" in ''|*[!0-9]*) echo 'reason=invalid_expected_store'; exit 1 ;; esac
        [ -z "$extra" ] && [ "${#digest}" -eq 64 ] && [ "${#hash}" -eq 8 ] &&
            [ "$name" = "$hash.$sequence" ] || { echo 'reason=invalid_expected_store'; exit 1; }
        [ -f "$directory/$name" ] || { echo "reason=certificate_missing path=$directory name=$name"; exit 1; }
        actual=$(sha256sum "$directory/$name" 2>/dev/null) || {
            echo "reason=certificate_unreadable path=$directory name=$name"; exit 1;
        }
        [ "${actual%% *}" = "$digest" ] || {
            echo "reason=certificate_mismatch path=$directory name=$name"; exit 1;
        }
    done || return 1
    if [ "$mode" = compatible ]; then
        want=$(printf '%s\n' "$expected" | wc -l)
        got=$(ls -1 "$directory" | wc -l)
        [ "$want" -eq "$got" ] || { echo "reason=certificate_count path=$directory expected=$want actual=$got"; return 1; }
    fi
    [ "$(stat -L -c '%d:%i' "$directory")" = "$directory_identity" ] || {
        echo "reason=directory_changed path=$directory"; return 1;
    }
    verified_directories="$verified_directories$directory_identity "
}

check_legacy_preservation() {
    legacy_directory=$1
    legacy_source=$2
    legacy_count=0
    [ -d "$legacy_directory" ] && [ ! -L "$legacy_directory" ] || {
        echo "reason=legacy_directory_unavailable path=$legacy_directory"
        return 1
    }
    for legacy_file in "$legacy_directory"/* "$legacy_directory"/.[!.]* "$legacy_directory"/..?*; do
        [ -e "$legacy_file" ] || [ -L "$legacy_file" ] || continue
        legacy_name=${legacy_file##*/}
        if [ ! -f "$legacy_file" ] || [ -L "$legacy_file" ] ||
           ! printf '%s\n' "$legacy_name" | grep -Eq '^[0-9a-f]{8}\.[0-9]+$' ||
           [ ! -f "$legacy_source/$legacy_name" ] || [ -L "$legacy_source/$legacy_name" ] ||
           ! cmp -s "$legacy_file" "$legacy_source/$legacy_name"; then
            echo "reason=legacy_entry_divergent path=$legacy_directory name=$legacy_name"
            return 1
        fi
        legacy_count=$((legacy_count + 1))
    done
    [ "$legacy_count" -gt 0 ] || {
        echo "reason=legacy_store_empty path=$legacy_directory"
        return 1
    }
    return 0
}
targets=$target
if [ -n "$legacy_target" ] && [ "$legacy_target" != "$target" ]; then
    targets="$targets $legacy_target"
fi
case "$target" in
    */com.android.conscrypt/cacerts)
        parent=${target%/com.android.conscrypt/cacerts}
        identity=$(stat -L -c '%d:%i' "$parent/com.android.conscrypt") || exit 1
        for alias in "$parent"/com.android.conscrypt@*; do
            [ -d "$alias/cacerts" ] || continue
            [ "$(stat -L -c '%d:%i' "$alias")" != "$identity" ] || targets="$targets $alias/cacerts"
        done
        ;;
esac

if [ "$action" = verify ]; then
    for destination in $targets; do check_store "$destination" || exit 1; done
    exit 0
fi

# The caller only requests repair after verifying init. Check the source again
# inside this namespace before any mount. Never synthesize or copy a CA store.
check_store "$source" || { echo 'reason=repair_source_invalid'; exit 1; }
if [ -n "$legacy_target" ] && [ "$legacy_target" != "$target" ]; then
    check_legacy_preservation "$legacy_target" "$source" || exit 1
fi
source_identity=$(stat -L -c '%d:%i' "$source") || exit 1
mounted=''
rollback() {
    for destination in $mounted; do
        umount "$destination" || echo "reason=rollback_failed path=$destination"
    done
}
for destination in $targets; do
    [ -d "$destination" ] || { rollback; echo "reason=directory_missing path=$destination"; exit 1; }
    if [ -n "$legacy_target" ] && [ "$destination" = "$legacy_target" ]; then
        check_legacy_preservation "$destination" "$source" || { rollback; exit 1; }
    fi
    identity=$(stat -L -c '%d:%i' "$destination") || { rollback; exit 1; }
    if [ "$identity" != "$source_identity" ]; then
        mount -o bind "$source" "$destination" || { rollback; echo "reason=bind_failed path=$destination"; exit 1; }
        mounted="$destination $mounted"
    fi
done
for destination in $targets; do
    check_store "$destination" || { rollback; exit 1; }
done
echo 'repair=verified_init_store'
