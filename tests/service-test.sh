#!/bin/sh
# Exercise the actual service control flow with a fixture runtime and no mounts.
ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/module/sh" "$WORK/module/state"
cp "$ROOT/service.sh" "$WORK/module/service.sh"
cp "$ROOT/post-mount.sh" "$WORK/module/post-mount.sh"
cp "$ROOT/sh/mount.sh" "$WORK/module/sh/mount.sh"
cp "$ROOT/sh/runtime.sh" "$WORK/module/sh/runtime.sh"
cat >> "$WORK/module/sh/runtime.sh" <<'MOCK'
init_paths() {
    BOOT_ID=fixture-boot; CURRENT_MODE=builtin; CONFIGURED_MODE=builtin; MODE_REASON=none
    RUNTIME="$MODDIR/runtime.conf"; LOG_PATH="$MODDIR/install.log"; TEMP_DIR="$MODDIR/mounted"
}
getprop() { echo 1; }
lock_state() { :; }
ns_run() { touch "$MODDIR/activated"; [ ! -f "$MODDIR/reject" ]; }
prepare_mount_source() { touch "$MODDIR/source-attempt"; [ ! -f "$MODDIR/reject" ] && touch "$MODDIR/source-ready"; }
mount_in_current_namespace() { [ "$1" = "$TEMP_DIR" ] && [ -f "$MODDIR/source-ready" ] && touch "$MODDIR/mounted-ok"; }
verify_processes() { touch "$MODDIR/verified"; [ ! -f "$MODDIR/reject" ]; }
cp() { :; } # Do not write the phone-only /data/local/tmp log export.
chmod() { :; }
MOCK
pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); printf 'ok %s - %s\n' "$pass" "$1"; }
setup() {
    printf 'boot_id=fixture-boot\nconfigured_mode=%s\neffective_mode=%s\nmode_reason=none\nstate=%s\nreason=%s\n' "${3:-builtin}" "${3:-builtin}" "$1" "$2" > "$WORK/module/runtime.conf"
    printf 'fixture-boot\n' > "$WORK/module/state/boot_id"
    rm -f "$WORK/module/verified" "$WORK/module/reject" "$WORK/module/activated" "$WORK/module/source-attempt" "$WORK/module/source-ready" "$WORK/module/mounted-ok"
}
run_service() { sh "$WORK/module/service.sh"; }
setup prepared none
run_service || fail 'prepared boot rejected'
grep -q '^state=ready$' "$WORK/module/runtime.conf" || fail 'prepared boot not ready'
ok 'prepared current-boot store is verified after boot'
for reason in initial_mount_failed post_mount_failed; do
    setup failed "$reason"
    run_service || fail "$reason not retried"
    [ -f "$WORK/module/verified" ] && grep -q '^state=ready$' "$WORK/module/runtime.conf" || fail "$reason did not recover"
    ok "early $reason is retried after boot"
done
setup failed preparation_failed
if run_service; then fail 'preparation failure accepted'; fi
[ ! -f "$WORK/module/verified" ] || fail 'bad preparation reached verifier'
ok 'preparation failure cannot be upgraded into installation success'
setup prepared none
printf 'old-boot\n' > "$WORK/module/state/boot_id"
if run_service; then fail 'old prepared store accepted'; fi
[ ! -f "$WORK/module/verified" ] || fail 'old store reached verifier'
ok 'a current runtime cannot validate the previous boot certificate cache'
setup prepared none
touch "$WORK/module/reject"
if run_service; then fail 'verification failure accepted'; fi
grep -q '^state=failed$' "$WORK/module/runtime.conf" &&
    grep -q '^reason=process_verification_failed$' "$WORK/module/runtime.conf" || fail 'failure not recorded'
ok 'failed namespace verification remains a failure'
run_post_mount() { sh "$WORK/module/post-mount.sh"; }
run_mount() { sh "$WORK/module/sh/mount.sh"; }
for reason in initial_mount_failed post_mount_failed; do
    setup failed "$reason" compatible
    run_post_mount || fail "post-mount did not retry $reason"
    [ -f "$WORK/module/activated" ] && grep -q '^state=prepared$' "$WORK/module/runtime.conf" || fail 'post-mount did not recover to prepared'
    [ ! -f "$WORK/module/verified" ] || fail 'post-mount claimed final verification'
    ok "post-mount retries $reason without claiming ready"
done
setup failed preparation_failed
if run_post_mount; then fail 'post-mount accepted failed preparation'; fi
[ ! -f "$WORK/module/activated" ] || fail 'invalid preparation reached activation'
ok 'post-mount rejects failed preparation'
setup prepared none
printf 'old-boot\n' > "$WORK/module/state/boot_id"
if run_post_mount; then fail 'post-mount accepted old store'; fi
[ ! -f "$WORK/module/activated" ] || fail 'old store reached activation'
ok 'post-mount rejects a previous boot store'
setup prepared none
touch "$WORK/module/reject"
if run_post_mount; then fail 'post-mount accepted failed activation'; fi
grep -q '^reason=post_mount_failed$' "$WORK/module/runtime.conf" || fail 'post-mount failure not recorded'
ok 'post-mount activation failure remains a failure'
setup failed initial_mount_failed compatible
run_mount || fail 'init recovery did not prepare source'
[ -f "$WORK/module/source-attempt" ] && [ -f "$WORK/module/mounted-ok" ] || fail 'init recovery did not mount prepared source'
ok 'init recovery reconstructs missing source before mounting'
setup failed initial_mount_failed compatible
touch "$WORK/module/reject"
if run_mount; then fail 'init recovery accepted failed source'; fi
[ ! -f "$WORK/module/mounted-ok" ] || fail 'failed source reached mount'
ok 'init recovery rejects failed source preparation'
setup failed initial_mount_failed compatible
printf 'old-boot\n' > "$WORK/module/state/boot_id"
if run_mount; then fail 'init recovery accepted old store'; fi
[ ! -f "$WORK/module/source-attempt" ] || fail 'old store reached source preparation'
ok 'init recovery rejects a previous boot store'
printf 'PASS: %s service regression cases\n' "$pass"
