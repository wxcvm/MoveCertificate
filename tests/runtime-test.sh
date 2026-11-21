#!/bin/sh
# All files are isolated fixtures. Mounts, labels and ownership are mocked.
ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
FIX="$ROOT/tests/fixtures"
TEST_ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT
. "$ROOT/sh/runtime.sh"
getenforce() { echo Disabled; }
chown() { return 0; }
stat() {
    if [ "$1" = -c ] && [ "$2" = '%u' ]; then echo 0
    else command stat "$@"; fi
}
mount() { echo "$*" >> "$TEST_ROOT/mounts"; return 1; }
umount() { echo "$*" >> "$TEST_ROOT/unmounts"; return 0; }
pass=0
ok() { pass=$((pass + 1)); printf 'ok %s - %s\n' "$pass" "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
HASH=$(cat "$FIX/subject-hash.txt")
setup() {
    MODDIR="$TEST_ROOT/case-$pass"
    mkdir -p "$MODDIR" "$MODDIR/native" "$MODDIR/user0" "$MODDIR/user10" "$MODDIR/custom"
    SYSTEM_SOURCE="$MODDIR/native"; MODULE_CERT_DIR="$MODDIR/state/certs"
    SYSTEM_CERT_DIR="$MODDIR/legacy"; APEX_CERT_DIR="$TEST_ROOT/apex-source/com.android.conscrypt/cacerts"
    LEGACY_TARGET=''; LEGACY_COMPAT=0
    MANIFEST="$MODDIR/state/certificate-sources.tsv"; LOG_PATH="$MODDIR/install.log"
    SELECTION_PATH="$MODDIR/cert-selection.tsv"
    CUSTOM_CERT_DIR="$MODDIR/custom"; USER_CERT_DIRS="$MODDIR/user0 $MODDIR/user10"
    TEMP_DIR="$MODDIR/mounted"; BOOT_ID=test-boot; SDK=33; CURRENT_MODE=compatible; CERT_OPENSSL=''
    cp "$FIX/native.pem" "$SYSTEM_SOURCE/$HASH.0"
}
setup
cp "$FIX/collision.pem" "$MODDIR/user0/$HASH.0"
base64 -d "$FIX/collision.b64" > "$MODDIR/user10/$HASH.9"
prepare_cert_store || fail 'valid preparation'
cmp -s "$SYSTEM_SOURCE/$HASH.0" "$MODULE_CERT_DIR/$HASH.0" || fail 'native overwritten by collision'
[ -f "$MODULE_CERT_DIR/$HASH.1" ] && [ "$(ls -1 "$MODULE_CERT_DIR" | wc -l)" -eq 2 ] || fail 'collision allocation / DER dedup'
[ "$(wc -l < "$MANIFEST")" -eq 2 ] || fail 'multi-user provenance'
grep -q 'BEGIN CERTIFICATE' "$MODULE_CERT_DIR/$HASH.1" || fail 'PEM output required'
ok 'colliding CA preserves native bytes; PEM/DER duplicates and all users recorded'
rm "$MODDIR/user0/$HASH.0" "$MODDIR/user10/$HASH.9"
prepare_cert_store || fail 'fresh preparation'
[ ! -e "$MODULE_CERT_DIR/$HASH.1" ] || fail 'removed input resurrected'
ok 'deleted input is not resurrected from the previous module cache'
setup
cp "$FIX/collision.pem" "$CUSTOM_CERT_DIR/input.pem"
prepare_cert_store || fail 'unverified custom must not destroy native store'
grep -q 'unverified$' "$MANIFEST" && [ -f "$CUSTOM_CERT_DIR/input.pem" ] || fail 'custom preserved'
[ "$(ls -1 "$MODULE_CERT_DIR" | wc -l)" -eq 1 ] || fail 'unparsed custom installed'
ok 'custom CA without X.509 parser is skipped and preserved'
setup
prepare_cert_store || fail 'baseline'
cp "$MODDIR/state/boot_id" "$MODDIR/saved-boot"
rm "$SYSTEM_SOURCE/$HASH.0"
if prepare_cert_store; then fail 'empty native store accepted'; fi
cmp -s "$MODDIR/saved-boot" "$MODDIR/state/boot_id" || fail 'failed preparation replaced valid state'
ok 'empty native store fails without replacing valid state'
setup
mv "$SYSTEM_SOURCE/$HASH.0" "$SYSTEM_SOURCE/$HASH.2"
if prepare_cert_store; then fail 'native hash gap accepted'; fi
ok 'native hash sequence gaps fail before mounting'
setup
ln -s "$FIX/collision.pem" "$MODDIR/user0/$HASH.0"
cp "$FIX/collision.pem" "$MODDIR/user10/not-a-hash.pem"
prepare_cert_store || fail 'input filtering'
[ ! -s "$MANIFEST" ] || fail 'symlink or invalid filename accepted'
ok 'symlink and invalid user filename are ignored'
setup
prepare_cert_store || fail 'baseline'
if prepare_mount_source; then fail 'tmpfs failure reported as success'; fi
if mount_in_current_namespace "$MODULE_CERT_DIR"; then fail 'bind failure reported as success'; fi
cmp -s "$SYSTEM_SOURCE/$HASH.0" "$FIX/native.pem" || fail 'failure modified original store'
ok 'tmpfs and bind failures propagate; original trust store remains intact'
# Same directory identity must not stack another bind mount.
SYSTEM_SOURCE="$MODULE_CERT_DIR"
before=$(wc -l < "$TEST_ROOT/mounts")
mount_in_current_namespace "$MODULE_CERT_DIR" || fail 'existing verified mount'
[ "$(wc -l < "$TEST_ROOT/mounts")" -eq "$before" ] || fail 'stacked mount'
ok 'an already verified directory does not receive a duplicate bind'
setup
cp "$FIX/collision.pem" "$MODDIR/user0/$HASH.0"
prepare_cert_store || fail 'baseline'
mkdir "$MODDIR/target"
cp "$MODULE_CERT_DIR"/* "$MODDIR/target/"
printf '\nchanged' >> "$MODDIR/target/$HASH.1"
if verify_cert_mount "$MODDIR/target"; then fail 'same filename with wrong contents accepted'; fi
ok 'verification rejects matching filenames with different certificate contents'
# Inject a copy failure during preparation; the previously published state survives.
cp() { case "$*" in *"$FIX"*) command cp "$@" ;; *) return 1 ;; esac; }
if prepare_cert_store; then fail 'copy failure accepted'; fi
[ -f "$MODULE_CERT_DIR/$HASH.1" ] || fail 'copy failure destroyed previous state'
unset -f cp
ok 'copy failure never publishes a partial certificate set'
if command -v openssl >/dev/null 2>&1; then
    setup
    CERT_OPENSSL=$(command -v openssl)
    cp "$FIX/collision.pem" "$CUSTOM_CERT_DIR/test.pem"
    printf 'not a certificate\n' > "$CUSTOM_CERT_DIR/invalid.pem"
    prepare_cert_store || fail 'OpenSSL custom validation'
    [ -f "$MODULE_CERT_DIR/$HASH.1" ] || fail 'validated custom CA not installed'
    grep -q 'unverified$' "$MANIFEST" && [ -f "$CUSTOM_CERT_DIR/invalid.pem" ] || fail 'malformed custom input destroyed'
    openssl x509 -in "$MODULE_CERT_DIR/$HASH.1" -noout || fail 'output X509 unreadable'
    ok 'real X.509 parser accepts a CA and preserves invalid custom input'
fi
setup
cp "$FIX/collision.pem" "$MODDIR/user0/$HASH.0"
base64 -d "$FIX/collision.b64" > "$MODDIR/user10/$HASH.2"
user_digest=$(file_digest "$MODDIR/user10/$HASH.2")
printf '%s\t0\n' "$user_digest" > "$SELECTION_PATH"
prepare_cert_store || fail 'disabled preparation'
[ ! -e "$MODULE_CERT_DIR/$HASH.1" ] && [ "$(grep -c 'disabled$' "$MANIFEST")" -eq 2 ] || fail 'fingerprint disable must cover all users'
[ -f "$MODDIR/user0/$HASH.0" ] && [ -f "$MODDIR/user10/$HASH.2" ] || fail 'toggle deleted original inputs'
ok 'disabled fingerprint skips every user copy and preserves originals'
printf '%s\t1\n' "$user_digest" > "$SELECTION_PATH"
prepare_cert_store || fail 'enabled preparation'
[ -f "$MODULE_CERT_DIR/$HASH.1" ] || fail 're-enable did not restore migration'
ok 're-enabling restores migration on the next preparation'
# Defaults are intentionally narrow, and explicit choice can override them.
printf '\060AdGuard Personal Intermediate' > "$MODDIR/intermediate.der"
if certificate_enabled "$user_digest" 47ec1af8 "$MODDIR/intermediate.der"; then :; else fail 'explicit enabled intermediate ignored'; fi
rm "$SELECTION_PATH"
if certificate_enabled "$user_digest" 47ec1af8 "$MODDIR/intermediate.der"; then fail 'AdGuard intermediate default enabled'; fi
certificate_enabled "$user_digest" 0f4ed297 "$MODDIR/intermediate.der" || fail 'AdGuard root default disabled'
ok 'AdGuard intermediate defaults off, root on, with explicit override supported'
setup
cp "$FIX/native.pem" "$MODDIR/user0/$HASH.0"
base64 -d "$FIX/native.b64" > "$MODDIR/native.der"
native_digest=$(file_digest "$MODDIR/native.der")
printf '%s\t0\n' "$native_digest" > "$SELECTION_PATH"
prepare_cert_store || fail 'native protection'
grep -q 'native$' "$MANIFEST" && cmp -s "$MODULE_CERT_DIR/$HASH.0" "$FIX/native.pem" || fail 'native CA hidden by selection'
ok 'user migration selection cannot remove an identical native CA'
printf 'corrupt\t0\n' > "$SELECTION_PATH"
if prepare_cert_store; then fail 'malformed selection accepted'; fi
ok 'malformed selection fails without publishing an unintended trust set'
# Exercise the real helper body with fixture paths and no root/process locking.
sed '/^MODDIR=/d; /^\. "$MODDIR\/sh\/runtime.sh"/d; /^init_paths /d' "$ROOT/sh/set-cert-enabled.sh" > "$TEST_ROOT/toggle-helper.sh"
setup
cp "$FIX/collision.pem" "$MODDIR/user0/$HASH.0"
prepare_cert_store || fail 'helper baseline'
user_digest=$(awk -F '\t' '{print $1; exit}' "$MANIFEST")
lock_state() { return 0; }
( set -- "$user_digest" 0; . "$TEST_ROOT/toggle-helper.sh" ) || fail 'helper save'
grep -q "^$user_digest$(printf '\t')0$" "$SELECTION_PATH" || fail 'helper did not publish selection'
grep -q 'pending$' "$MANIFEST" && [ -f "$MODULE_CERT_DIR/$HASH.1" ] && [ -f "$MODDIR/user0/$HASH.0" ] || fail 'helper modified live state/input'
ok 'actual toggle helper atomically saves next-boot selection without changing live CA/input'
( set -- "$user_digest" 1; . "$TEST_ROOT/toggle-helper.sh" ) || fail 'helper re-enable'
grep -q "^$user_digest$(printf '\t')1$" "$SELECTION_PATH" && [ "$(wc -l < "$SELECTION_PATH")" -eq 1 ] || fail 'helper appended conflicting duplicate choice'
ok 'actual toggle helper replaces a prior choice rather than appending conflicts'
# Providers such as Mountify collect only module/system, including APEX.
# Both layouts must contain the full set and only the currently active alias.
for version in 34 37; do
    setup
    SDK=$version; CURRENT_MODE=builtin
    mkdir -p "$MODDIR/apex-source/com.android.conscrypt@active/cacerts" "$MODDIR/apex-source/com.android.conscrypt@inactive/cacerts"
    ln -s com.android.conscrypt@active "$MODDIR/apex-source/com.android.conscrypt"
    APEX_CERT_DIR="$MODDIR/apex-source/com.android.conscrypt/cacerts"
    cp "$FIX/native.pem" "$APEX_CERT_DIR/$HASH.0"
    SYSTEM_SOURCE="$APEX_CERT_DIR"
    cp "$FIX/collision.pem" "$MODDIR/user0/$HASH.0"
    prepare_cert_store && prepare_builtin || fail 'builtin preparation'
    for layout in apex system/apex; do
        for alias in com.android.conscrypt com.android.conscrypt@active; do
            verify_cert_mount "$MODDIR/$layout/$alias/cacerts" builtin || fail 'builtin incomplete layout'
            cmp -s "$FIX/native.pem" "$MODDIR/$layout/$alias/cacerts/$HASH.0" || fail 'builtin native byte preservation'
        done
        [ ! -d "$MODDIR/$layout/com.android.conscrypt@inactive" ] || fail 'inactive APEX output generated'
    done
    # Extra files are allowed for builtin framework merging, but an omitted
    # selected certificate must fail rather than report a working mount.
    if mount_in_current_namespace "$MODULE_CERT_DIR"; then fail 'unmounted builtin reported as active'; fi
    cp "$MODULE_CERT_DIR"/* "$APEX_CERT_DIR/"
    mount_in_current_namespace "$MODULE_CERT_DIR" || fail 'provider result not verified'
    rm "$MODDIR/user0/$HASH.0" "$APEX_CERT_DIR/$HASH.1"
    mkdir -p "$MODDIR/apex-source/com.android.conscrypt@next/cacerts"
    cp "$FIX/native.pem" "$MODDIR/apex-source/com.android.conscrypt@next/cacerts/$HASH.0"
    rm "$MODDIR/apex-source/com.android.conscrypt"
    ln -s com.android.conscrypt@next "$MODDIR/apex-source/com.android.conscrypt"
    prepare_cert_store && prepare_builtin || fail 'builtin rebuild'
    for layout in apex system/apex; do
        [ ! -e "$MODDIR/$layout/com.android.conscrypt/cacerts/$HASH.1" ] || fail 'stale builtin certificate retained'
        [ ! -d "$MODDIR/$layout/com.android.conscrypt@active" ] || fail 'old APEX alias left for provider mounting'
        verify_cert_mount "$MODDIR/$layout/com.android.conscrypt@next/cacerts" builtin || fail 'new APEX alias not prepared'
    done
    ok "Android SDK $version builtin layouts preserve full CA contents and active aliases; provider result must verify"
done
# Separate active aliases can share the same APEX parent identity but have
# different mounted certificate directories. Inject a failure on the second
# bind and require the first bind to be undone, without unmounting the source.
setup
SDK=37
APEX_CERT_DIR="$MODDIR/apex/com.android.conscrypt/cacerts"
SYSTEM_SOURCE="$APEX_CERT_DIR"
mkdir -p "$SYSTEM_SOURCE" "$MODDIR/apex/com.android.conscrypt@active/cacerts"
cp "$FIX/native.pem" "$SYSTEM_SOURCE/$HASH.0"
cp "$FIX/native.pem" "$MODDIR/apex/com.android.conscrypt@active/cacerts/$HASH.0"
cp "$FIX/collision.pem" "$MODDIR/user0/$HASH.0"
prepare_cert_store || fail 'rollback preparation'
rollback_alias="$MODDIR/apex/com.android.conscrypt@active/cacerts"
rollback_ops="$MODDIR/rollback-ops"
stat() {
    case "$*" in
        *'%d:%i'*'/com.android.conscrypt'|*'%d:%i'*'/com.android.conscrypt@active') echo '10:10' ;;
        *'%u'*) echo 0 ;;
        *) command stat "$@" ;;
    esac
}
mount() {
    printf 'bind %s\n' "$4" >> "$rollback_ops"
    [ "$4" = "$SYSTEM_SOURCE" ] || return 1
    command cp "$3"/* "$4/"
}
umount() {
    printf 'unmount %s\n' "$1" >> "$rollback_ops"
    rm -f "$1/$HASH.1"
}
if mount_in_current_namespace "$MODULE_CERT_DIR"; then fail 'second alias failure accepted'; fi
[ "$(cat "$rollback_ops")" = "$(printf 'bind %s\nbind %s\nunmount %s' "$SYSTEM_SOURCE" "$rollback_alias" "$SYSTEM_SOURCE")" ] || fail 'rollback did not unwind only successful binds'
[ ! -f "$SYSTEM_SOURCE/$HASH.1" ] && [ -f "$MODULE_CERT_DIR/$HASH.1" ] || fail 'rollback altered source or left partial mount'
ok 'failed second APEX bind rolls back the first new bind'
: > "$rollback_ops"
printf 'stale' >> "$MODULE_CERT_DIR/$HASH.1"
# A mismatched source must be rejected before any target is touched.
mkdir -p "$MODDIR/partial"
command cp "$MODULE_CERT_DIR/$HASH.0" "$MODDIR/partial/"
if mount_in_current_namespace "$MODDIR/partial"; then fail 'partial mount source accepted'; fi
[ ! -s "$rollback_ops" ] || fail 'partial source touched live mounts'
ok 'partial source is rejected before binding'
# Restore the standard fixture mocks for later cases.
stat() {
    if [ "$1" = -c ] && [ "$2" = '%u' ]; then echo 0
    else command stat "$@"; fi
}
mount() { echo "$*" >> "$TEST_ROOT/mounts"; return 1; }
umount() { echo "$*" >> "$TEST_ROOT/unmounts"; return 0; }

# Compare canonical DER at the original input path, not just the hash filename.
setup
cp "$FIX/collision.pem" "$MODDIR/user0/$HASH.0"
prepare_cert_store || fail 'diagnostic baseline'
output=$(check_certificate_sources) || fail 'unchanged sources flagged'
printf '%s\n' "$output" | grep -q '^source_changes=0 source_unverified=0$' || fail 'unchanged summary'
base64 -d "$FIX/collision.b64" > "$MODDIR/user0/$HASH.0"
check_certificate_sources >/dev/null || fail 'equivalent DER source flagged'
ok 'source diagnostics recognize equivalent PEM and DER'
cp "$FIX/native.pem" "$MODDIR/user0/$HASH.0"
output=$(check_certificate_sources)
[ "$?" -eq 1 ] && printf '%s\n' "$output" | grep -q 'source_status=changed' || fail 'replacement not detected'
ok 'source diagnostics detect changed certificate at same path'
cp "$FIX/collision.pem" "$MODDIR/user10/$HASH.2"
output=$(check_certificate_sources)
[ "$?" -eq 1 ] && printf '%s\n' "$output" | grep -q 'source_status=new' || fail 'new source not detected'
rm "$MODDIR/user0/$HASH.0"
output=$(check_certificate_sources)
[ "$?" -eq 1 ] && printf '%s\n' "$output" | grep -q 'source_status=missing' || fail 'missing source not detected'
[ -f "$MODULE_CERT_DIR/$HASH.1" ] || fail 'read-only diagnostic modified prepared store'
ok 'source diagnostics identify new and missing inputs without modifying prepared store'
printf 'not a certificate\n' > "$MODDIR/user10/$HASH.2"
output=$(check_certificate_sources)
[ "$?" -eq 2 ] && printf '%s\n' "$output" | grep -q 'source_status=unverified' || fail 'invalid source not detected'
ok 'source diagnostics distinguish unreadable certificate from verified change'

# Follow the actual AOSP Conscrypt source selection: APEX only when
# available and nonempty on Android 14+; preserve the official fallback.
setup
SDK=37
SYSTEM_CERT_DIR="$SYSTEM_SOURCE"
APEX_CERT_DIR="$MODDIR/apex-test/cacerts"
mkdir -p "$APEX_CERT_DIR"
select_system_source
[ "$SYSTEM_SOURCE" = "$SYSTEM_CERT_DIR" ] || fail 'empty APEX selected instead of system fallback'
ok 'Android 14+ empty APEX directory selects the system fallback'
cp "$FIX/native.pem" "$APEX_CERT_DIR/$HASH.0"
select_system_source
[ "$SYSTEM_SOURCE" = "$APEX_CERT_DIR" ] || fail 'populated Android 14+ APEX not preferred'
ok 'Android 14+ populated APEX directory is the preferred trust store'
SDK=33
select_system_source
[ "$SYSTEM_SOURCE" = "$SYSTEM_CERT_DIR" ] || fail 'pre-Android 14 selected APEX'
ok 'pre-Android 14 uses the traditional system trust store'

# When Android's APEX source is absent, builtin mode must not try to
# prepare nonexistent APEX overlay aliases.
setup
SDK=37
CURRENT_MODE=builtin
SYSTEM_CERT_DIR="$SYSTEM_SOURCE"
APEX_CERT_DIR="$MODDIR/missing-apex/cacerts"
select_system_source
prepare_cert_store && prepare_builtin || fail 'system fallback builtin preparation'
verify_cert_mount "$MODDIR/system/etc/security/cacerts" builtin ||
    fail 'system fallback builtin overlay missing'
[ ! -d "$MODDIR/system/apex/com.android.conscrypt/cacerts" ] ||
    fail 'APEX overlay generated while official source was unavailable'
ok 'builtin system fallback does not generate stale APEX overlay'


# The official Conscrypt source can appear or disappear across early boot
# phases. Only the source used to prepare this boot may be verified later.
setup
SDK=37
SYSTEM_CERT_DIR="$SYSTEM_SOURCE"
APEX_CERT_DIR="$MODDIR/apex-source/cacerts"
RUNTIME="$MODDIR/runtime.conf"
CONFIGURED_MODE=compatible
MODE_REASON=none
mkdir -p "$APEX_CERT_DIR"
select_system_source
[ "$SYSTEM_SOURCE" = "$SYSTEM_CERT_DIR" ] || fail 'empty APEX should fall back'
write_runtime prepared || fail 'system-source fallback snapshot'
cp "$FIX/native.pem" "$APEX_CERT_DIR/$HASH.0"
select_system_source
if load_runtime_mode > "$MODDIR/drift.out" 2>&1; then
    fail 'system-source drift from fallback to APEX accepted'
fi
grep -q 'reason=system_source_changed' "$MODDIR/drift.out" ||
    fail 'source drift did not report a concrete reason'
ok 'source changing from legacy to APEX fails closed, not falsely ready'
rm "$APEX_CERT_DIR/$HASH.0"
select_system_source
load_runtime_mode || fail 'same boot legacy source snapshot rejected'
ok 'stable fallback source matches its boot snapshot'

# Test drift in the opposite direction (APEX temporarily disappears).
cp "$FIX/native.pem" "$APEX_CERT_DIR/$HASH.0"
select_system_source
write_runtime prepared || fail 'APEX source snapshot'
rm "$APEX_CERT_DIR/$HASH.0"
select_system_source
if load_runtime_mode > "$MODDIR/drift.out" 2>&1; then
    fail 'system-source drift from APEX to fallback accepted'
fi
grep -q 'reason=system_source_changed' "$MODDIR/drift.out" ||
    fail 'APEX disappearance lacked a concrete error'
ok 'APEX disappearing during boot fails closed'
printf 'system_source=/unexpected/untrusted/path\n' > "$MODDIR/invalid-source"
sed '/^system_source=/d' "$RUNTIME" > "$MODDIR/runtime.copy"
cat "$MODDIR/invalid-source" >> "$MODDIR/runtime.copy"
mv "$MODDIR/runtime.copy" "$RUNTIME"
if load_runtime_mode > "$MODDIR/drift.out" 2>&1; then
    fail 'unexpected CA source accepted from runtime snapshot'
fi
grep -q 'reason=prepared_system_source_invalid' "$MODDIR/drift.out" ||
    fail 'unsafe source had no diagnostic reason'
ok 'runtime snapshot refuses an unexpected source path'


# A newly added native CA during preparation must not be silently omitted,
# even though all entries from the original listing still compare byte-wise.
setup
prepare_cert_store || fail 'baseline before native CA race'
cp() {
    command cp "$@" || return 1
    if [ "$1" = -p ] && [ "$2" = "$SYSTEM_SOURCE/$HASH.0" ] &&
       [ ! -e "$SYSTEM_SOURCE/$HASH.1" ]; then
        command cp "$FIX/collision.pem" "$SYSTEM_SOURCE/$HASH.1" || return 1
    fi
}
if prepare_cert_store; then
    fail 'native certificate added mid-preparation was not detected'
fi
unset -f cp
grep -q 'native certificate set changed during preparation' "$LOG_PATH" ||
    fail 'new native certificate had no actionable diagnostic'
[ -f "$MODULE_CERT_DIR/$HASH.0" ] &&
    [ ! -e "$MODULE_CERT_DIR/$HASH.1" ] ||
    fail 'failed CA race replaced last good prepared store'
ok 'new native CA during staging causes atomic failure without losing last state'

# User CA contents must remain stable across the preparation window.
setup
prepare_cert_store || fail 'baseline before user-source mutation race'
base64 -d "$FIX/collision.b64" > "$MODDIR/user0/$HASH.0"
cp() {
    command cp "$@" || return 1
    if [ "$1" = -f ] && [ "$2" = "$MODDIR/user0/$HASH.0" ]; then
        command cp "$FIX/native.pem" "$MODDIR/user0/$HASH.0" || return 1
    fi
}
if prepare_cert_store; then fail 'user CA mutation during preparation accepted'; fi
unset -f cp
grep -q 'user certificate sources changed during preparation' "$LOG_PATH" || fail 'user mutation lacked an actionable diagnostic'
[ ! -e "$MODULE_CERT_DIR/$HASH.1" ] || fail 'changed user CA replaced last good state'
ok 'user CA replacement during staging aborts atomically and preserves last good state'

# A newly added user/profile CA during staging must not enter a partial snapshot.
setup
prepare_cert_store || fail 'baseline before user-source addition race'
base64 -d "$FIX/collision.b64" > "$MODDIR/user0/$HASH.0"
cp() {
    command cp "$@" || return 1
    if [ "$1" = -f ] && [ "$2" = "$MODDIR/user0/$HASH.0" ] && [ ! -e "$MODDIR/user10/$HASH.9" ]; then
        base64 -d "$FIX/collision.b64" > "$MODDIR/user10/$HASH.9" || return 1
    fi
}
if prepare_cert_store; then fail 'new user CA during preparation accepted'; fi
unset -f cp
grep -q 'user certificate sources changed during preparation' "$LOG_PATH" || fail 'user addition lacked an actionable diagnostic'
[ ! -e "$MODULE_CERT_DIR/$HASH.1" ] || fail 'new user CA race replaced last good state'
ok 'new user/profile CA during staging aborts atomically and preserves last good state'

# Removing a source while another user CA is being staged must also abort.
setup
prepare_cert_store || fail 'baseline before user-source removal race'
base64 -d "$FIX/collision.b64" > "$MODDIR/user0/$HASH.0"
base64 -d "$FIX/collision.b64" > "$MODDIR/user10/$HASH.9"
cp() {
    command cp "$@" || return 1
    if [ "$1" = -f ] && [ "$2" = "$MODDIR/user0/$HASH.0" ]; then
        rm -f "$MODDIR/user10/$HASH.9" || return 1
    fi
}
if prepare_cert_store; then fail 'removed user CA during preparation accepted'; fi
unset -f cp
grep -q 'user certificate sources changed during preparation' "$LOG_PATH" || fail 'user removal lacked an actionable diagnostic'
[ ! -e "$MODULE_CERT_DIR/$HASH.1" ] || fail 'removed user CA race replaced last good state'
ok 'removed user/profile CA during staging aborts atomically and preserves last good state'

# Opt-in legacy mirroring preserves every original native CA entry.
setup
SDK=37; SYSTEM_SOURCE="$APEX_CERT_DIR"; LEGACY_TARGET="$SYSTEM_CERT_DIR"; LEGACY_COMPAT=1
mkdir -p "$APEX_CERT_DIR" "$SYSTEM_CERT_DIR"
cp "$FIX/native.pem" "$APEX_CERT_DIR/$HASH.0"
cp "$FIX/native.pem" "$SYSTEM_CERT_DIR/$HASH.0"
cp "$FIX/collision.pem" "$MODDIR/user0/$HASH.0"
prepare_cert_store || fail 'legacy source preparation'
validate_legacy_native_store || fail 'matching legacy native CA rejected'
cp "$FIX/collision.pem" "$SYSTEM_CERT_DIR/$HASH.9"
if validate_legacy_native_store; then fail 'extra legacy native CA was hidden'; fi
rm -f "$SYSTEM_CERT_DIR/$HASH.9"
cp "$FIX/collision.pem" "$SYSTEM_CERT_DIR/$HASH.0"
if validate_legacy_native_store; then fail 'divergent legacy native CA was hidden'; fi
cp "$FIX/native.pem" "$SYSTEM_CERT_DIR/$HASH.0"
printf hidden > "$SYSTEM_CERT_DIR/.unexpected"
if validate_legacy_native_store; then fail 'hidden legacy entry was ignored'; fi
rm -f "$SYSTEM_CERT_DIR/.unexpected"
ok 'legacy preflight rejects extra, changed and hidden native entries'

# Android 17 device evidence: APEX contains two additional roots absent from
# the byte-identical legacy subset. Use synthetic test file names and fixtures:
# this verifies mount scope, not the identity or validity of real AdGuard CAs.
setup
SDK=37; CURRENT_MODE=compatible
APEX_CERT_DIR="$MODDIR/apex/com.android.conscrypt/cacerts"
SYSTEM_SOURCE="$APEX_CERT_DIR"
LEGACY_TARGET="$SYSTEM_CERT_DIR"; LEGACY_COMPAT=1
mkdir -p "$APEX_CERT_DIR" "$SYSTEM_CERT_DIR" "$MODULE_CERT_DIR"
cp "$FIX/native.pem" "$APEX_CERT_DIR/$HASH.0"
cp "$FIX/native.pem" "$SYSTEM_CERT_DIR/$HASH.0"
cp "$FIX/native.pem" "$MODULE_CERT_DIR/$HASH.0"
cp "$FIX/collision.pem" "$MODULE_CERT_DIR/11111111.0"
cp "$FIX/collision.pem" "$MODULE_CERT_DIR/22222222.0"
validate_legacy_native_store || fail 'two APEX-only CAs unexpectedly rejected'
mount() {
    command cp -p "$3"/* "$4/" || return 1
    printf '%s\n' "$4" >> "$MODDIR/mounts"
}
LEGACY_COMPAT=0; LEGACY_TARGET=''
mount_in_current_namespace "$MODULE_CERT_DIR" || fail 'default APEX-only bind failed'
[ "$(wc -l < "$MODDIR/mounts")" -eq 1 ] ||
    fail 'default-off mode mounted more than selected APEX'
[ ! -e "$SYSTEM_CERT_DIR/11111111.0" ] && [ ! -e "$SYSTEM_CERT_DIR/22222222.0" ] ||
    fail 'default-off mode unexpectedly widened legacy trust'
ok 'Android 17 APEX superset does not change legacy store by default'
LEGACY_COMPAT=1; LEGACY_TARGET="$SYSTEM_CERT_DIR"
mount_in_current_namespace "$MODULE_CERT_DIR" || fail 'two-root opt-in legacy mirror failed'
verify_cert_mount "$SYSTEM_CERT_DIR" compatible ||
    fail 'two APEX-only roots were not mirrored into the legacy store'
cmp -s "$FIX/native.pem" "$SYSTEM_CERT_DIR/$HASH.0" ||
    fail 'legacy original native certificate changed'
ok 'opt-in mirrors two APEX-only roots while preserving the native legacy subset'

# Recheck the legacy directory immediately before binding it; roll back an earlier APEX bind on drift.
legacy_mount_setup() {
    setup
    SDK=37; CURRENT_MODE=compatible; SYSTEM_SOURCE="$APEX_CERT_DIR"
    LEGACY_TARGET="$SYSTEM_CERT_DIR"; LEGACY_COMPAT=1
    mkdir -p "$APEX_CERT_DIR" "$SYSTEM_CERT_DIR"
    cp "$FIX/native.pem" "$APEX_CERT_DIR/$HASH.0"
    cp "$FIX/native.pem" "$SYSTEM_CERT_DIR/$HASH.0"
    cp "$FIX/collision.pem" "$MODDIR/user0/$HASH.0"
    prepare_cert_store || fail 'legacy mount source preparation'
}
legacy_mount_setup
mount() {
    command cp -p "$3"/* "$4/" || return 1
    if [ "$4" = "$SYSTEM_SOURCE" ]; then command cp "$FIX/collision.pem" "$SYSTEM_CERT_DIR/$HASH.9" || return 1; fi
    printf '%s\n' "$4" >> "$MODDIR/mounts"
}
umount() { printf '%s\n' "$1" >> "$MODDIR/unmounts"; }
if mount_in_current_namespace "$MODULE_CERT_DIR"; then fail 'legacy drift between binds was accepted'; fi
[ "$(wc -l < "$MODDIR/mounts")" -eq 1 ] || fail 'legacy target was mounted after drift'
[ "$(wc -l < "$MODDIR/unmounts")" -eq 1 ] || fail 'primary APEX bind was not rolled back'
ok 'legacy target is revalidated before its bind and earlier mounts are rolled back'

# Builtin mode emits the legacy overlay only when the explicit flag is enabled.
setup
SDK=37; CURRENT_MODE=builtin; LEGACY_COMPAT=1
SYSTEM_SOURCE="$APEX_CERT_DIR"; LEGACY_TARGET="$SYSTEM_CERT_DIR"
mkdir -p "$APEX_CERT_DIR" "$SYSTEM_CERT_DIR"
cp "$FIX/native.pem" "$APEX_CERT_DIR/$HASH.0"
cp "$FIX/native.pem" "$SYSTEM_CERT_DIR/$HASH.0"
cp "$FIX/collision.pem" "$MODDIR/user0/$HASH.0"
prepare_cert_store && prepare_builtin || fail 'builtin legacy preparation'
verify_cert_mount "$MODDIR/apex/com.android.conscrypt/cacerts" builtin || fail 'builtin APEX overlay incomplete'
verify_cert_mount "$MODDIR/system/apex/com.android.conscrypt/cacerts" builtin || fail 'builtin system APEX overlay incomplete'
verify_cert_mount "$MODDIR/system/etc/security/cacerts" builtin || fail 'builtin legacy overlay incomplete'
ok 'builtin mode prepares APEX and legacy overlays only for explicit opt-in'

# Default-off builtin mode must not create a legacy overlay.
setup
SDK=37; CURRENT_MODE=builtin; LEGACY_COMPAT=0
SYSTEM_SOURCE="$APEX_CERT_DIR"
mkdir -p "$APEX_CERT_DIR" "$MODDIR/apex/com.android.conscrypt"
cp "$FIX/native.pem" "$APEX_CERT_DIR/$HASH.0"
prepare_cert_store && prepare_builtin || fail 'default builtin preparation'
[ ! -d "$MODDIR/system/etc/security/cacerts" ] || fail 'default-off created legacy overlay'
ok 'legacy overlay remains absent by default'

# The boot snapshot must not change if the config file is edited after preparation.
(
    MODDIR="$TEST_ROOT/legacy-snapshot"; mkdir -p "$MODDIR"
    getprop() { echo 37; }
    select_system_source() { SYSTEM_SOURCE="$APEX_CERT_DIR"; }
    printf 'legacy_compat=1\n' > "$MODDIR/legacy-ca.conf"
    init_paths || exit 1
    [ "$LEGACY_COMPAT" = 1 ] || exit 1
    write_runtime prepared || exit 1
    printf 'legacy_compat=0\n' > "$MODDIR/legacy-ca.conf"
    init_paths || exit 1
    [ "$LEGACY_COMPAT" = 0 ] || exit 1
    load_runtime_mode || exit 1
    [ "$LEGACY_COMPAT" = 1 ] && [ "$LEGACY_TARGET" = "$SYSTEM_CERT_DIR" ]
) || fail 'legacy boot snapshot changed after config edit'
ok 'legacy opt-in is immutable for the current boot'
(
    MODDIR="$TEST_ROOT/legacy-fallback"; mkdir -p "$MODDIR"
    getprop() { echo 37; }
    select_system_source() { SYSTEM_SOURCE="$SYSTEM_CERT_DIR"; }
    printf 'legacy_compat=1\n' > "$MODDIR/legacy-ca.conf"
    init_paths || exit 1
    [ "$LEGACY_COMPAT" = 0 ] && [ -z "$LEGACY_TARGET" ]
) || fail 'legacy mirror activated when AOSP selected system fallback'
ok 'legacy mirror stays off when the official system store is already primary'

printf 'PASS: %s shell regression cases\n' "$pass"
