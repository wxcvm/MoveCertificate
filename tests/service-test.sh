#!/bin/sh
# Exercise the actual service control flow with a fixture runtime and no mounts.
ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/module/sh" "$WORK/module/state"
cp "$ROOT/service.sh" "$WORK/module/service.sh"
cp "$ROOT/sh/runtime.sh" "$WORK/module/sh/runtime.sh"
cat >> "$WORK/module/sh/runtime.sh" <<'MOCK'
init_paths() {
    BOOT_ID=fixture-boot; CURRENT_MODE=builtin; CONFIGURED_MODE=builtin; MODE_REASON=none
    RUNTIME="$MODDIR/runtime.conf"; LOG_PATH="$MODDIR/install.log"
}
getprop() { echo 1; }
lock_state() { :; }
verify_processes() { touch "$MODDIR/verified"; [ ! -f "$MODDIR/reject" ]; }
cp() { :; } # Do not write the phone-only /data/local/tmp log export.
chmod() { :; }
MOCK
pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); printf 'ok %s - %s\n' "$pass" "$1"; }
setup() {
    printf 'boot_id=fixture-boot\nconfigured_mode=builtin\neffective_mode=builtin\nmode_reason=none\nstate=%s\nreason=%s\n' "$1" "$2" > "$WORK/module/runtime.conf"
    printf 'fixture-boot\n' > "$WORK/module/state/boot_id"
    rm -f "$WORK/module/verified" "$WORK/module/reject"
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
printf 'PASS: %s service regression cases\n' "$pass"
