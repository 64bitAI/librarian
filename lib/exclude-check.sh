#!/usr/bin/env bash
# librarian exclude-check PATH...: does this machine's exclude cover these paths? Exit 0 if every one is excluded, 1 if not,
# 2 with no paths or no exclude. Decided by the same check the collector and the digest use. Prints a count, never a path or a term.
set -uo pipefail
. "$(dirname "$0")/common.sh"
[ $# -ge 1 ] || { echo "usage: librarian exclude-check PATH..." >&2; exit 2; }
load_config
need_exclude
export BRAIN_EXCLUDE; BRAIN_EXCLUDE="$(envget BRAIN_EXCLUDE)"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$LIBRARIAN_HOME/lib" python3 - "$@" <<'PY'
import sys
import brain_digest as b
rx, paths = b.excluder(), sys.argv[1:]
n = sum(b.folder_excluded(rx, p) for p in paths)
print("%d of %d excluded" % (n, len(paths)))
sys.exit(0 if n == len(paths) else 1)
PY
