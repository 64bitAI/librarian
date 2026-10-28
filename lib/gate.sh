#!/usr/bin/env bash
# The ingest's built-in gate (lib/ingest.sh asks it through run_gate in lib/common.sh):
# exit 10 when no raw chat is new or changed since the last digest pass, no digest waits to be
# ingested and no committed owner note (raw/notes) waits, here or on the upstream branch, so the
# night's run starts neither Claude nor the local model; else 0. Reads the brain's state and git;
# the only write is a quiet `git fetch` (remote refs only, never the work tree), bounded by
# BRAIN_GATE_FETCH_SECONDS (20) and failing open to what is already fetched. Prints counts, never a
# chat's, a digest's or a note's contents.
#   lib/gate.sh WIKI
set -euo pipefail
BRAIN="${1:?usage: gate.sh WIKI}"
DIGEST="$(cd "$(dirname "$0")" && pwd)/brain_digest.py"
fresh="$(python3 "$DIGEST" fresh "$BRAIN")"
pending="$(python3 "$DIGEST" pending "$BRAIN")"
notes="$(python3 "$DIGEST" notes "$BRAIN" pending)"
# A note pushed from another clone is on the upstream branch until the job pulls: any change under
# raw/notes there since HEAD opens the gate.
upstream=0
if git -C "$BRAIN" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes -o ConnectTimeout=10" \
    git -C "$BRAIN" fetch -q >/dev/null 2>&1 & f=$!
  for _ in $(seq $(( ${BRAIN_GATE_FETCH_SECONDS:-20} * 4 ))); do kill -0 "$f" 2>/dev/null || break; sleep 0.25; done
  kill "$f" 2>/dev/null || true; wait "$f" 2>/dev/null || true
  upstream="$(git -C "$BRAIN" -c core.quotePath=false diff --name-only 'HEAD...@{u}' -- raw/notes 2>/dev/null | grep -c '\.md$' || true)"
fi
if [ "$fresh" = 0 ] && [ "${pending%% *}" = 0 ] && [ "${notes%% *}" = 0 ] && [ "${upstream:-0}" = 0 ]; then
  echo "no new chats and no digest to ingest"; exit 10
fi
exit 0
