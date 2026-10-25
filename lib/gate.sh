#!/usr/bin/env bash
# The brain ingest's gate (scripts/brain-ingest.sh; the convention is run_gated in scripts/common.sh):
# exit 10 when no raw chat is new or changed since the last digest pass, no digest waits to be
# ingested and no committed owner note (raw/notes) waits, so the night's run starts neither Claude nor the local model; else 0. Reads the brain's
# state only (raw/.state) and prints counts, never a chat's or a digest's contents.
#   gates/brain-ingest.sh BRAIN
set -euo pipefail
BRAIN="${1:?usage: brain-ingest.sh BRAIN}"
DIGEST="${SWARM_REPO:-$(cd "$(dirname "$0")/.." && pwd)}/scripts/brain_digest.py"
fresh="$(python3 "$DIGEST" fresh "$BRAIN")"
pending="$(python3 "$DIGEST" pending "$BRAIN")"
notes="$(python3 "$DIGEST" notes "$BRAIN" pending)"
if [ "$fresh" = 0 ] && [ "${pending%% *}" = 0 ] && [ "${notes%% *}" = 0 ]; then
  echo "no new chats and no digest to ingest"; exit 10
fi
exit 0
