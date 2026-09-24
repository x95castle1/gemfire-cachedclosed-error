#!/usr/bin/env bash
# Prints one line per scenario from the latest run's logs/<scenario>-<ts>/summary.txt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FMT='%-20s %-12s %-13s %-32s %s\n'

printf "${FMT}" SCENARIO FAILED_PUTS FAILED_POLLS "HTTP CODES AFTER TRIGGER" RUN
for s in broken-delete broken-liveness fixed-delete fixed-liveness broken-close-cache; do
  # Latest *completed* run: interrupted runs leave a folder without summary.txt.
  f="$(ls -t "${ROOT}/logs/${s}-"*/summary.txt 2>/dev/null | head -1 || true)"
  if [[ -z "${f}" ]]; then
    printf '%-20s %s\n' "${s}" "(no run yet: make ${s})"
    continue
  fi
  dir="$(dirname "${f}")"
  puts="$(sed -n 's/^Failed Account puts.*: //p' "${f}")"
  polls="$(sed -n 's/^Failed config polls.*: //p' "${f}")"
  # "  15 200" lines under the HTTP codes heading become "15x200".
  codes="$(awk '/^-- HTTP codes/ {on=1; next}
                on && /^ *[0-9]+ [0-9]+$/ {printf "%sx%s ", $1, $2; next}
                on {exit}' "${f}")"
  printf "${FMT}" "${s}" "${puts}" "${polls}" "${codes:-(none)}" "$(basename "${dir}")"
done
echo
echo "000 = connection dropped. Full details: logs/<run>/summary.txt"
