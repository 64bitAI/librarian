#!/usr/bin/env bash
# `librarian lease-gate` with a stub bureau, the units that call it, and the refusal to run without
# `exclude`. Nothing real is asked; no network.
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$(dirname "$0")/.hermetic"
L="$SRC/bin/librarian"; CONF="$TMP/librarian.toml"; export LIBRARIAN_CONFIG="$CONF"
export D="$TMP"; mkdir -p "$TMP/bin"
cat > "$TMP/bin/bureau" <<'SH'
#!/bin/sh
echo "$*" >> "$D/calls"
case "$*" in
  *"lease is-leader") exit "$(cat "$D/leader")" ;;
  *"history add"*) exit 0 ;;
  *history*) cat "$D/history" 2>/dev/null; exit 0 ;;
esac
exit 9
SH
chmod +x "$TMP/bin/bureau"
setconf() { printf 'state_dir = "%s"\nbureau_bin = "%s"\nexclude = "wrk"\n%s\n' "$TMP/state" "$TMP/bin/bureau" "$1" > "$CONF"; }
gate() { bash "$L" lease-gate "$@" > "$TMP/out" 2>&1; echo $?; }

# off
setconf ""; echo 1 > "$TMP/leader"; : > "$TMP/calls"
eq "off: passes" 0 "$(gate ingest day)"
eq "off: asks nothing" 0 "$(wc -l < "$TMP/calls" | tr -d ' ')"
eq "off: no stamps" no "$([ -d "$TMP/state/lease-slots" ] && echo yes || echo no)"
# on
setconf "lease_gate = 1"
eq "not the leader: a systemd skip" 1 "$(gate ingest day)"
echo 3 > "$TMP/leader"; eq "no node: a skip" 1 "$(gate ingest day)"
eq "no node: the log says why" 1 "$(grep -c 'could not say (exit 3)' "$TMP/out")"
printf '{"holder":"this-node","phase":"leader"}' > "$TMP/state-leader.json"; echo 1 > "$TMP/leader"
eq "only the command decides" 1 "$(gate ingest day)"
eq "the gate never names the leader file" 0 "$(grep -c 'leader\.json' "$SRC/lib/lease-gate.sh")"
echo 0 > "$TMP/leader"; export LEASE_GATE_STAMP=2026-11-01
eq "leader: runs" 0 "$(gate ingest day)"
eq "the slot is recorded" 1 "$(grep -c 'history add --kind slot --source librarian ingest 2026-11-01' "$TMP/calls")"
eq "second run in the slot: skipped" 1 "$(gate ingest day)"
eq "second run: says so" 1 "$(grep -c 'already ran here' "$TMP/out")"
LEASE_GATE_STAMP=2026-11-02 ; export LEASE_GATE_STAMP
printf '{"kind":"slot","text":"ingest 2026-11-02"}\n' > "$TMP/history"
eq "ran on another machine: skipped" 1 "$(gate ingest day)"
: > "$TMP/history"; eq "a new slot runs" 0 "$(gate ingest day)"
# the wrapper
export LEASE_GATE_STAMP=2026-11-03
eq "wrapper: runs the job" "0 yes" "$(gate ingest day --run /usr/bin/touch "$TMP/ran") $([ -f "$TMP/ran" ] && echo yes)"
rm -f "$TMP/ran"; echo 1 > "$TMP/leader"; export LEASE_GATE_STAMP=2026-11-04
eq "wrapper: a skip exits clean, no job" "0 no" "$(gate ingest day --run /usr/bin/touch "$TMP/ran") $([ -f "$TMP/ran" ] && echo yes || echo no)"
eq "a bad slot is a failure to systemd, not a skip" 255 "$(gate ingest fortnight)"
eq "extra words too" 255 "$(gate ingest day extra)"
printf 'wiki_dir "broken"\n' > "$CONF"
eq "a broken config with the gate off: a failure, not a skip" 255 "$(gate ingest day)"
rm -f "$TMP/ran"; eq "a broken config under the wrapper: the job runs and reports it" "0 yes" "$(gate ingest day --run /usr/bin/touch "$TMP/ran") $([ -f "$TMP/ran" ] && echo yes)"
unset LEASE_GATE_STAMP
# the units
S="$SRC/units/systemd/librarian-ingest.service.tmpl"; P="$SRC/units/launchd/librarian-ingest.plist.tmpl"
eq "ingest unit: ExecCondition" 1 "$(grep -c '^ExecCondition=@LIBRARIAN@ --config @CONFIG@ lease-gate ingest day$' "$S")"
eq "ingest plist: wrapped" 1 "$(grep -c '<string>--run</string>' "$P")"
if command -v plutil >/dev/null 2>&1; then eq "ingest plist parses" 0 "$(sed -e "s|@LIBRARIAN@|/l|" -e "s|@CONFIG@|/c|" -e "s|@LOG@|/g|" "$P" | plutil -lint - >/dev/null 2>&1; echo $?)"; fi
eq "collect is per machine: not gated" 0 "$(cat "$SRC"/units/*/librarian-collect.* | grep -c lease-gate)"
# exclude is required
printf '#!/bin/sh\nexit 97\n' > "$TMP/bin/claude"; chmod +x "$TMP/bin/claude"; export PATH="$TMP/bin:$PATH"
git init -q "$TMP/wiki"; printf 'wiki_dir = "%s"\nstate_dir = "%s"\ncollect_from = "%s"\n' "$TMP/wiki" "$TMP/state" "$TMP/nochats" > "$CONF"
run() { bash "$L" "$@" > "$TMP/out" 2>&1; echo $?; }
eq "ingest with no exclude: refused" 2 "$(run ingest)"
eq "the refusal names the setting" 1 "$(grep -c 'no exclude set' "$TMP/out")"
eq "dry run with no exclude: refused" 2 "$(run ingest --dry-run)"
eq "collect with no exclude: refused" 2 "$(run collect)"
eq "nothing written to the wiki" "" "$(git -C "$TMP/wiki" status --porcelain)"
printf 'exclude = "   "\n' >> "$CONF"
eq "a blank exclude: refused" 2 "$(run ingest)"
printf 'wiki_dir = "%s"\nstate_dir = "%s"\ncollect_from = "%s"\nexclude = '"'"'(?!)'"'"'\n' "$TMP/wiki" "$TMP/state" "$TMP/nochats" > "$CONF"
eq "the explicit match-nothing passes the refusal" 0 "$(run collect >/dev/null; grep -c 'no exclude set' "$TMP/out")"
printf 'wiki_dir = "%s"\nstate_dir = "%s"\n' "$TMP/wiki" "$TMP/state" > "$CONF"
eq "status still answers with no exclude" 0 "$(run status >/dev/null; grep -c 'no exclude set' "$TMP/out")"
if [ "$(nfails)" -eq 0 ]; then echo "all ok"; else echo "$(nfails) failed"; exit 1; fi
