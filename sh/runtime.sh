#!/system/bin/sh
# Shared library. Sourcing this file must not modify the device.

init_paths() {
    [ -n "${MODDIR:-}" ] && [ "$MODDIR" != / ] && [ -d "$MODDIR" ] || return 1
    SDK=$(getprop ro.build.version.sdk)
    case "$SDK" in ''|*[!0-9]*) return 1 ;; esac
    BOOT_ID=$(cat /proc/sys/kernel/random/boot_id) || return 1
    MODULE_CERT_DIR="$MODDIR/state/certs"
    MANIFEST="$MODDIR/state/certificate-sources.tsv"
    RUNTIME="$MODDIR/runtime.conf"
    LOG_PATH="$MODDIR/install.log"
    CUSTOM_CERT_DIR=/data/local/tmp/cert
    SYSTEM_CERT_DIR=/system/etc/security/cacerts
    APEX_CERT_DIR=/apex/com.android.conscrypt/cacerts
    TEMP_DIR=/mnt/movecertificate
    SYSTEM_SOURCE="$SYSTEM_CERT_DIR"
    [ "$SDK" -lt 34 ] || SYSTEM_SOURCE="$APEX_CERT_DIR"
    CONFIGURED_MODE=compatible
    if [ -f "$MODDIR/mode.conf" ]; then
        value=$(sed -n 's/^[[:space:]]*mode[[:space:]]*=[[:space:]]*//p' "$MODDIR/mode.conf" | head -n1 | tr -d '\r' | sed 's/[[:space:]]*$//')
        case "$value" in builtin|compatible) CONFIGURED_MODE="$value" ;; esac
    fi
    CURRENT_MODE="$CONFIGURED_MODE"
    MODE_REASON=none
    if [ "$SDK" -ge 36 ] && [ "$CURRENT_MODE" = builtin ]; then
        CURRENT_MODE=compatible
        MODE_REASON=builtin_unsupported_sdk
    fi
    CERT_OPENSSL=$(command -v openssl 2>/dev/null)
    return 0
}

print_log() { printf '[MoveCertificate] %s\n' "$*" >> "$LOG_PATH"; }

write_runtime() {
    local state="$1" reason="${2:-none}"
    {
        printf 'boot_id=%s\nconfigured_mode=%s\neffective_mode=%s\nmode_reason=%s\nstate=%s\nreason=%s\n' \
            "$BOOT_ID" "$CONFIGURED_MODE" "$CURRENT_MODE" "$MODE_REASON" "$state" "$reason"
    } > "$RUNTIME.tmp" && chmod 600 "$RUNTIME.tmp" && mv -f "$RUNTIME.tmp" "$RUNTIME"
}

valid_cert_name() { printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{8}\.[0-9]+$'; }

# Fingerprints use canonical DER, so PEM and DER copies of the same CA deduplicate.
# Android already validates user-store certificates. Untrusted custom files need
# a real X.509 parser; do not guess from one ASN.1 byte when openssl is unavailable.
cert_to_der() {
    local input="$1" output="$2" origin="${3:-system}" byte
    [ -f "$input" ] && [ ! -L "$input" ] && [ -s "$input" ] || return 1
    if [ -n "$CERT_OPENSSL" ]; then
        "$CERT_OPENSSL" x509 -in "$input" -outform DER -out "$output" 2>/dev/null || \
            "$CERT_OPENSSL" x509 -inform DER -in "$input" -outform DER -out "$output" 2>/dev/null || return 1
        if [ "$origin" = custom ]; then
            "$CERT_OPENSSL" x509 -inform DER -in "$output" -text -noout 2>/dev/null | grep -q 'CA:TRUE' || return 1
        fi
    else
        [ "$origin" != custom ] || return 2
        if grep -q -- '-----BEGIN CERTIFICATE-----' "$input"; then
            sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$input" | \
                sed '1d;$d' | tr -d '\r\n ' | base64 -d > "$output" || return 1
        else
            cp -f "$input" "$output" || return 1
        fi
    fi
    byte=$(od -An -tx1 -N1 "$output" | tr -d ' \n')
    [ "$byte" = 30 ] && [ -s "$output" ]
}

file_digest() { sha256sum "$1" | cut -d' ' -f1; }

prepare_cert_store() {
    local stage input name hash digest target index prior rc owner origin user_dir original_count=0
    prior="$MODDIR/.state.previous"
    if [ -d "$prior" ]; then
        if [ -d "$MODDIR/state" ]; then rm -rf "$prior"; else mv "$prior" "$MODDIR/state"; fi
    fi
    stage=$(mktemp -d "$MODDIR/.stage.XXXXXX") || return 1
    mkdir -p "$stage/certs" || return 1
    : > "$stage/sources.tsv"
    : > "$stage/index.tsv"
    : > "$stage/system.txt"
    printf '%s\n' "$BOOT_ID" > "$stage/boot_id"
    # A fresh boot must read the native store, never the historical module cache.
    for input in "$SYSTEM_SOURCE"/*; do
        [ -f "$input" ] || continue
        name=${input##*/}
        valid_cert_name "$name" || continue
        if ! cert_to_der "$input" "$stage/current.der" system; then
            print_log "ERROR: cannot read native certificate $input"
            remove_stage "$stage"
            return 1
        fi
        digest=$(file_digest "$stage/current.der")
        cp -p "$input" "$stage/certs/$name" || { remove_stage "$stage"; return 1; }
        printf '%s\t%s\n' "$digest" "$name" >> "$stage/index.tsv"
        printf '%s\n' "$name" >> "$stage/system.txt"
        original_count=$((original_count + 1))
    done
    if [ "$original_count" -eq 0 ]; then
        print_log "ERROR: native trust store is empty; refusing to replace it"
        remove_stage "$stage"
        return 1
    fi
    # Validate native hash sequences before adding any files.
    for input in "$stage/certs"/*; do
        name=${input##*/}; hash=${name%.*}; index=${name##*.}
        [ "$index" -eq 0 ] || [ -f "$stage/certs/$hash.$((index - 1))" ] || {
            print_log "ERROR: native hash sequence has a gap: $name"
            remove_stage "$stage"; return 1
        }
    done
    for user_dir in ${USER_CERT_DIRS:-/data/misc/user/*/cacerts-added} "$CUSTOM_CERT_DIR"; do
        [ -d "$user_dir" ] || continue
        origin=user
        [ "$user_dir" != "$CUSTOM_CERT_DIR" ] || origin=custom
        for input in "$user_dir"/*; do
            [ -f "$input" ] && [ ! -L "$input" ] || continue
            name=${input##*/}
            if [ "$origin" = user ]; then
                valid_cert_name "$name" || { print_log "SKIP invalid user filename: $input"; continue; }
            else
                printf '%s\n' "$name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]*$' || continue
                owner=$(stat -c '%u' "$input")
                [ "$owner" = 0 ] || { print_log "SKIP non-root custom file: $input"; continue; }
            fi
            cert_to_der "$input" "$stage/current.der" "$origin"
            rc=$?
            if [ "$rc" -ne 0 ]; then
                digest=$(file_digest "$input")
                printf '%s\t-\t%s\t%s\n' "$digest" "$input" "unverified" >> "$stage/sources.tsv"
                print_log "SKIP $input: X.509 validation unavailable or failed (status=$rc); input preserved"
                continue
            fi
            digest=$(file_digest "$stage/current.der")
            hash=${name%.*}
            if [ -n "$CERT_OPENSSL" ]; then
                hash=$("$CERT_OPENSSL" x509 -inform DER -in "$stage/current.der" -subject_hash_old -noout) || { remove_stage "$stage"; return 1; }
            fi
            printf '%s\n' "$hash" | grep -Eq '^[0-9a-f]{8}$' || { remove_stage "$stage"; return 1; }
            if [ "$hash" = 47ec1af8 ] && grep -aq 'Guard Personal Intermediate\|AdGuard Intermediate CA' "$stage/current.der"; then
                printf '%s\t-\t%s\texcluded\n' "$digest" "$input" >> "$stage/sources.tsv"
                print_log "EXCLUDED AdGuard intermediate: $input (root CA remains eligible)"
                continue
            fi
            target=$(awk -F '\t' -v d="$digest" '$1 == d {print $2; exit}' "$stage/index.tsv")
            if [ -z "$target" ]; then
                index=0
                while [ -e "$stage/certs/$hash.$index" ]; do index=$((index + 1)); done
                target="$hash.$index"
                # Hashed CA directories are also read by PEM-only consumers.
                # DER is only the fingerprint representation, never the output format.
                { printf '%s\n' '-----BEGIN CERTIFICATE-----'; base64 "$stage/current.der";
                  printf '%s\n' '-----END CERTIFICATE-----'; } > "$stage/certs/$target" || { remove_stage "$stage"; return 1; }
                printf '%s\t%s\n' "$digest" "$target" >> "$stage/index.tsv"
            fi
            printf '%s\t%s\t%s\tpending\n' "$digest" "$target" "$input" >> "$stage/sources.tsv"
        done
    done
    # Recheck every original file byte-for-byte before publishing the new set.
    while IFS= read -r name; do
        cmp -s "$SYSTEM_SOURCE/$name" "$stage/certs/$name" || { remove_stage "$stage"; return 1; }
    done < "$stage/system.txt"
    if ! set_cert_permissions "$stage/certs" "$SYSTEM_SOURCE"; then
        remove_stage "$stage"; return 1
    fi
    mv "$stage/sources.tsv" "$stage/certificate-sources.tsv" && \
        mv "$stage/system.txt" "$stage/system_certs.txt" && \
        chmod 600 "$stage/certificate-sources.tsv" "$stage/system_certs.txt" || { remove_stage "$stage"; return 1; }
    rm -f "$stage/current.der" "$stage/index.tsv"
    if [ -d "$MODDIR/state" ]; then mv "$MODDIR/state" "$prior" || { remove_stage "$stage"; return 1; }; fi
    if ! mv "$stage" "$MODDIR/state"; then
        [ ! -d "$prior" ] || mv "$prior" "$MODDIR/state"
        remove_stage "$stage"; return 1
    fi
    [ ! -d "$prior" ] || rm -rf "$prior"
    remove_stage "$stage"
    print_log "Prepared trust store: native=$original_count total=$(ls -1 "$MODULE_CERT_DIR" | wc -l)"
    return 0
}

remove_stage() {
    case "$1" in "$MODDIR"/.stage.*) [ ! -L "$1" ] && rm -rf "$1" ;; *) return 1 ;; esac
}

set_cert_permissions() {
    local directory="$1" reference="$2" context file
    chown -R root:root "$directory" && chmod 755 "$directory" || return 1
    for file in "$directory"/*; do chmod 644 "$file" || return 1; done
    if [ "$(getenforce)" = Enforcing ]; then
        context=$(ls -Zd "$reference" | awk '{print $1}')
        case "$context" in u:object_r:*:s0*) ;; *) context=u:object_r:system_security_cacerts_file:s0 ;; esac
        chcon -R "$context" "$directory" || return 1
    fi
}

# Compare the complete set and file contents. builtin overlays may contain extra
# native files; bind mounts must contain exactly the prepared set.
verify_cert_mount() {
    local target="$1" mode="${2:-$CURRENT_MODE}" file name want got
    [ -d "$target" ] && [ -d "$MODULE_CERT_DIR" ] || return 1
    want=$(ls -1 "$MODULE_CERT_DIR" | wc -l)
    [ "$want" -gt 0 ] || return 1
    for file in "$MODULE_CERT_DIR"/*; do
        name=${file##*/}
        [ -f "$file" ] && cmp -s "$file" "$target/$name" || return 1
    done
    if [ "$mode" = compatible ]; then
        got=$(ls -1 "$target" | wc -l)
        [ "$got" -eq "$want" ] || return 1
    fi
    return 0
}

ns_run() {
    local pid="$1" target self binary actual
    shift
    target=$(readlink "/proc/$pid/ns/mnt") || return 1
    self=$(readlink /proc/self/ns/mnt) || return 1
    if [ "$target" = "$self" ]; then "$@"; return $?; fi
    for binary in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox; do
        [ -x "$binary" ] || continue
        actual=$("$binary" nsenter -t "$pid" -m -- readlink /proc/self/ns/mnt 2>/dev/null)
        if [ "$actual" = "$target" ]; then "$binary" nsenter -t "$pid" -m -- "$@"; return $?; fi
    done
    if [ -x /system/bin/toybox ]; then
        actual=$(/system/bin/toybox nsenter -t "$pid" -m -- readlink /proc/self/ns/mnt 2>/dev/null)
        if [ "$actual" = "$target" ]; then /system/bin/toybox nsenter -t "$pid" -m -- "$@"; return $?; fi
    fi
    return 1
}

prepare_mount_source() {
    local file source_id mounted_id
    mkdir -p "$TEMP_DIR" || return 1
    if ! grep -q " $TEMP_DIR " /proc/self/mountinfo; then mount -t tmpfs -o mode=0755 tmpfs "$TEMP_DIR" || return 1; fi
    # Refuse to rebuild a source that already has a different live certificate set.
    if [ -n "$(ls -A "$TEMP_DIR")" ]; then verify_cert_mount "$TEMP_DIR" compatible; return $?; fi
    for file in "$MODULE_CERT_DIR"/*; do cp -p "$file" "$TEMP_DIR/" || { umount "$TEMP_DIR"; return 1; }; done
    set_cert_permissions "$TEMP_DIR" "$SYSTEM_SOURCE" && verify_cert_mount "$TEMP_DIR" compatible || {
        umount "$TEMP_DIR"; return 1
    }
}

mount_in_current_namespace() {
    local source="$1" target source_id target_id targets directory apex_identity
    targets="$SYSTEM_SOURCE"
    if [ "$SDK" -ge 34 ]; then
        apex_identity=$(stat -c '%d:%i' /apex/com.android.conscrypt) || return 1
        for directory in /apex/com.android.conscrypt@*; do
            [ -d "$directory/cacerts" ] || continue
            if [ "$(stat -c '%d:%i' "$directory")" = "$apex_identity" ]; then
                targets="$targets $directory/cacerts"
            fi
        done
    fi
    if [ "$CURRENT_MODE" = builtin ]; then verify_cert_mount "$SYSTEM_SOURCE" builtin; return $?; fi
    [ -d "$source" ] && [ -d "$SYSTEM_SOURCE" ] || return 1
    source_id=$(stat -c '%d:%i' "$source") || return 1
    for target in $targets; do
        [ -d "$target" ] || return 1
        target_id=$(stat -c '%d:%i' "$target") || return 1
        if [ "$source_id" != "$target_id" ]; then
            mount -o bind "$source" "$target" || return 1
            verify_cert_mount "$target" compatible || { umount "$target"; return 1; }
        else
            verify_cert_mount "$target" compatible || return 1
        fi
    done
    return 0
}

prepare_builtin() {
    local destination file destinations directory apex_identity
    clean_builtin_outputs || return 1
    destinations="$MODDIR/system/etc/security/cacerts"
    if [ "$SDK" -ge 34 ]; then
        destinations="$MODDIR/apex/com.android.conscrypt/cacerts"
        apex_identity=$(stat -c '%d:%i' /apex/com.android.conscrypt) || return 1
        for directory in /apex/com.android.conscrypt@*; do
            [ -d "$directory/cacerts" ] || continue
            [ "$(stat -c '%d:%i' "$directory")" != "$apex_identity" ] || destinations="$destinations $MODDIR/apex/${directory##*/}/cacerts"
        done
    fi
    for destination in $destinations; do
        mkdir -p "$destination" || return 1
        for file in "$MODULE_CERT_DIR"/*; do cp -p "$file" "$destination/" || return 1; done
        set_cert_permissions "$destination" "$SYSTEM_SOURCE" || return 1
    done
}

clean_builtin_outputs() {
    local directory file
    for directory in "$MODDIR/system/etc/security/cacerts" "$MODDIR"/apex/*/cacerts; do
        [ -d "$directory" ] || continue
        for file in "$directory"/*; do [ ! -f "$file" ] || rm -f "$file" || return 1; done
    done
}

verify_processes() {
    local pid namespace seen=' ' result=0
    for pid in 1 $(pidof zygote zygote64 webview_zygote) $(ps -A -o PID,NAME | awk '$2 ~ /_zygote$/ {print $1}'); do
        namespace=$(readlink "/proc/$pid/ns/mnt") || { result=1; continue; }
        case "$seen" in *" $namespace "*) continue ;; esac
        seen="$seen$namespace "
        if ns_run "$pid" /system/bin/sh "$MODDIR/sh/mount.sh"; then
            print_log "Verified namespace $namespace pid=$pid"
        else
            print_log "ERROR: namespace verification failed pid=$pid"
            result=1
        fi
    done
    # At least one zygote must exist, even when it shares init's namespace.
    [ -n "$(pidof zygote zygote64)" ] || return 1
    return "$result"
}

load_runtime_mode() {
    [ -f "$RUNTIME" ] && [ "$(sed -n 's/^boot_id=//p' "$RUNTIME")" = "$BOOT_ID" ] || return 1
    CURRENT_MODE=$(sed -n 's/^effective_mode=//p' "$RUNTIME")
    CONFIGURED_MODE=$(sed -n 's/^configured_mode=//p' "$RUNTIME")
    MODE_REASON=$(sed -n 's/^mode_reason=//p' "$RUNTIME")
    case "$CURRENT_MODE" in compatible|builtin) ;; *) return 1 ;; esac
}

lock_state() {
    local binary
    exec 9> "$MODDIR/state.lock" || return 1
    for binary in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox; do
        [ ! -x "$binary" ] || { "$binary" flock -x 9; return $?; }
    done
    flock -x 9
}
