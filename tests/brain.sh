#!/usr/bin/env bash
# brain_digest.py and brain-ingest.sh against a throwaway brain with a bare origin; claude is a stub
# that records its argv and prompt and writes a fake JSON result. No network, no real claude.
set -u
SRC="$(cd "$(dirname "$0")/../.." && pwd)"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$(dirname "$0")/.hermetic"
cp -R "$SRC/scripts" "$SRC/infra" "$TMP/"; mkdir -p "$TMP/bin"
# common.sh puts the real tools first on PATH: the copy under test keeps the stubs in front, so the real
# claude can never run from here.
sed -i.bak "s|^export PATH=\"/opt/homebrew/bin|export PATH=\"$TMP/bin:/opt/homebrew/bin|" "$TMP/scripts/common.sh"
grep -q "^export PATH=\"$TMP/bin:" "$TMP/scripts/common.sh" || { echo "FAIL could not pin the stub PATH"; exit 1; }
cat > "$TMP/bin/claude" <<'SH'
#!/bin/sh
: > "$CLOG"; for a in "$@"; do printf '%s\n' "$a" >> "$CLOG"; done
cat > "$CLOG.prompt"
echo call >> "$CLOG.calls"
d="$(date +%F)"
case "${CLAUDE_MODE:-ok}" in
  ok)
    mkdir -p wiki/topics; echo "# Topic (raw/digests/x.md)" > wiki/topics/fixture.md
    echo "- [Topic](wiki/topics/fixture.md): fixture" >> index.md
    printf '\n## [%s] ingest | n sessions\nfixture\n' "$d" >> log.md
    mkdir -p raw/digests && echo stray > raw/digests/extra.md
    echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.42,"result":"1 page"}' ;;
  fail)
    mkdir -p wiki/topics; echo partial > wiki/topics/partial.md; echo partial >> index.md
    printf '\n## [%s] ingest | n sessions\n' "$d" >> log.md
    echo '{"type":"result","subtype":"error_max_turns","is_error":true,"total_cost_usd":0.1}'; exit 1 ;;
  stray)
    echo "changed" >> sources.md; printf '\n## [%s] ingest | n\n' "$d" >> log.md
    echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.2}' ;;
esac
SH
for c in docker tailscale; do printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/$c"; done
chmod +x "$TMP/bin/"*
export CLOG="$TMP/clog"
unset ANTHROPIC_API_KEY OPENAI_API_KEY BRAIN_INGEST_CHARS BRAIN_COST_CAP_USD BRAIN_RUN_MAX_USD BRAIN_MONTH

# --- a brain with a bare origin ---------------------------------------------------------------------
BR="$TMP/brain"; OR="$TMP/origin.git"
git init -q --bare "$OR"; git init -q "$BR"
g() { git -C "$BR" -c user.email=t@t -c user.name=t "$@"; }
mkdir -p "$BR/wiki/topics" "$BR/raw/notes"
printf '# schema\n' > "$BR/CLAUDE.md"; printf '# Index\n' > "$BR/index.md"; printf '# Log\n' > "$BR/log.md"; printf '# Sources\n' > "$BR/sources.md"
touch "$BR/wiki/topics/.gitkeep" "$BR/raw/notes/.gitkeep"
printf 'raw/chats/**\n!raw/chats/**/\nraw/digests/**\nraw/.state/**\n' > "$BR/.gitignore"
g add -A; g commit -qm init; g branch -M main; g remote add origin "$OR"; g push -q -u origin main
git config --global user.email t@t; git config --global user.name t   # the hermetic HOME's identity for the job's commits

# --- fixtures: synthetic sessions ----------------------------------------------------------------
SECRET="sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
python3 - "$BR" "$SECRET" <<'PY'
import json, os, sys
brain, secret = sys.argv[1], sys.argv[2]
cc = os.path.join(brain, "raw/chats/claude-code/h1")
def w(path, recs):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for r in recs: f.write(json.dumps(r) + "\n")
def base(t, ts, **k):
    r = {"type": t, "timestamp": ts, "sessionId": "s1", "cwd": "/home/o/src/github.com/example/project-alpha", "gitBranch": "main", "isSidechain": False}
    r.update(k); return r
recs = [
    {"type": "ai-title", "aiTitle": "Fixture session"},
    base("user", "2026-10-01T10:00:00Z", message={"role": "user", "content": "OWNERPHRASE please use key " + secret + " now<system-reminder>REMINDERMARK</system-reminder>"}),
    base("assistant", "2026-10-01T10:00:05Z", message={"role": "assistant", "content": [{"type": "thinking", "thinking": "THINKMARK"}]}),
    base("assistant", "2026-10-01T10:00:06Z", message={"role": "assistant", "content": [{"type": "text", "text": "CLAUDEPHRASE checking"}, {"type": "tool_use", "name": "Bash", "input": {"command": "TOOLINPUTMARK"}}]}),
    base("user", "2026-10-01T10:00:07Z", toolUseResult={"stdout": "x"}, message={"role": "user", "content": [{"type": "tool_result", "content": "TOOLRESULTMARK"}]}),
    {"type": "api-request-blob", "message": {"content": [{"type": "tool_result", "content": "BLOBMARK"}]}},
    base("assistant", "2026-10-01T10:00:08Z", message={"role": "assistant", "content": [{"type": "tool_use", "name": "Edit", "input": {"x": "TOOLINPUTMARK"}}]}),
    base("assistant", "2026-10-01T10:00:09Z", message={"role": "assistant", "content": [{"type": "text", "text": "done; token=abcd1234efgh5678"}]}),
    base("user", "2026-10-01T10:01:00Z", isMeta=True, message={"role": "user", "content": "METAMARK skill body"}),
    base("user", "2026-10-01T10:02:00Z", message={"role": "user", "content": "<task-notification>TASKMARK</task-notification>"}),
    base("user", "2026-10-01T10:03:00Z", message={"role": "user", "content": "thanks"}),
]
w(os.path.join(cc, "-proj-a/s1.jsonl"), recs)
side = [base("user", "2026-10-01T11:00:00Z", isSidechain=True, message={"role": "user", "content": "SIDEMARK subagent brief"}),
        base("assistant", "2026-10-01T11:00:01Z", isSidechain=True, message={"role": "assistant", "content": [{"type": "text", "text": "subagent reply"}]})]
w(os.path.join(cc, "-proj-a/s1/subagents/agent-a1.jsonl"), side)        # parent exists: skipped
w(os.path.join(cc, "-proj-a/s9/subagents/agent-b2.jsonl"), side)        # the only record: digested
for i in range(3):   # three sessions of ~30k characters, oldest first by their first timestamp
    big = [base("user", "2026-09-0%dT09:00:00Z" % (i + 1), message={"role": "user", "content": "word " * 6000})]
    w(os.path.join(cc, "-proj-b/big%d.jsonl" % i), big)
huge = [base("user", "2026-08-01T09:00:00Z", message={"role": "user", "content": "lorem " * 20000})]
w(os.path.join(cc, "-proj-c/huge.jsonl"), huge)
ai = os.path.join(brain, "raw/chats/claude-ai/acct1/2026-10-05")
os.makedirs(ai, exist_ok=True)
json.dump([{"uuid": "c-1", "name": "AI chat title", "created_at": "2026-10-20T00:00:00Z", "updated_at": "2026-10-21T00:00:00Z",
            "chat_messages": [{"sender": "human", "text": "AIOWNER " + secret}, {"sender": "assistant", "content": [{"type": "text", "text": "AICLAUDE"}]}]}],
          open(os.path.join(ai, "conversations.json"), "w"))
PY
D="$BR/raw/digests"; DIG="$TMP/scripts/brain_digest.py"

# --- digests ------------------------------------------------------------------------------------
out="$(python3 "$DIG" digest "$BR")"
S1="$D/claude-code/h1/-proj-a/s1.md"
eq "session digest written" yes "$([ -f "$S1" ] && echo yes || echo no)"
eq "the fake key is masked everywhere" 0 "$(grep -rc 'sk-ant-' "$D" | awk -F: '{s+=$2} END {print s+0}')"
eq "the mask marker is there" 1 "$(grep -c '\[REDACTED\]' "$S1" | awk '{print ($1>0)}')"
eq "token=value masked" 0 "$(grep -c 'abcd1234efgh5678' "$S1")"
eq "owner text kept" 1 "$(grep -c '^Owner: OWNERPHRASE' "$S1")"
eq "assistant text kept" 1 "$(grep -c '^Claude: CLAUDEPHRASE' "$S1")"
eq "tool results skipped" 0 "$(grep -c 'TOOLRESULTMARK\|BLOBMARK' "$S1")"
eq "tool inputs skipped" 0 "$(grep -c 'TOOLINPUTMARK' "$S1")"
eq "thinking, reminders, meta and notifications skipped" 0 "$(grep -c 'THINKMARK\|REMINDERMARK\|METAMARK\|TASKMARK' "$S1")"
eq "one tools line for the merged assistant turn" "[tools: Bash x1, Edit x1]" "$(grep '^\[tools:' "$S1")"
eq "one Claude paragraph per owner message" 1 "$(grep -c '^Claude:' "$S1")"
eq "header: project, branch, title, cwd intact" 4 "$(grep -cE '^- (project folder: -proj-a|git branch: main|title: Fixture session|cwd: /home/o/src/github.com/example/project-alpha)$' "$S1")"
eq "header: first and last timestamps" 2 "$(grep -cE '^- (first: 2026-10-01T10:00:00Z|last: 2026-10-01T10:03:00Z)$' "$S1")"
eq "subagent with a parent session skipped" no "$([ -e "$D/claude-code/h1/-proj-a/s1-agent-a1.md" ] && echo yes || echo no)"
eq "orphan subagent digested" yes "$([ -f "$D/claude-code/h1/-proj-a/s9-agent-b2.md" ] && echo yes || echo no)"
eq "claude.ai conversation digested" 1 "$(grep -c '^- title: AI chat title$' "$D/claude-ai/acct1/c-1.md")"
eq "claude.ai: both senders" 2 "$(grep -cE '^(Owner: AIOWNER|Claude: AICLAUDE)' "$D/claude-ai/acct1/c-1.md")"
eq "huge session capped" 1 "$(grep -c 'characters omitted' "$D/claude-code/h1/-proj-c/huge.md")"
eq "cap holds" 1 "$(wc -c < "$D/claude-code/h1/-proj-c/huge.md" | awk '{print ($1 <= 60100)}')"
eq "digests are private" 600 "$(stat -f %Lp "$S1" 2>/dev/null || stat -c %a "$S1")"
eq "the summary prints counts only" 0 "$(printf '%s\n' "$out" | grep -c 'OWNERPHRASE\|sk-')"
out="$(python3 "$DIG" digest "$BR")"
eq "second pass: nothing rewritten" 0 "$(printf '%s\n' "$out" | grep -c 'written_')"
eq "masking keeps paths and folder names" "-Users-o-src-github-com-example-x /a/b/c/AcmeCo42/d/e/f/g" "$(printf '%s' '-Users-o-src-github-com-example-x /a/b/c/AcmeCo42/d/e/f/g' | python3 "$DIG" mask)"
eq "masking: provider keys" "[REDACTED] [REDACTED] [REDACTED] [REDACTED]" "$(printf '%s' 'AKIAABCDEFGHIJKLMNOP ghp_abcdefghijklmnopqrstuvwxyz0123 xoxb-1234-5678-abcdefgh AIzaSyA1234567890abcdefghijklmnopqrstu' | python3 "$DIG" mask)"
eq "masking: card-like numbers, not dates" "[REDACTED] 2026-10-23" "$(printf '%s' '4111 1111 1111 1111 2026-10-23' | python3 "$DIG" mask)"

# --- the queue ----------------------------------------------------------------------------------
eq "queue: oldest first, within the budget" "raw/digests/claude-code/h1/-proj-c/huge.md" "$(python3 "$DIG" queue "$BR" 70000)"
eq "queue: the capped 60k one and one 30k one fit 95k" 2 "$(python3 "$DIG" queue "$BR" 95000 | grep -c .)"
eq "queue: a budget smaller than the first digest still takes one" 1 "$(python3 "$DIG" queue "$BR" 10 | grep -c .)"

# --- the job ------------------------------------------------------------------------------------
SW="$HOME/.local/state/swarm/t"; mkdir -p "$SW"
printf 'SWARM_PROFILE=light\nSWARM_MACHINE=m1\nSWARM_BRAIN_DIR=%s\nBRAIN_INGEST_CHARS=70000\n' "$BR" > "$SW/.env"
printf 'role=primary\nepoch=1\n' > "$SW/.role"
HELD="$SW/backups/alerts-held.log"
job() { : > "$CLOG.calls"; bash "$TMP/scripts/brain-ingest.sh" --swarm t "$@" > "$TMP/out" 2>&1; echo $?; }
calls() { cat "$CLOG.calls" 2>/dev/null | wc -l | tr -d ' '; }
ingested() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$BR/raw/.state/ingested.json" 2>/dev/null || echo 0; }
head0="$(g rev-parse HEAD)"

# a standby never ingests
printf 'role=standby\nepoch=1\n' > "$SW/.role"
eq "standby: exit 0" 0 "$(job run)"; eq "standby: no claude" 0 "$(calls)"
printf 'role=primary\nepoch=1\n' > "$SW/.role"

# the cap: $9.5 spent, one run up to $2, cap $10: skipped, alerted once a month
python3 "$DIG" cost "$BR" add 9.5 ingest 0
eq "cap: exit 0" 0 "$(job run)"; eq "cap: no claude" 0 "$(calls)"
eq "cap: one alert held" 1 "$(grep -c 'brain: ingest paused, monthly cap reached' "$HELD")"
eq "cap: says so" 1 "$(grep -c 'ingest paused' "$TMP/out")"
job run >/dev/null
eq "cap: still one alert after a second run" 1 "$(grep -c 'brain: ingest paused' "$HELD")"
python3 - "$BR" <<'PY'
import json, sys, os
p = os.path.join(sys.argv[1], "raw/.state/costs.json"); d = json.load(open(p))
for m in d.values(): m["usd"] = 0.0; m["runs"] = []
json.dump(d, open(p, "w"))
PY

# failure: nothing marked, spend recorded, alert with the class, non-zero exit
rc="$(CLAUDE_MODE=fail job run)"
eq "failure: non-zero exit" 1 "$([ "$rc" != 0 ] && echo 1 || echo 0)"
eq "failure: nothing marked" 0 "$(ingested)"
eq "failure: alert names the class" 1 "$(grep -c 'brain: ingest failed on m1 (claude-error_max_turns-exit1)' "$HELD")"
eq "failure: the spend still counts" "0.10" "$(python3 "$DIG" cost "$BR" month)"
eq "failure: no commit" "$head0" "$(g rev-parse HEAD)"
eq "failure: partial writes undone" "" "$(g status --porcelain)"

# a write outside the wiki: refused, nothing marked
rc="$(CLAUDE_MODE=stray job run)"
eq "stray write: non-zero exit" 1 "$([ "$rc" != 0 ] && echo 1 || echo 0)"
eq "stray write: alert" 1 "$(grep -c '(stray-writes)' "$HELD")"
eq "stray write: nothing marked" 0 "$(ingested)"
eq "stray write: no commit" "$head0" "$(g rev-parse HEAD)"
eq "stray write: undone" "" "$(g status --porcelain)"

# a hand edit in progress: the run waits, touching nothing
echo "hand edit" >> "$BR/index.md"; echo note > "$BR/raw/notes/n1.md"
rc="$(job run)"
eq "dirty tree: refused" 1 "$([ "$rc" != 0 ] && echo 1 || echo 0)"
eq "dirty tree: no claude" 0 "$(calls)"
eq "dirty tree: the edit kept" 1 "$(grep -c '^hand edit$' "$BR/index.md")"
g checkout -q -- index.md

# success
eq "success: exit 0" 0 "$(job run)"
eq "success: claude called once" 1 "$(calls)"
eq "success: commit message" "ingest: $(date +%F) 1 sessions" "$(g log -1 --format=%s)"
eq "success: only the wiki, index and log committed" "index.md log.md wiki/topics/fixture.md" "$(g show --name-only --format= HEAD | sort | tr '\n' ' ' | sed 's/ $//')"
eq "success: the dropped note is not committed and is kept" yes "$([ -f "$BR/raw/notes/n1.md" ] && [ -z "$(g ls-files raw/notes/n1.md)" ] && echo yes || echo no)"
eq "success: raw never tracked" "raw/notes/.gitkeep" "$(g ls-files raw)"
eq "success: pushed" "$(g rev-parse HEAD)" "$(git -C "$OR" rev-parse main)"
eq "success: the queue marked" 1 "$(ingested)"
eq "success: spend added (failed runs count too)" "0.72" "$(python3 "$DIG" cost "$BR" month)"
eq "success: the log has no digest text" 0 "$(grep -c 'OWNERPHRASE\|CLAUDEPHRASE\|sk-ant\|lorem' "$TMP/out")"
eq "the prompt names digests by path, without their text" 0 "$(grep -c 'OWNERPHRASE\|lorem\|sk-ant' "$CLOG.prompt")"
eq "the prompt lists the queued digest" 1 "$(grep -c '^- raw/digests/claude-code/h1/-proj-c/huge.md$' "$CLOG.prompt")"
eq "the prompt keeps work out" 1 "$(grep -c 'skipped: work' "$CLOG.prompt" | awk '{print ($1 > 0)}')"

# the claude argv: file tools only, writes confined, no shell
argv="$(tr '\n' ' ' < "$CLOG")"
eq "argv: no Bash anywhere" 0 "$(grep -c 'Bash' "$CLOG")"
eq "argv: tools are the file tools" "Read,Write,Edit,Glob,Grep" "$(grep -A1 -x -- '--tools' "$CLOG" | tail -1)"
eq "argv: allowed writes only under wiki/, index.md, log.md" \
  "Read,Glob,Grep,Edit(wiki/**),Write(wiki/**),Edit(index.md),Write(index.md),Edit(log.md),Write(log.md)" "$(grep -A1 -x -- '--allowedTools' "$CLOG" | tail -1)"
eq "argv: headless, json, sonnet, dontAsk, no persistence" 5 "$(printf '%s\n' "$argv" | grep -o -- '-p \|--output-format json\|--model sonnet\|--permission-mode dontAsk\|--no-session-persistence' | wc -l | tr -d ' ')"
eq "argv: a run ceiling" 1 "$(grep -c -x -- '--max-budget-usd' "$CLOG")"
eq "argv: no user settings or MCP servers" 2 "$(grep -cx -- '--setting-sources\|--strict-mcp-config' "$CLOG")"

# the next run takes the next digests; status reports
job run >/dev/null
eq "next run: more marked" 1 "$(ingested | awk '{print ($1 > 1)}')"
eq "status: exit 0" 0 "$(job status)"
eq "status: spend against the cap" 1 "$(grep -c 'this month: \$1.14 of \$10' "$TMP/out")"
eq "status: last run and queue" 2 "$(grep -cE '^(last run: .* ok |queue: [0-9]+ digests)' "$TMP/out")"

# no brain configured
grep -v '^SWARM_BRAIN_DIR=' "$SW/.env" > "$SW/.env.new" && mv "$SW/.env.new" "$SW/.env"
eq "no SWARM_BRAIN_DIR: refused" 1 "$(job run)"
eq "... saying so" 1 "$(grep -c 'SWARM_BRAIN_DIR is not set' "$TMP/out")"

fails="$(nfails)"; [ "$fails" = 0 ] && echo "all ok" || { echo "$fails failed"; exit 1; }
