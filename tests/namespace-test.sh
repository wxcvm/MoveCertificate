#!/bin/sh
# Standalone verifier uses real hashes; only mounts and process discovery mock.
ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
. "$ROOT/sh/runtime.sh"
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
pass=0
ok() { pass=$((pass + 1)); printf 'ok %s - %s\n' "$pass" "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
MODDIR="$WORK/module"
MODULE_CERT_DIR="$MODDIR/state/certs"
mkdir -p "$MODULE_CERT_DIR" "$WORK/native" "$WORK/target"
cp "$ROOT/tests/fixtures/native.pem" "$MODULE_CERT_DIR/12345678.0"
cp "$ROOT/tests/fixtures/collision.pem" "$MODULE_CERT_DIR/12345678.1"
cp "$MODULE_CERT_DIR"/* "$WORK/native/"
cp "$MODULE_CERT_DIR"/* "$WORK/target/"
manifest=$(namespace_store_manifest) || fail 'snapshot'
script=$(cat "$ROOT/sh/namespace.sh") || fail 'script'
run_verify() { sh -c "$script" fixture verify "$WORK/target" "$manifest" "${1:-builtin}" ''; }
run_verify || fail 'matching store'
mv "$MODDIR" "$WORK/hidden-module"
run_verify || fail 'verification reopened hidden module files'
mv "$WORK/hidden-module" "$MODDIR"
ok 'content verification works even when module scripts and runtime config are hidden'
printf 'changed' >> "$WORK/target/12345678.1"
if run_verify > "$WORK/detail"; then fail 'mismatch accepted'; fi
grep -q 'reason=certificate_mismatch' "$WORK/detail" || fail 'mismatch reason'
ok 'same filenames and count cannot hide different contents'
rm "$WORK/target/12345678.1"
if run_verify > "$WORK/detail"; then fail 'missing CA accepted'; fi
grep -q 'reason=certificate_missing' "$WORK/detail" || fail 'missing reason'
ok 'missing migrated CA is identified by name'
cp "$WORK/native/12345678.1" "$WORK/target/"
cp "$WORK/native/12345678.1" "$WORK/target/87654321.0"
if run_verify compatible > "$WORK/detail"; then fail 'compatible extra CA accepted'; fi
grep -q 'reason=certificate_count' "$WORK/detail" || fail 'count reason'
rm "$WORK/target/87654321.0"
ok 'compatible mode rejects extra certificates'
if sh -c "$script" fixture verify "$WORK/target" "$manifest" builtin 'mnt:[wrong]' > "$WORK/detail"; then fail 'wrong namespace accepted'; fi
grep -q 'reason=namespace_changed' "$WORK/detail" || fail 'namespace reason'
ok 'namespace identity is checked inside the child before touching mounts'

# Inject mount operations into the real standalone script. A failed repair
# must roll back only its own new binds, never the source or a prior mount.
prelude='mount() { echo mount >> "$OPS"; cp "$SOURCE"/* "$DEST/"; }; umount() { echo umount >> "$OPS"; };'
export OPS="$WORK/operations" SOURCE="$WORK/native" DEST="$WORK/target"
rm "$WORK/target/12345678.1"
sh -c "$prelude
$script" fixture repair "$DEST" "$manifest" builtin '' "$SOURCE" || fail 'repair'
run_verify || fail 'repaired content'
grep -q mount "$OPS" || fail 'repair not mounted'
ok 'builtin repair binds and verifies the already validated init source'
: > "$OPS"
if sh -c "$prelude
$script" fixture repair "$DEST" "$manifest" builtin '' "$WORK/missing-source" > "$WORK/detail"; then fail 'bad source accepted'; fi
[ ! -s "$OPS" ] || fail 'bad source modified mount'
ok 'invalid init source is refused before any bind'
: > "$OPS"
prelude='mount() { echo mount >> "$OPS"; return 0; }; umount() { echo umount >> "$OPS"; };'
rm "$WORK/target/12345678.1"
if sh -c "$prelude
$script" fixture repair "$DEST" "$manifest" builtin '' "$SOURCE" > "$WORK/detail"; then fail 'unverified mount reported repaired'; fi
grep -q umount "$OPS" || fail 'failed repair did not undo its bind'
ok 'a bind that fails content verification rolls back'

namespace_script=$script; expected_namespace_store=$manifest; CURRENT_MODE=builtin
SYSTEM_SOURCE=$DEST
ns_run() {
    case "$6" in
        verify) echo "reason=${VERIFY_FAILURE:-certificate_missing}"; return 1 ;;
        repair) echo repair >> "$OPS"; return 0 ;;
        *) return 1 ;;
    esac
}
: > "$OPS"
if check_process_namespace 1 init > "$WORK/detail"; then fail 'init mismatch accepted'; fi
[ ! -s "$OPS" ] || fail 'init was repaired from itself'
check_process_namespace 20 z20 > "$WORK/detail" || fail 'missing child not repaired'
[ "$(cat "$OPS")" = repair ] || fail 'child repair not attempted'
ok 'only a child with missing contents is eligible for builtin repair'
: > "$OPS"; VERIFY_FAILURE=namespace_entry_failed
if check_process_namespace 20 z20 > "$WORK/detail"; then fail 'entry failure accepted'; fi
[ ! -s "$OPS" ] || fail 'entry failure treated as missing CA'
unset VERIFY_FAILURE
ok 'namespace entry errors do not trigger speculative binds'

# Test boot orchestration separately from filesystem namespaces.
mkdir -p "$MODDIR/sh"
cp "$ROOT/sh/namespace.sh" "$MODDIR/sh/"
LOG_PATH="$WORK/install.log"; SYSTEM_SOURCE="$WORK/target"; CURRENT_MODE=builtin
pidof() { case "$*" in 'zygote zygote64') echo '20 30' ;; webview_zygote) echo 40 ;; esac; }
ps() { printf 'PID NAME\n40 webview_zygote\n'; }
readlink() { case "$1" in /proc/1/ns/mnt) echo init ;; /proc/20/ns/mnt) echo z20 ;; /proc/30/ns/mnt) echo z30 ;; /proc/40/ns/mnt) echo z40 ;; *) return 1 ;; esac; }
sleep() { :; }
check_process_namespace() { printf '%s\n' "$1" >> "$WORK/visited"; [ "$1" != "${FAIL_PID:-}" ]; }
verify_processes || fail 'boot verification'
[ "$(sort -u "$WORK/visited" | wc -l)" -eq 4 ] || fail 'missing process namespace'
ok 'init and both zygotes and WebView are all required and deduplicated'
: > "$WORK/visited"; FAIL_PID=1
if verify_processes; then fail 'init failure accepted'; fi
[ "$(cat "$WORK/visited")" = 1 ] || fail 'attempted child repair after init failure'
ok 'init failure prevents all child repair attempts'
: > "$WORK/visited"; FAIL_PID=30
if verify_processes; then fail 'child failure ignored'; fi
[ "$(grep -c '^30$' "$WORK/visited")" -eq 3 ] || fail 'failure did not receive bounded retries'
ok 'persistent child failures remain failed after three bounded snapshots'
printf 'PASS: %s namespace regression cases\n' "$pass"
