#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
case "${1:-}" in
    sweb) ;;
    ''|all)
        (cd webdev && npm ci --ignore-scripts && npm run typecheck && npm run build)
        node --test tests/*.test.mjs
        sh tests/runtime-test.sh
        sh tests/namespace-test.sh
        sh tests/service-test.sh
        sh tests/lock-test.sh
        python3 -m unittest discover -s tests -p '*_test.py'
        ;;
    *) echo 'Usage: buildzip.sh [sweb|all]' >&2; exit 1 ;;
esac
python3 scripts/package.py
