#!/usr/bin/env bash
# The exclude, through the real `librarian collect` and brain_digest.py: a work chat never reaches the brain. The example
# file ships it commented out, so copied as it is the file refuses to run; the form it shows, with made-up names, blocks a
# work chat in every way one can match. Throwaway HOME, synthetic chats, a local copy only; claude is a stub that fails.
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$(dirname "$0")/.hermetic"
mkdir -p "$TMP/bin" "$TMP/wiki/raw/chats"; printf '#!/bin/sh\nexit 97\n' > "$TMP/bin/claude"; chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
SHIPPED="$SRC/librarian.toml.example"; CONF="$TMP/librarian.toml"; export LIBRARIAN_CONFIG="$CONF"
L="$SRC/bin/librarian"
# The example with only this machine's paths changed.
sed -e "s|^wiki_dir = .*|wiki_dir = \"$TMP/wiki\"|" -e "s|^collect_from = .*|collect_from = \"$HOME/.claude/projects\"|" \
    -e "s|^host = .*|host = \"host1\"|" -e "s|^state_dir = .*|state_dir = \"$TMP/state\"|" "$SHIPPED" > "$CONF"
eq "nothing ships an offer to exclude nothing" 0 "$(cat "$SHIPPED" "$SRC/README.md" "$SRC/lib/common.sh" | grep -cF "exclude = '(?!)'")"

cc() { # cc FOLDER FILE CWD [TITLE]
  local d="$HOME/.claude/projects/$1"; mkdir -p "$(dirname "$d/$2")"
  { printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"hello"}}\n' "$3"
    [ -z "${4:-}" ] || printf '{"type":"ai-title","aiTitle":"%s"}\n' "$4"; } > "$d/$2"
}
P=/Users/o/src/personal
cc -Users-o-src-personal keep.jsonl "$P" "Garden plan"
cc -Users-o-src-homewrkshop keep2.jsonl /Users/o/src/homewrkshop                  # the short name inside a word is not the employer
cc -Users-o-src-github-com-EmployerCo-next w1.jsonl /Users/o/src/github.com/EmployerCo/next
cc -Users-o-src-wrk-tools w2.jsonl /Users/o/src/wrk-tools
cc -Users-o-src-personal w3.jsonl /Users/o/src/github.com/EmployerCo/core         # a neutral folder, a work cwd
cc -Users-o-src-personal w4.jsonl "$P" "WRK voice agent rollout"                  # a work title
cc -Users-o-src-forgeco-mirror w5.jsonl /Users/o/src/forgeco-mirror
SA="$HOME/.claude/projects/-Users-o-src-personal/s1/subagents"; mkdir -p "$SA"
printf '{"type":"user","cwd":"%s"}\n' "$P" > "$SA/agent-v.jsonl"; printf '{"agentType":"wrk:wrk-voice"}\n' > "$SA/agent-v.meta.json"

# Copied as it is: refused, nothing read.
bash "$L" collect >/dev/null 2>&1; rc=$?
eq "the example as shipped refuses to collect" 2 "$rc"
bash "$L" ingest --dry-run >/dev/null 2>&1; rc=$?
eq "the example as shipped refuses to ingest" 2 "$rc"
eq "and nothing arrived" "" "$(find "$TMP/wiki/raw/chats" -name '*.jsonl')"

# Its form, as a machine's private file would hold it.
sed -i.bak "s/^# exclude = /exclude = /" "$CONF"; rm -f "$CONF.bak"
bash "$L" collect >/dev/null 2>&1; rc=$?
eq "collect runs with the exclude set" 0 "$rc"
got="$(cd "$TMP/wiki/raw/chats" 2>/dev/null && find . -name '*.jsonl' | LC_ALL=C sort)"
eq "the personal chats arrive" 2 "$(printf '%s\n' "$got" | grep -c 'keep')"
eq "no work chat arrives" "" "$(printf '%s\n' "$got" | grep -v keep | grep -iE 'employerco|wrk|/w[0-9]\.jsonl|forgeco|agent-v')"

# The digest pass decides again, on a header, whatever reached the wiki another way.
rx="$(python3 "$SRC/lib/config.py" "$CONF" | sed -n 's/^BRAIN_EXCLUDE=//p')"
eq "the form parses, and the exclude comes through whole" 'employerco|(?<![a-z0-9])wrk(?![a-z0-9])|forgeco' "$rx"
dig() { BRAIN_EXCLUDE="$rx" PYTHONPATH="$SRC/lib" python3 -c 'import sys, brain_digest as b; print(b.excluded(b.excluder(), "", sys.argv[1]))' "$1"; }
for f in "-Users-o-src-github-com-EmployerCo-next" "/Users/o/src/github.com/employerco/core" "wrk:wrk-voice" "forgeco"; do
  eq "digest: excluded: $f" True "$(dig "$f")"
done
eq "digest: a personal folder is not" False "$(dig "-Users-o-src-personal")"

# exclude-check: a machine asks its own config about a path, and nothing is printed of the path or the terms
out="$(bash "$L" exclude-check /Users/o/src/github.com/EmployerCo/next /Users/o/src/wrk-tools 2>&1)"; rc=$?
eq "exclude-check: every path excluded, exit 0" 0 "$rc"
eq "exclude-check: a count only" "2 of 2 excluded" "$out"
out="$(bash "$L" exclude-check /Users/o/src/github.com/EmployerCo/next /Users/o/src/personal 2>&1)"; rc=$?
eq "exclude-check: one not excluded, exit 1" 1 "$rc"
eq "exclude-check: it says how many, and no path" "1 of 2 excluded" "$out"
eq "exclude-check: a path with no args is a usage error" 2 "$(bash "$L" exclude-check >/dev/null 2>&1; echo $?)"
sed -i.bak "/^exclude = /d" "$CONF"; rm -f "$CONF.bak"
eq "exclude-check: no exclude set, refused" 2 "$(bash "$L" exclude-check /x >/dev/null 2>&1; echo $?)"
if [ "$(nfails)" -eq 0 ]; then echo "all ok"; else echo "$(nfails) failed"; exit 1; fi
