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
  *history*) [ -f "$D/history" ] && exec cat "$D/history"; exit 0 ;;   # exec: a writer that dies of SIGPIPE, as Bureau does
  *"health --json") cat "$D/report" 2>/dev/null; exit "$(cat "$D/health" 2>/dev/null || echo 0)" ;;
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
eq "not the leader: the log says so" 1 "$(grep -c 'skipped, not the leader' "$TMP/out")"
# The real CLI with no node (bureau cli.go, node.go): is-leader 1 and no message; health 3 and no report.
echo 3 > "$TMP/health"; : > "$TMP/report"
eq "no node: a skip" 1 "$(gate ingest day)"
eq "no node: the log says so, not 'not the leader'" "1 0" "$(grep -c 'skipped, no node' "$TMP/out") $(grep -c 'not the leader' "$TMP/out")"
printf '{"majority":false}\n' > "$TMP/report"
eq "a node with no majority: a skip" 1 "$(gate ingest day)"
eq "a node with no majority: not the leader" 1 "$(grep -c 'skipped, not the leader' "$TMP/out")"
rm -f "$TMP/health" "$TMP/report"
echo 2 > "$TMP/leader"; eq "bureau cannot say: a skip" 1 "$(gate ingest day)"
eq "bureau cannot say: the log says why" 1 "$(grep -c 'could not say (exit 2)' "$TMP/out")"
echo 1 > "$TMP/leader"
printf '{"holder":"this-node","phase":"leader"}' > "$TMP/state-leader.json"; echo 1 > "$TMP/leader"
eq "only the command decides" 1 "$(gate ingest day)"
eq "the gate never names the leader file" 0 "$(grep -c 'leader\.json' "$SRC/lib/lease-gate.sh")"
echo 0 > "$TMP/leader"; export LEASE_GATE_STAMP=2026-11-01
: > "$TMP/calls"; eq "leader: runs" 0 "$(gate ingest day)"
eq "a leader never asks health" 0 "$(grep -c 'health' "$TMP/calls")"
eq "the slot is recorded" 1 "$(grep -c 'history add --kind slot --source librarian ingest 2026-11-01' "$TMP/calls")"
eq "second run in the slot: skipped" 1 "$(gate ingest day)"
eq "second run: says so" 1 "$(grep -c 'already ran here' "$TMP/out")"
export LEASE_GATE_STAMP=2026-11-05; { printf '{"text":"ingest 2026-11-05"}\n'; yes '{"text":"filler"}' | head -200000; } > "$TMP/history"
eq "a found slot stays found when grep would stop the writer" 1 "$(gate ingest day)"
eq "and it says another machine" 1 "$(grep -c 'another machine' "$TMP/out")"
rm -f "$TMP/history"
export LEASE_GATE_STAMP=2026-11-01
LEASE_GATE_STAMP=2026-11-02 ; export LEASE_GATE_STAMP
printf '{"kind":"slot","text":"ingest 2026-11-02"}\n' > "$TMP/history"
eq "ran on another machine: skipped" 1 "$(gate ingest day)"
: > "$TMP/history"; eq "a new slot runs" 0 "$(gate ingest day)"
# a stamp that cannot be written is not "already ran"
chmod 500 "$TMP/state/lease-slots/ingest"; export LEASE_GATE_STAMP=2026-11-06
eq "stamp not written: a skip" 1 "$(gate ingest day)"
eq "stamp not written: says so" "0 1" "$(grep -c 'already ran' "$TMP/out") $(grep -c 'could not write' "$TMP/out")"
chmod 700 "$TMP/state/lease-slots/ingest"
# the real CLI, when one is given: three voters listed and none, then one, running on loopback in a temp directory
if [ -n "${BUREAU_TEST_BIN:-}" ]; then
  RB="$(mktemp -d /tmp/gXXXXXX)"; "$BUREAU_TEST_BIN" keys new --out "$RB/secret" >/dev/null; mkdir -m 700 "$RB/s"
  ports="$(python3 -c 'import socket
s=[socket.socket() for _ in range(6)]
[x.bind(("127.0.0.1",0)) for x in s]
print(*[x.getsockname()[1] for x in s])')"; set -- $ports
  { printf 'identity = "personal"\nnode = "voter-1"\n[paths]\nstate_dir = "%s/s"\n[cluster]\nsecret_file = "%s/secret"\n' "$RB" "$RB"
    printf '[[voter]]\nname="voter-1"\nhost="127.0.0.1"\nclient_port=%s\ncluster_port=%s\n' "$1" "$2"
    printf '[[voter]]\nname="voter-2"\nhost="127.0.0.1"\nclient_port=%s\ncluster_port=%s\n' "$3" "$4"
    printf '[[voter]]\nname="voter-3"\nhost="127.0.0.1"\nclient_port=%s\ncluster_port=%s\n' "$5" "$6"; } > "$RB/c.toml"; chmod 600 "$RB/c.toml"
  printf 'state_dir = "%s/st"\nbureau_bin = "%s"\nbureau_config = "%s/c.toml"\nexclude = "wrk"\nlease_gate = 1\n' "$RB" "$BUREAU_TEST_BIN" "$RB" > "$CONF"
  eq "real bureau, no node: a skip" 1 "$(gate ingest day)"
  eq "real bureau, no node: the log" 1 "$(grep -c 'skipped, no node' "$TMP/out")"
  (cd "$RB" && exec env -i HOME="$RB" PATH=/usr/bin:/bin "$BUREAU_TEST_BIN" --config "$RB/c.toml" node >/dev/null 2>&1) & RN=$!
  for _ in $(jot 100 2>/dev/null || seq 100); do [ -S "$RB/s/bureau.sock" ] && break; sleep 0.2; done
  eq "real bureau, a node not leading: a skip" 1 "$(gate ingest day)"
  eq "real bureau, a node not leading: the log" 1 "$(grep -c 'skipped, not the leader' "$TMP/out")"
  kill "$RN"; wait "$RN" 2>/dev/null; rm -rf "$RB"
  setconf "lease_gate = 1"
else
  echo "skipped: BUREAU_TEST_BIN unset, so the gate did not meet the real CLI"
fi
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
if command -v plutil >/dev/null 2>&1; then eq "ingest plist parses" 0 "$(sed -e "s|@LIBRARIAN@|/l|" -e "s|@CONFIG@|/c|" -e "s|@LOG@|/g|" -e "s|@HOME@|/h|" "$P" | plutil -lint - >/dev/null 2>&1; echo $?)"; fi
# the gate asks bureau and the ingest runs claude, both usually in ~/.local/bin, which launchd's PATH lacks
eq "ingest plist: ~/.local/bin on PATH" 1 "$(grep -c '<string>@HOME@/.local/bin:/opt/homebrew/bin:' "$P")"
# every placeholder in the plist body is one its header's render command replaces
miss=""; for ph in $(sed '1,/-->/d' "$P" | grep -o '@[A-Z]*@' | sort -u); do
  sed -n '1,/-->/p' "$P" | grep -q "s|$ph|" || miss="$miss $ph"
done
eq "ingest plist: the header renders every placeholder" "" "$miss"
eq "collect is per machine: not gated" 0 "$(cat "$SRC"/units/*/librarian-collect.* | grep -c lease-gate)"
# exclude is required
printf '#!/bin/sh\nexit 97\n' > "$TMP/bin/claude"; chmod +x "$TMP/bin/claude"; export PATH="$TMP/bin:$PATH"
git init -q "$TMP/wiki"; printf 'wiki_dir = "%s"\nstate_dir = "%s"\ncollect_from = "%s"\n' "$TMP/wiki" "$TMP/state" "$TMP/nochats" > "$CONF"
run() { bash "$L" "$@" > "$TMP/out" 2>&1; echo $?; }
eq "ingest with no exclude: refused" 2 "$(run ingest)"
eq "the refusal names the setting" 1 "$(grep -c 'no exclude set' "$TMP/out")"
printf 'alert_cmd = "cat >> %s/refused"\n' "$TMP" >> "$CONF"; eq "a refusal with an alert command: still 2" 2 "$(run ingest)"
eq "a nightly refusal reaches someone" 1 "$(grep -c 'no exclude set' "$TMP/refused")"
eq "dry run with no exclude: refused" 2 "$(run ingest --dry-run)"
eq "collect with no exclude: refused" 2 "$(run collect)"
eq "nothing written to the wiki" "" "$(git -C "$TMP/wiki" status --porcelain)"
printf 'exclude = "   "\n' >> "$CONF"
eq "a blank exclude: refused" 2 "$(run ingest)"
printf 'wiki_dir = "%s"\nstate_dir = "%s"\n' "$TMP/wiki" "$TMP/state" > "$CONF"
eq "status still answers with no exclude" 0 "$(run status >/dev/null; grep -c 'no exclude set' "$TMP/out")"
if [ "$(nfails)" -eq 0 ]; then echo "all ok"; else echo "$(nfails) failed"; exit 1; fi
