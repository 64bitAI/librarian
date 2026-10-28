#!/usr/bin/env bash
# `librarian collect` (and brain_digest.py collect-list) against synthetic chat trees in a throwaway
# HOME: work folders and temp folders never reach the list; collect copies into the wiki, or into
# another wiki with --to (a local path, or host:/path over --rsh). rsync is a stub that records its
# argv and the --files-from list, then runs the real rsync with a remote destination (host:/path)
# mapped to $TMP/remote/path. No network. Fixture chats are synthetic.
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
REAL_RSYNC="$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v rsync)"
. "$(dirname "$0")/.hermetic"
mkdir -p "$TMP/bin" "$TMP/remote"
export PATH="$TMP/bin:$PATH"
export RLOG="$TMP/rlog" REAL_RSYNC REMOTE="$TMP/remote" TMPDIR="$TMP/tmpdir"; mkdir -p "$TMPDIR"

cat > "$TMP/bin/rsync" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$RLOG"
args=(); skip=""
for a in "$@"; do
  if [ -n "$skip" ]; then skip=""; continue; fi
  case "$a" in
    -e) skip=1; continue ;;
    --files-from=*) cp "${a#--files-from=}" "$RLOG.list" ;;
    *:/*) a="$REMOTE/${a#*:/}" ;;
  esac
  args+=("$a")
done
[ -z "${RSYNC_FAIL:-}" ] || exit 23
exec "$REAL_RSYNC" "${args[@]}"
SH
printf '#!/bin/sh\nexit 97\n' > "$TMP/bin/claude"   # never called here
chmod +x "$TMP/bin/"*

# --- fixtures: the Claude home is under the hermetic HOME -----------------------------------------
BR="$TMP/brain"; mkdir -p "$BR/raw/chats"
CONF="$TMP/librarian.toml"; export LIBRARIAN_CONFIG="$CONF"
SD="$TMP/state"
setconf() { printf 'wiki_dir = "%s"\nhost = "host1"\nstate_dir = "%s"\ncollect_from = "%s"\nexclude = '"'%s'"'\n' "$BR" "$SD" "$HOME/.claude/projects" 'employerco|(?<![a-z0-9])wrk(?![a-z0-9])' > "$CONF"; }
cc() { # cc FOLDER FILE CWD [TITLE]: a Claude Code session whose second record carries CWD
  local d="$HOME/.claude/projects/$1"; mkdir -p "$(dirname "$d/$2")"
  {
    echo '{"type":"summary","summary":"fixture"}'
    printf '{"type":"user","cwd":"/Users/o/src/personal","message":{"role":"user","content":"hello"}}\n'
    printf '{"type":"assistant","cwd":"%s","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}\n' "$3"
    [ -z "${4:-}" ] || printf '{"type":"ai-title","aiTitle":"%s"}\n' "$4"
  } > "$d/$2"
}
P=/Users/o/src/personal
cc -Users-o-src-personal s1.jsonl "$P" "Garden plan"
cc -Users-o-src-personal s1/subagents/agent-a.jsonl "$P"
mkdir -p "$HOME/.claude/projects/-Users-o-src-personal/s1/tool-results" "$HOME/.claude/projects/-Users-o-src-personal/memory"
echo out > "$HOME/.claude/projects/-Users-o-src-personal/s1/tool-results/t.txt"
echo mem > "$HOME/.claude/projects/-Users-o-src-personal/memory/MEMORY.md"
touch -t 202001021234.56 "$HOME/.claude/projects/-Users-o-src-personal/s1.jsonl"
cc -Users-o-src-employerco-app w1.jsonl /Users/o/src/employerco/app
cc -private-tmp t1.jsonl /private/tmp
cc -private-tmp-claude-501--Users-o-src-personal-abc-scratchpad t2.jsonl /private/tmp/claude-501/x/scratchpad
cc -private-var-folders-5g-abc-T t3.jsonl /private/var/folders/5g/abc/T
cc -Users-o-src-mixed m1.jsonl /Users/o/src/mixed
cc -Users-o-src-mixed m2.jsonl /Users/o/src/wrk/thing
cc -Users-o-src-mixed m2/subagents/agent-b.jsonl /Users/o/src/mixed
cc -Users-o-src-mixed m3.jsonl /Users/o/src/mixed "wrk rollout plan"
# A session that started in a temp folder goes; one that only visits the scratchpad later stays.
cc -Users-o-src-other o1.jsonl /Users/o/src/other
sed -i.bak 's|"cwd":"/Users/o/src/personal"|"cwd":"/private/var/folders/zz/T/tmp.q1/cwd"|' "$HOME/.claude/projects/-Users-o-src-other/o1.jsonl"
rm -f "$HOME/.claude/projects/-Users-o-src-other/o1.jsonl.bak"
cc -Users-o-src-personal s8.jsonl /private/tmp/claude-501/x/scratchpad
WANT="claude-code/host1/-Users-o-src-mixed/m1.jsonl
claude-code/host1/-Users-o-src-personal/s1.jsonl
claude-code/host1/-Users-o-src-personal/s1/subagents/agent-a.jsonl
claude-code/host1/-Users-o-src-personal/s8.jsonl"
tree() { (cd "$1" && find . -type f | sed 's|^\./||' | LC_ALL=C sort); }
mtime() { python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$1"; }
run() { : > "$RLOG"; rm -f "$RLOG.list"; bash "$SRC/bin/librarian" collect "$@" 2>&1; echo "rc=$?"; }
lines() { printf '%s\n' "$1" | grep -vc '^rc='; }
DIG="$SRC/lib/brain_digest.py"; export BRAIN_EXCLUDE='employerco|(?<![a-z0-9])wrk(?![a-z0-9])'

# --- the list itself -------------------------------------------------------------------------------
L="$(python3 "$DIG" collect-list host1 "" "$HOME/.claude/projects" | LC_ALL=C sort)"
eq "collect-list: only personal chats, in the wiki's layout" "$WANT" "$L"
L2="$(BRAIN_EXCLUDE=mixed python3 "$DIG" collect-list host1 "" "$HOME/.claude/projects" | LC_ALL=C sort)"
eq "collect-list: BRAIN_EXCLUDE is the whole rule" "$({ printf '%s\n' "$WANT" | grep claude-code | grep -v mixed
  echo claude-code/host1/-Users-o-src-employerco-app/w1.jsonl; } | LC_ALL=C sort)" "$L2"
eq "collect-list: no BRAIN_EXCLUDE excludes no work folder" 1 "$(env -u BRAIN_EXCLUDE python3 "$DIG" collect-list host1 "" "$HOME/.claude/projects" | grep -c employerco-app/w1.jsonl)"
eq "collect-list: missing sources are skipped" "" "$(python3 "$DIG" collect-list host1 "" "$TMP/none")"

# A subagent's type (its sibling agent-*.meta.json agentType) is matched too: a wrk subagent run from
# a personal project stays here; therapy and legal stay when BRAIN_EXCLUDE names them; food travels
# with its meta (the digest pass checks the type again). A subagent with no meta is kept as before.
SA="$HOME/.claude/projects/-Users-o-src-personal/s1/subagents"
for a in v:wrk:wrk-voice t:therapy:therapy l:legal:legal f:food:food; do
  cp "$SA/agent-a.jsonl" "$SA/agent-${a%%:*}.jsonl"; printf '{"agentType":"%s","description":"x"}\n' "${a#*:}" > "$SA/agent-${a%%:*}.meta.json"
done
L="$(python3 "$DIG" collect-list host1 "" "$HOME/.claude/projects" | grep /subagents/ | LC_ALL=C sort | tr '\n' ' ')"
eq "collect-list: a wrk subagent stays, others travel with their meta" "$(printf '%s ' \
  claude-code/host1/-Users-o-src-personal/s1/subagents/agent-a.jsonl \
  claude-code/host1/-Users-o-src-personal/s1/subagents/agent-f.jsonl claude-code/host1/-Users-o-src-personal/s1/subagents/agent-f.meta.json \
  claude-code/host1/-Users-o-src-personal/s1/subagents/agent-l.jsonl claude-code/host1/-Users-o-src-personal/s1/subagents/agent-l.meta.json \
  claude-code/host1/-Users-o-src-personal/s1/subagents/agent-t.jsonl claude-code/host1/-Users-o-src-personal/s1/subagents/agent-t.meta.json)" "$L"
L="$(BRAIN_EXCLUDE='employerco|(?<![a-z0-9])wrk(?![a-z0-9])|therapy|legal' python3 "$DIG" collect-list host1 "" "$HOME/.claude/projects" | grep /subagents/ | sed 's|.*/||' | LC_ALL=C sort | tr '\n' ' ')"
eq "collect-list: BRAIN_EXCLUDE with therapy|legal keeps those subagents here; food still travels" "agent-a.jsonl agent-f.jsonl agent-f.meta.json " "$L"
printf 'not json' > "$SA/agent-f.meta.json"
eq "collect-list: an unreadable meta keeps the subagent" 1 "$(python3 "$DIG" collect-list host1 "" "$HOME/.claude/projects" | grep -c '/agent-f.jsonl$')"
rm -f "$SA"/agent-[vtlf].*
unset BRAIN_EXCLUDE   # from here the config's exclude applies

# --- into this host's wiki ---------------------------------------------------------------------------
setconf
out="$(run)"
eq "local: exit 0" 1 "$(printf '%s\n' "$out" | grep -c '^rc=0$')"
eq "local: one line, the count" "1 1" "$(lines "$out") $(printf '%s\n' "$out" | grep -c 'collected 4 chat files into the brain')"
eq "local: exactly the listed files arrive" "$WANT" "$(tree "$BR/raw/chats")"
eq "local: the list handed to rsync" "$WANT" "$(LC_ALL=C sort "$RLOG.list")"
eq "local: a session keeps its mtime" "$(mtime "$HOME/.claude/projects/-Users-o-src-personal/s1.jsonl")" "$(mtime "$BR/raw/chats/claude-code/host1/-Users-o-src-personal/s1.jsonl")"
eq "local: files arrive, not links" 0 "$(find "$BR/raw/chats" -type l | wc -l | tr -d ' ')"
eq "local: rsync -aL, never --delete" "1 0" "$(grep -cE -- '(^| )-aL( |$)' "$RLOG") $(grep -c -- '--delete' "$RLOG")"
eq "local: stamp written in state_dir" 1 "$([ -s "$SD/.brain-collected" ] && echo 1 || echo 0)"
eq "no stage left behind" "" "$(ls -A "$TMPDIR")"
eq "no lock left behind" 0 "$([ -d "$SD/.brain-collect.lock" ] && echo 1 || echo 0)"
# A copy already there is never removed (no --delete).
echo keep > "$BR/raw/chats/claude-code/host1/-Users-o-src-personal/gone.jsonl"
run >/dev/null; eq "local: a chat gone at the source stays in the wiki" 1 "$([ -f "$BR/raw/chats/claude-code/host1/-Users-o-src-personal/gone.jsonl" ] && echo 1 || echo 0)"
rm -f "$BR/raw/chats/claude-code/host1/-Users-o-src-personal/gone.jsonl"
# No collect_from: refused, never a guess at ~/.claude/projects (another login's chats).
grep -v '^collect_from' "$CONF" > "$CONF.n"; mv "$CONF.n" "$CONF"
out="$(run)"
eq "no collect_from: exit 0, one line, no rsync" "1 1 0" "$(printf '%s\n' "$out" | grep -c '^rc=0$') $(printf '%s\n' "$out" | grep -c 'no source set (collect_from, LIBRARIAN_COLLECT_FROM); nothing collected') $(grep -c . "$RLOG")"
out="$(LIBRARIAN_COLLECT_FROM='' run)"
eq "empty LIBRARIAN_COLLECT_FROM: refused too" "1 0" "$(printf '%s\n' "$out" | grep -c 'no source set') $(grep -c . "$RLOG")"
setconf
# collect_from names the Claude projects folder
mkdir -p "$HOME/.claude-work/projects/-Users-o-src-workonly"
cp "$HOME/.claude/projects/-Users-o-src-personal/s1.jsonl" "$HOME/.claude-work/projects/-Users-o-src-workonly/wk.jsonl"
out="$(LIBRARIAN_COLLECT_FROM="$HOME/.claude-work/projects" run)"
eq "collect_from: that folder's chats, under this host" "1 claude-code/host1/-Users-o-src-workonly/wk.jsonl" "$(printf '%s\n' "$out" | grep -c 'collected 1 chat files') $(cat "$RLOG.list")"
rm -rf "$BR/raw/chats/claude-code/host1/-Users-o-src-workonly"
out="$(LIBRARIAN_COLLECT_FROM=relative/path run)"
eq "collect_from must be absolute: exit 0, no rsync" "1 0" "$(printf '%s\n' "$out" | grep -c '^rc=0$') $(grep -c . "$RLOG")"
eq "a held lock with a live holder: skipped" 1 "$(mkdir -p "$SD/.brain-collect.lock"; sleep 30 & echo $! > "$SD/.brain-collect.lock/pid"; o="$(run)"; kill "$(cat "$SD/.brain-collect.lock/pid")"; rm -rf "$SD/.brain-collect.lock"; printf '%s\n' "$o" | grep -c 'another collection is running')"

# --- the hourly stamp ------------------------------------------------------------------------------
out="$(run --hourly)"; eq "hourly: a second run within the hour does nothing" "1 0 0" "$(printf '%s\n' "$out" | grep -c '^rc=0$') $(wc -l < "$RLOG" | tr -d ' ') $(lines "$out")"
echo $(( $(date +%s) - 4000 )) > "$SD/.brain-collected"
out="$(run --hourly)"; eq "hourly: runs again after an hour" 1 "$(wc -l < "$RLOG" | tr -d ' ')"
out="$(run)"; eq "without --hourly: the stamp is ignored" 1 "$(wc -l < "$RLOG" | tr -d ' ')"

# --- --to: another wiki, local or over a remote shell ---------------------------------------------------
rm -f "$SD/.brain-collected"
O="$TMP/other"; mkdir -p "$O"
out="$(run --to "$O")"
eq "--to DIR: exactly the listed files arrive there" "$WANT" "$(tree "$O/raw/chats")"
eq "--to DIR: nothing new in this host's wiki" 0 "$(find "$BR/raw/chats" -newer "$SD/.brain-collected" -type f | wc -l | tr -d ' ')"
mkdir -p "$REMOTE/srv/brain/raw"
out="$(run --to peer.example:/srv/brain --rsh "ssh -o BatchMode=yes")"
eq "--to host:/dir: exit 0, one line" "1 1" "$(printf '%s\n' "$out" | grep -c '^rc=0$') $(lines "$out")"
eq "--to host:/dir: says where" 1 "$(printf '%s\n' "$out" | grep -c 'copied 4 chat files to peer.example$')"
eq "--to host:/dir: pushes over the remote shell given" 1 "$(grep -c -- '-e ssh -o BatchMode=yes .*peer.example:/srv/brain/raw/chats/$' "$RLOG")"
eq "--to host:/dir: exactly the listed files arrive" "$WANT" "$(tree "$REMOTE/srv/brain/raw/chats")"
eq "--to host:/dir: mtime kept" "$(mtime "$HOME/.claude/projects/-Users-o-src-personal/s1.jsonl")" "$(mtime "$REMOTE/srv/brain/raw/chats/claude-code/host1/-Users-o-src-personal/s1.jsonl")"
eq "--to host:/dir: an I/O timeout, never --delete" "1 0" "$(grep -c -- '--timeout=300' "$RLOG") $(grep -c -- '--delete' "$RLOG")"
rm -f "$SD/.brain-collected"
out="$(RSYNC_FAIL=1 run --to peer.example:/srv/brain)"; eq "a failed push: exit 0, one line, no stamp" "1 1 0" "$(printf '%s\n' "$out" | grep -c '^rc=0$') $(lines "$out") $([ -f "$SD/.brain-collected" ] && echo 1 || echo 0)"
out="$(run --to relative/dir)"; eq "--to neither absolute nor host:/path: exit 0, one line, no rsync" "1 1 0" "$(printf '%s\n' "$out" | grep -c '^rc=0$') $(lines "$out") $(grep -c . "$RLOG")"
eq "a bad option: usage, exit 2" 1 "$(run --bogus | grep -c '^rc=2$')"

# --- no wiki set: nothing collected ------------------------------------------------------------------
printf 'host = "host1"\nstate_dir = "%s"\n' "$SD" > "$CONF"
out="$(run)"; eq "no wiki_dir: exit 0, one line, no rsync" "1 1 0" "$(printf '%s\n' "$out" | grep -c '^rc=0$') $(lines "$out") $(grep -c . "$RLOG")"

# --- the ingest collects before its gate ----------------------------------------------------------------
setconf; rm -rf "$BR/raw/chats"; mkdir -p "$BR/raw/chats"; git -C "$BR" init -q
mkdir -p "$TMP/gates"; printf 'echo "test gate"\nexit 10\n' > "$TMP/gates/g"; printf 'gate_cmd = "%s"\n' "$TMP/gates/g" >> "$CONF"
out="$(bash "$SRC/bin/librarian" ingest 2>&1; echo "rc=$?")"
eq "ingest: exit 0" 1 "$(printf '%s\n' "$out" | grep -c '^rc=0$')"
eq "ingest: collected, then gated" "collected gated" "$(printf '%s\n' "$out" | sed -n 's/.*\(collected\) 4 chat files.*/\1/p; s/.*\(gated\): test gate.*/\1/p' | tr '\n' ' ' | sed 's/ $//')"
eq "ingest: the chats arrived" "$WANT" "$(tree "$BR/raw/chats")"
out="$(RSYNC_FAIL=1 bash "$SRC/bin/librarian" ingest 2>&1; echo "rc=$?")"
eq "ingest: a failed collection never fails the run" "1 1" "$(printf '%s\n' "$out" | grep -c '^rc=0$') $(printf '%s\n' "$out" | grep -c 'gated: test gate')"

fails="$(nfails)"; [ "$fails" = 0 ] && echo "all ok" || { echo "$fails failed"; exit 1; }
