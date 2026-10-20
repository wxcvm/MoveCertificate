#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
case "${1:-}" in
    sweb) ;;
    ''|all|auto)
        (cd webdev && npm ci --ignore-scripts && npm run typecheck && npm run build)
        node --test tests/*.test.mjs
        sh tests/runtime-test.sh
        ;;
    *) echo 'Usage: buildzip.sh [sweb|all|auto]' >&2; exit 1 ;;
esac
python3 scripts/package.py
# Installing/rebooting remains an explicit command-line request.
if [ "${1:-}" = all ] || [ "${1:-}" = auto ]; then
    VERSION=$(sed -n 's/^version=//p' module.prop)
    adb push "MoveCertificate-$VERSION.zip" /sdcard/Download/
    adb shell "su -c 'ksud module install /sdcard/Download/MoveCertificate-$VERSION.zip'"
    adb reboot
fi
