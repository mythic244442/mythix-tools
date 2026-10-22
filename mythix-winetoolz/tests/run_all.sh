#!/usr/bin/env bash
# Runs every winetoolz test suite:  bash tests/run_all.sh [filter]
# (WT_TEST_REAL_PREFIX64 / WT_TEST_REAL_PREFIX32 also enable the real-Wine tests.)
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for suite in test_lib.sh test_modules.sh test_tools.sh; do
    bash "$TESTS_DIR/$suite" "${1:-}" || rc=1
    echo
done
if (( rc )); then echo "SOME TESTS FAILED"; else echo "all suites passed"; fi
exit "$rc"
