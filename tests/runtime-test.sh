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
    if [ "$1" = -c ] && [ "$2" = '%u' ]; then echo 0; else command stat "$@"; fi
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
sed '/^MODDIR=/d; /^\. "$MODDIR\/sh\/runtime.sh"/d; /^init_paths || exit 1/d' "$ROOT/sh/set-cert-enabled.sh" > "$TEST_ROOT/toggle-helper.sh"
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
printf 'PASS: %s shell regression cases\n' "$pass"
