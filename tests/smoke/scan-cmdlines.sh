#!/usr/bin/env bash
# Prints how many processes have FC_SCAN_SECRET in their command line, not counting this script
# or its children. The secret comes from the environment, so it never appears in an argument here.
set -uo pipefail
secret="${FC_SCAN_SECRET:?}"
self=$$
n=0
for p in /proc/[0-9]*; do
  pid="${p#/proc/}"
  [ "$pid" = "$self" ] && continue
  [ "$(awk '{print $4}' "$p/stat" 2>/dev/null)" = "$self" ] && continue
  # Processes can exit mid-scan: the braces keep "No such file" quiet.
  if { tr '\0' ' ' < "$p/cmdline"; } 2>/dev/null | grep -qF -- "$secret"; then n=$((n + 1)); fi
done
echo "$n"
