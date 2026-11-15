#!/usr/bin/env bash
# Dependency audit (developer machine / CI only; contacts pub.dev and OSV).
#   1. flutter pub outdated
#   2. OSV vulnerability check of pubspec.lock
#   3. License check of every locked package
#   4. Privacy invariants test (no network/tracker code)
# Exit non-zero if 2, 3 or 4 fail. Run from the repository root.
set -uo pipefail
cd "$(dirname "$0")/../.."

FLUTTER="${FLUTTER:-flutter}"
PY="${PYTHON:-python3}"
export FLUTTER_ROOT="${FLUTTER_ROOT:-$(dirname "$(dirname "$(command -v "$FLUTTER")")")}"
status=0

echo "== flutter pub get"
"$FLUTTER" pub get >/dev/null || exit 2

echo "== flutter pub outdated (informational)"
"$FLUTTER" pub outdated --no-dev-dependencies || true

echo "== OSV vulnerability check"
if command -v osv-scanner >/dev/null 2>&1; then
  osv-scanner scan --lockfile=pubspec.lock || status=1
else
  "$PY" -I tool/security/osv_check.py pubspec.lock
  rc=$?
  [ $rc -eq 1 ] && status=1
  [ $rc -eq 2 ] && { echo "WARN: OSV check could not run (offline?)"; [ "${CI:-}" = "true" ] && status=1; }
fi

echo "== License check"
"$PY" -I tool/security/license_check.py pubspec.lock || status=1

echo "== Privacy invariants"
"$FLUTTER" test test/security/no_network_test.dart || status=1

exit $status
