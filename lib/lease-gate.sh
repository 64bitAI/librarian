#!/usr/bin/env bash
# One owner per job: run a scheduled job only on the machine `bureau lease is-leader` names, once per slot.
#   librarian lease-gate JOB hour|day|week|month              exit 0 to run, 1 to skip: systemd's ExecCondition (1 is a skip, not a failure)
#   librarian lease-gate JOB hour|day|week|month --run CMD... run CMD on a pass, exit 0 on a skip: launchd's wrapper, it has no ExecCondition
# Off unless LIBRARIAN_LEASE_GATE=1: then it only passes through. Only the command decides: this never reads Bureau's leader file, and
# every answer but 0 skips, so a machine with no node or a bad config runs nothing and its log says why.
# One run per slot: JOB and its slot are recorded in Bureau's replicated history and in a local stamp, and either skips a
# second run, so a new leader or a timer catching up does not repeat one. A slot is spent when the run starts: a failed run
# is not retried here, and running the job by hand never passes through this gate. An unreadable history falls back to the stamp.
# Keeps to: bureau (lease_gate = 1 in the config; bureau_bin), bureau_config, stamps in state_dir.
set -uo pipefail
. "$(dirname "$0")/common.sh"
load_config
on="$(envget LIBRARIAN_LEASE_GATE 0)"; bin="$(envget LIBRARIAN_BUREAU_BIN bureau)"; conf="$(envget LIBRARIAN_BUREAU_CONFIG "")"
state="$(state_dir)/lease-slots"; source_name=librarian
[ $# -ge 2 ] || { echo "usage: librarian lease-gate JOB hour|day|week|month [--run CMD...]" >&2; exit 2; }
job="$1"; slot="$2"; shift 2
wrap=""
if [ $# -gt 0 ]; then
  [ "$1" = --run ] && [ $# -ge 2 ] || { echo "usage: librarian lease-gate JOB hour|day|week|month [--run CMD...]" >&2; exit 2; }
  shift; wrap=1
fi
go() { if [ -n "$wrap" ]; then exec "$@"; fi; exit 0; }
skip() { printf '%s lease-gate %s: skipped, %s\n' "$(date +%FT%T)" "$job" "$1"; if [ -n "$wrap" ]; then exit 0; fi; exit 1; }
case "$slot" in
  hour) fmt=%Y-%m-%dT%H; since=48h ;;
  day) fmt=%Y-%m-%d; since=48h ;;
  week) fmt=%Y-W%U; since=192h ;;
  month) fmt=%Y-%m; since=800h ;;
  *) echo "lease-gate: slot is hour, day, week or month" >&2; exit 2 ;;
esac
[ "$on" = 1 ] || go "$@"

bureau=("$bin")
[ -z "$conf" ] || bureau+=(--config "$conf")
"${bureau[@]}" lease is-leader >/dev/null 2>&1; rc=$?
case "$rc" in
  0) ;;
  1) skip "not the leader" ;;
  *) skip "bureau could not say (exit $rc): no node, or a bad config" ;;
esac

stamp="${LEASE_GATE_STAMP:-$(date +"$fmt")}"; key="$job $stamp"
if "${bureau[@]}" history --kind slot --since "$since" --json 2>/dev/null | grep -qF "\"text\":\"$key\""; then
  skip "$stamp already ran on another machine"
fi
mkdir -p "$state/$job" 2>/dev/null
mkdir "$state/$job/$stamp" 2>/dev/null || skip "$stamp already ran here"
find "$state/$job" -mindepth 1 -maxdepth 1 -type d -mtime +100 -exec rmdir {} + 2>/dev/null
"${bureau[@]}" history add --kind slot --source "$source_name" "$key" >/dev/null 2>&1 || \
  printf '%s lease-gate %s: the slot is not recorded in Bureau; a takeover could repeat it\n' "$(date +%FT%T)" "$job"
go "$@"
