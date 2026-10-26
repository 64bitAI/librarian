#!/usr/bin/env bash
# brain-collect.sh (and brain_digest.py collect-list) against synthetic chat trees in a throwaway
# HOME: work folders, temp folders, Codex consults and Gemini slugs without a folder never reach the
# list; the primary copies into its own brain, the standby pushes to the primary's (asked of it).
# rsync is a stub that records its argv and the --files-from list, then runs the real rsync with a
# remote destination (host:/path) mapped to $TMP/remote/path; ssh is a stub answering stack-role.sh.
# No network. Fixture chats are synthetic.
set -u
SRC="$(cd "$(dirname "$0")/../.." && pwd)"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
REAL_RSYNC="$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v rsync)"
. "$(dirname "$0")/.hermetic"
cp -R "$SRC/scripts" "$SRC/infra" "$SRC/gates" "$TMP/"; mkdir -p "$TMP/bin" "$TMP/remote"
sed -i.bak "s|^export PATH=\"/opt/homebrew/bin|export PATH=\"$TMP/bin:/opt/homebrew/bin|" "$TMP/scripts/common.sh"
grep -q "^export PATH=\"$TMP/bin:" "$TMP/scripts/common.sh" || { echo "FAIL could not pin the stub PATH"; exit 1; }
export RLOG="$TMP/rlog" SLOG="$TMP/slog" REAL_RSYNC REMOTE="$TMP/remote" TMPDIR="$TMP/tmpdir"; mkdir -p "$TMPDIR"

cat > "$TMP/bin/rsync" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$RLOG"
# The standby-sync pass must have let go of its lock before a long push.
[ ! -d "$SWARM_STATE_DIR/standby/.lock" ] || printf '%s\n' "$*" >> "$RLOG.lock"
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
cat > "$TMP/bin/ssh" <<'SH'
#!/bin/bash
c="${*: -1}"; printf '%s\n' "$c" >> "$SLOG"
[ -z "${SSH_DOWN:-}" ] || exit 255
case "$c" in
  *"stack-role.sh identity"*) exit 0 ;;
  *"stack-role.sh brain"*) [ -z "${PEER_OLD:-}" ] || { echo "usage: stack-role.sh ..." >&2; exit 2; }; echo "${PEER_BRAIN:-/srv/brain}" ;;
  *"stack-role.sh dir"*) echo /srv/state ;;
  *) exit 0 ;;
esac
SH
for c in docker curl; do printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/$c"; done
# shellcheck disable=SC2016  # TS_NET is the stub's, expanded when it runs
printf '#!/bin/sh\necho "{\\"BackendState\\":\\"Running\\",\\"MagicDNSSuffix\\":\\"${TS_NET:-ts.example}\\"}"\n' > "$TMP/bin/tailscale"
chmod +x "$TMP/bin/"*

# --- fixtures: the personal swarm's Claude, Codex and Gemini homes are under the hermetic HOME ----
S="$HOME/.local/state/swarm/personal"; mkdir -p "$S"
BR="$TMP/brain"; mkdir -p "$BR/raw/chats"
setenv() { printf 'SWARM_MACHINE=host1\nSWARM_BRAIN_DIR=%s\n' "$BR" > "$S/.env"; [ $# = 0 ] || printf '%s\n' "$@" >> "$S/.env"; }
setrole() { printf 'role=%s\nepoch=3\n' "$1" > "$S/.role"; }
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
cx() { # cx NAME ORIGINATOR CWD: a Codex rollout (an empty CWD writes no session_meta)
  local d="$HOME/.codex/sessions/2026/10/01"; mkdir -p "$d"
  {
    [ -z "$3" ] || printf '{"type":"session_meta","payload":{"id":"x","cwd":"%s","originator":"%s"}}\n' "$3" "$2"
    echo '{"type":"event_msg","payload":{"type":"user_message","message":"hello"}}'
  } > "$d/rollout-2026-10-01T10-00-00-$1.jsonl"
}
cx a codex_cli_rs "$P"; cx b codex_cli_rs /Users/o/src/employerco/api; cx c codex_exec "$P"; cx d codex_cli_rs ""
cx e codex_cli_rs /tmp/x; cx f codex_cli_rs "$P"
echo '{"type":"turn_context","payload":{"cwd":"/tmp/later"}}' >> "$HOME/.codex/sessions/2026/10/01/rollout-2026-10-01T10-00-00-f.jsonl"
cx g codex_cli_rs "$P"
echo '{"type":"turn_context","payload":{"cwd":"/Users/o/src/wrk/api"}}' >> "$HOME/.codex/sessions/2026/10/01/rollout-2026-10-01T10-00-00-g.jsonl"
touch -t 202001021234.56 "$HOME/.codex/sessions/2026/10/01/rollout-2026-10-01T10-00-00-a.jsonl"
gm() { # gm SLUG ROOT|-: a Gemini slug with one session (- writes no .project_root)
  local d="$HOME/.gemini/tmp/$1"; mkdir -p "$d/chats" "$d/logs"
  [ "$2" = - ] || printf '%s\n' "$2" > "$d/.project_root"
  echo '{"type":"user","content":"hello"}' > "$d/chats/session-2026-10-01T10-00-$1.jsonl"
}
gm personal "$P"; gm noroot -; gm tmp /private/tmp; gm g /private/tmp/claude-501/g; gm work /Users/o/src/employerco/x
mkdir -p "$HOME/.gemini/tmp/0123abcd"; echo '[]' > "$HOME/.gemini/tmp/0123abcd/logs.json"

WANT="claude-code/host1/-Users-o-src-mixed/m1.jsonl
claude-code/host1/-Users-o-src-personal/s1.jsonl
claude-code/host1/-Users-o-src-personal/s1/subagents/agent-a.jsonl
claude-code/host1/-Users-o-src-personal/s8.jsonl
codex/host1/2026/10/01/rollout-2026-10-01T10-00-00-a.jsonl
codex/host1/2026/10/01/rollout-2026-10-01T10-00-00-f.jsonl
gemini/host1/personal/.project_root
gemini/host1/personal/session-2026-10-01T10-00-personal.jsonl"
tree() { (cd "$1" && find . -type f | sed 's|^\./||' | LC_ALL=C sort); }
mtime() { python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$1"; }
run() { : > "$RLOG"; : > "$SLOG"; rm -f "$RLOG.list" "$RLOG.lock"; bash "$TMP/scripts/brain-collect.sh" --swarm personal "$@" 2>&1; echo "rc=$?"; }
lines() { printf '%s\n' "$1" | grep -vc '^rc='; }

# --- the list itself -------------------------------------------------------------------------------
L="$(python3 "$TMP/scripts/brain_digest.py" collect-list host1 "" "$HOME/.claude/projects" "$HOME/.codex/sessions" "$HOME/.gemini/tmp" | LC_ALL=C sort)"
eq "collect-list: only personal chats, in the brain's layout" "$WANT" "$L"
L2="$(BRAIN_EXCLUDE=mixed python3 "$TMP/scripts/brain_digest.py" collect-list host1 "" "$HOME/.claude/projects" "" "" | LC_ALL=C sort)"
eq "collect-list: BRAIN_EXCLUDE replaces the default" "$({ printf '%s\n' "$WANT" | grep claude-code | grep -v mixed
  echo claude-code/host1/-Users-o-src-employerco-app/w1.jsonl; } | LC_ALL=C sort)" "$L2"
eq "collect-list: missing sources are skipped" "" "$(python3 "$TMP/scripts/brain_digest.py" collect-list host1 "" "$TMP/none" "" "$TMP/none2")"

# --- the primary: a local copy into its own brain --------------------------------------------------
setenv; setrole primary
out="$(run run)"
eq "primary: exit 0" 1 "$(printf '%s\n' "$out" | grep -c '^rc=0$')"
eq "primary: one line, the count" "1 1" "$(lines "$out") $(printf '%s\n' "$out" | grep -c 'collected 8 chat files into the brain')"
eq "primary: exactly the listed files arrive" "$WANT" "$(tree "$BR/raw/chats")"
eq "primary: the list handed to rsync" "$WANT" "$(LC_ALL=C sort "$RLOG.list")"
eq "primary: a session keeps its mtime" "$(mtime "$HOME/.claude/projects/-Users-o-src-personal/s1.jsonl")" "$(mtime "$BR/raw/chats/claude-code/host1/-Users-o-src-personal/s1.jsonl")"
eq "primary: a rollout keeps its mtime" "$(mtime "$HOME/.codex/sessions/2026/10/01/rollout-2026-10-01T10-00-00-a.jsonl")" "$(mtime "$BR/raw/chats/codex/host1/2026/10/01/rollout-2026-10-01T10-00-00-a.jsonl")"
eq "primary: files arrive, not links" 0 "$(find "$BR/raw/chats" -type l | wc -l | tr -d ' ')"
eq "primary: rsync -aL, never --delete" "1 0" "$(grep -cE -- '(^| )-aL( |$)' "$RLOG") $(grep -c -- '--delete' "$RLOG")"
eq "primary: no ssh" 0 "$(wc -l < "$SLOG" | tr -d ' ')"
eq "primary: stamp written" 1 "$([ -s "$S/.brain-collected" ] && echo 1 || echo 0)"
eq "no stage left behind" "" "$(ls -A "$TMPDIR")"
# A copy already there is never removed (no --delete), and an older copy is replaced.
echo keep > "$BR/raw/chats/claude-code/host1/-Users-o-src-personal/gone.jsonl"
run run >/dev/null; eq "primary: a chat gone at the source stays in the brain" 1 "$([ -f "$BR/raw/chats/claude-code/host1/-Users-o-src-personal/gone.jsonl" ] && echo 1 || echo 0)"

# --- the hourly stamp ------------------------------------------------------------------------------
out="$(run hourly)"; eq "hourly: a second run within the hour does nothing" "1 0 0" "$(printf '%s\n' "$out" | grep -c '^rc=0$') $(wc -l < "$RLOG" | tr -d ' ') $(lines "$out")"
echo $(( $(date +%s) - 4000 )) > "$S/.brain-collected"
out="$(run hourly)"; eq "hourly: runs again after an hour" 1 "$(wc -l < "$RLOG" | tr -d ' ')"
out="$(run run)"; eq "run: ignores the stamp" 1 "$(wc -l < "$RLOG" | tr -d ' ')"

# --- the standby: a push to the primary's brain, asked of the primary ------------------------------
setenv SWARM_PAIR_SSH=peer.example; setrole standby; rm -f "$S/.brain-collected"
mkdir -p "$REMOTE/srv/brain/raw"   # the primary's brain (raw/chats is made by the push)
out="$(run run)"
eq "standby: exit 0, one line" "1 1" "$(printf '%s\n' "$out" | grep -c '^rc=0$') $(lines "$out")"
eq "standby: says where" 1 "$(printf '%s\n' "$out" | grep -c 'copied 8 chat files to the primary')"
eq "standby: asks the primary for its brain" 1 "$(grep -c 'scripts/stack-role.sh brain' "$SLOG")"
eq "standby: pushes over the pair ssh to that brain" 1 "$(grep -c -- '-e ssh .*peer.example:/srv/brain/raw/chats/$' "$RLOG")"
eq "standby: exactly the listed files arrive" "$WANT" "$(tree "$REMOTE/srv/brain/raw/chats")"
eq "standby: mtime kept" "$(mtime "$HOME/.claude/projects/-Users-o-src-personal/s1.jsonl")" "$(mtime "$REMOTE/srv/brain/raw/chats/claude-code/host1/-Users-o-src-personal/s1.jsonl")"
eq "standby: never --delete" 0 "$(grep -c -- '--delete' "$RLOG")"
eq "standby: nothing copied into its own brain" 0 "$(find "$BR/raw/chats" -newer "$S/.role" -type f | wc -l | tr -d ' ')"
eq "standby: stamp written" 1 "$([ -s "$S/.brain-collected" ] && echo 1 || echo 0)"
rm -f "$S/.brain-collected"
out="$(SSH_DOWN=1 run hourly)"
eq "unreachable peer: exit 0, one line" "1 1" "$(printf '%s\n' "$out" | grep -c '^rc=0$') $(lines "$out")"
eq "unreachable peer: no rsync, no stamp" "0 0" "$(wc -l < "$RLOG" | tr -d ' ') $([ -f "$S/.brain-collected" ] && echo 1 || echo 0)"
out="$(PEER_OLD=1 run run)"; eq "peer without a brain answer: exit 0, one line, no rsync" "1 1 0" "$(printf '%s\n' "$out" | grep -c '^rc=0$') $(lines "$out") $(wc -l < "$RLOG" | tr -d ' ')"
out="$(PEER_BRAIN=relative/path run run)"; eq "peer answer not a path: exit 0, one line, no rsync" "1 1 0" "$(printf '%s\n' "$out" | grep -c '^rc=0$') $(lines "$out") $(wc -l < "$RLOG" | tr -d ' ')"
out="$(RSYNC_FAIL=1 run run)"; eq "push fails: exit 0, one line, no stamp" "1 1 0" "$(printf '%s\n' "$out" | grep -c '^rc=0$') $(lines "$out") $([ -f "$S/.brain-collected" ] && echo 1 || echo 0)"
setenv SWARM_PAIR_SSH=peer.example SWARM_TAILNET_SUFFIX=ts.example
out="$(TS_NET=other.example run run)"; eq "off the swarm's tailnet: exit 0, one line, no ssh" "1 1 0" "$(printf '%s\n' "$out" | grep -c '^rc=0$') $(lines "$out") $(wc -l < "$SLOG" | tr -d ' ')"
setenv SWARM_PAIR_SSH=peer.example SWARM_IDENTITY=personal
out="$(run run)"; eq "identity mismatch: exit 0, one line, no rsync" "1 1 0" "$(printf '%s\n' "$out" | grep -c '^rc=0$') $(lines "$out") $(wc -l < "$RLOG" | tr -d ' ')"
setenv; setrole standby
out="$(run run)"; eq "standby without a pair: exit 0, one line, no rsync" "1 1 0" "$(printf '%s\n' "$out" | grep -c '^rc=0$') $(lines "$out") $(wc -l < "$RLOG" | tr -d ' ')"

# --- a swarm without a brain collects nothing (a work swarm's Claude home never travels) -----------
printf 'SWARM_MACHINE=host1\n' > "$S/.env"; setrole primary
out="$(SWARM_BRAIN_DIR="$BR" run run)"; eq "no SWARM_BRAIN_DIR in the swarm's .env: exit 0, one line, no rsync" "1 1 0" "$(printf '%s\n' "$out" | grep -c '^rc=0$') $(lines "$out") $(wc -l < "$RLOG" | tr -d ' ')"

# --- stack-role.sh answers the brain directory ------------------------------------------------------
setenv
eq "stack-role.sh brain" "$BR" "$(bash "$TMP/scripts/stack-role.sh" --swarm personal brain 2>/dev/null | tail -1)"

# --- the hooks ---------------------------------------------------------------------------------------
# standby-sync's standby pass: the collector runs after the pass lets go of its lock.
setenv SWARM_PAIR_SSH=peer.example; setrole standby; rm -f "$S/.brain-collected"; rm -rf "$REMOTE/srv/brain"; mkdir -p "$REMOTE/srv/brain/raw"
: > "$RLOG"; : > "$SLOG"; rm -f "$RLOG.lock"
out="$(bash "$TMP/scripts/standby-sync.sh" --swarm personal run 2>&1; echo "rc=$?")"
eq "standby-sync: exit 0" 1 "$(printf '%s\n' "$out" | grep -c '^rc=0$')"
eq "standby-sync: chats pushed" 1 "$(printf '%s\n' "$out" | grep -c 'copied 8 chat files to the primary')"
eq "standby-sync: the pull held the sync lock, the collector did not" "1 0 1" "$(cat "$RLOG.lock" 2>/dev/null | grep -c 'srv/state/standby/latest') $(cat "$RLOG.lock" 2>/dev/null | grep -c 'brain/raw/chats') $(grep -c 'peer.example:/srv/brain/raw/chats/' "$RLOG")"
eq "standby-sync: no lock left" 0 "$([ -d "$S/standby/.lock" ] && echo 1 || echo 0)"
out="$(bash "$TMP/scripts/standby-sync.sh" --swarm personal run 2>&1)"
eq "standby-sync: hourly, so the next pass does not push again" 0 "$(printf '%s\n' "$out" | grep -c 'chat files')"
# standby-sync's standby pass also fast-forwards a clean brain clone here; a dirty one is left, a failure never fatal.
UP="$TMP/brain-up"; CL="$TMP/brain-clone"; G="git -c user.name=t -c user.email=t@example.com"
git init -q "$UP" && : > "$UP/index.md" && git -C "$UP" add . && $G -C "$UP" commit -q -m one && git clone -q "$UP" "$CL"
printf 'x\n' > "$UP/index.md" && $G -C "$UP" commit -q -am two
printf 'SWARM_MACHINE=host1\nSWARM_BRAIN_DIR=%s\n' "$CL" > "$S/.env"; setrole standby; rm -f "$S/.brain-collected"
out="$(bash "$TMP/scripts/standby-sync.sh" --swarm personal run 2>&1; echo "rc=$?")"
eq "standby-sync: a clean brain clone is fast-forwarded" "$(git -C "$UP" rev-parse HEAD) 1" "$(git -C "$CL" rev-parse HEAD) $(printf '%s\n' "$out" | grep -c '^rc=0$')"
printf 'y\n' > "$UP/index.md" && $G -C "$UP" commit -q -am three
mkdir -p "$CL/raw/notes"; printf 'a note\n' > "$CL/raw/notes/n.md"
out="$(bash "$TMP/scripts/standby-sync.sh" --swarm personal run 2>&1; echo "rc=$?")"
eq "standby-sync: an untracked note does not block the pull" "$(git -C "$UP" rev-parse HEAD) 0" "$(git -C "$CL" rev-parse HEAD) $(printf '%s\n' "$out" | grep -c 'brain pull')"
rm -f "$CL/raw/notes/n.md"; printf 'z\n' > "$UP/index.md" && $G -C "$UP" commit -q -am four; printf 'dirty\n' >> "$CL/index.md"
out="$(bash "$TMP/scripts/standby-sync.sh" --swarm personal run 2>&1; echo "rc=$?")"
eq "standby-sync: a dirty brain clone is left, with a log line" "1 1 1" "$([ "$(git -C "$CL" rev-parse HEAD)" != "$(git -C "$UP" rev-parse HEAD)" ] && echo 1) $(printf '%s\n' "$out" | grep -c 'brain pull skipped') $(printf '%s\n' "$out" | grep -c '^rc=0$')"
git -C "$CL" checkout -q -- index.md; rm -rf "$UP"
out="$(bash "$TMP/scripts/standby-sync.sh" --swarm personal run 2>&1; echo "rc=$?")"
eq "standby-sync: a failed brain pull is logged and not fatal" "1 1" "$(printf '%s\n' "$out" | grep -c 'brain pull failed') $(printf '%s\n' "$out" | grep -c '^rc=0$')"
# brain-ingest run: the collector runs before the gate.
setenv; setrole primary; rm -rf "$BR/raw/chats"; mkdir -p "$BR/raw/chats"; git -C "$BR" init -q
mkdir -p "$S/gates"; printf 'echo "test gate"\nexit 10\n' > "$S/gates/brain-ingest"
out="$(bash "$TMP/scripts/brain-ingest.sh" --swarm personal run 2>&1; echo "rc=$?")"
eq "brain-ingest: exit 0" 1 "$(printf '%s\n' "$out" | grep -c '^rc=0$')"
eq "brain-ingest: collected, then gated" "collected gated" "$(printf '%s\n' "$out" | sed -n 's/.*\(collected\) 8 chat files.*/\1/p; s/.*\(gated\): test gate.*/\1/p' | tr '\n' ' ' | sed 's/ $//')"
eq "brain-ingest: the chats arrived" "$WANT" "$(tree "$BR/raw/chats")"
out="$(RSYNC_FAIL=1 bash "$TMP/scripts/brain-ingest.sh" --swarm personal run 2>&1; echo "rc=$?")"
eq "brain-ingest: a failed collection never fails the run" "1 1" "$(printf '%s\n' "$out" | grep -c '^rc=0$') $(printf '%s\n' "$out" | grep -c 'gated: test gate')"

fails="$(nfails)"; [ "$fails" = 0 ] && echo "all ok" || { echo "$fails failed"; exit 1; }
