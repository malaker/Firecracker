#!/usr/bin/env bash
# Run every smoke test, then clean up and check nothing is left.
# Usage (from Windows): wsl -d fc-host -u root -e bash /mnt/c/sources/Firecracker/tests/smoke/all.sh
set -uo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
failed=()

for t in boot resources lifecycle net run timeout; do
  bash "$dir/$t.sh" || failed+=("$t")
done

/opt/fc-sandbox/bin/fcctl cleanup 2>/dev/null
. "$dir/lib.sh"
expect "final cleanup leaves nothing behind" no_leftovers
expect "final list is empty" test "$("$FCCTL" list | wc -l)" = 1
(( FAILS )) && failed+=(final)

if (( ${#failed[@]} )); then
  echo "SMOKE TESTS FAILED: ${failed[*]}"
  exit 1
fi
echo "ALL SMOKE TESTS PASSED"
