#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/src"

while IFS= read -r m || [[ -n "$m" ]]; do
  [[ -z "$m" || "$m" == \#* ]] && continue
  if [[ ! -f "${SRC}/${m}" ]]; then
    echo "missing module listed in src/MODULES: ${m}" >&2
    exit 1
  fi
  source "${SRC}/${m}"
done < "${SRC}/MODULES"

run_cli "$@"