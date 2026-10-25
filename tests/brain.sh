#!/usr/bin/env bash
# brain_digest.py, brain_condense.py, brain_merge.py and brain-ingest.sh against a throwaway brain
# with a bare origin. Ollama is a stub HTTP server on localhost that records each request and answers
# with a fixed note; claude is a stub that records its argv, prompt, cwd and environment and, for a
# stage B merge, writes into its cwd; for a stage A condense call (--max-turns 1, no --allowedTools)
# it answers with a fixed note and a cost (CONDENSE_MODE, CONDENSE_COST). No network beyond localhost, no real model, no real claude. Secrets are synthetic.
set -u
SRC="$(cd "$(dirname "$0")/../.." && pwd)"; TMP="$(mktemp -d)"
OPID=""; trap '[ -z "$OPID" ] || kill "$OPID" 2>/dev/null; rm -rf "$TMP"' EXIT
. "$(dirname "$0")/.hermetic"
cp -R "$SRC/scripts" "$SRC/infra" "$SRC/gates" "$TMP/"; mkdir -p "$TMP/bin"
# common.sh puts the real tools first on PATH: the copy under test keeps the stubs in front, so the real
# claude can never run from here.
sed -i.bak "s|^export PATH=\"/opt/homebrew/bin|export PATH=\"$TMP/bin:/opt/homebrew/bin|" "$TMP/scripts/common.sh"
grep -q "^export PATH=\"$TMP/bin:" "$TMP/scripts/common.sh" || { echo "FAIL could not pin the stub PATH"; exit 1; }

# --- the claude stub ----------------------------------------------------------------------------------
cat > "$TMP/bin/claude" <<'SH'
#!/bin/bash
# NO_CLAUDE: a gated run must never get here, in either stage
[ -z "${NO_CLAUDE:-}" ] || { echo called >> "$CLOG.forbidden"; exit 97; }
case " $* " in *" --allowedTools "*) ;; *)
  # stage A: one condense call. Its own record files, so stage B's checks see only the merge.
  : > "$CLOG.c"; for a in "$@"; do printf '%s\n' "$a" >> "$CLOG.c"; done
  head -c 12 > "$CLOG.c.stdin"; cat > /dev/null
  echo call >> "$CLOG.ccalls"
  pwd -P > "$CLOG.c.cwd"; ls -A > "$CLOG.c.ls"
  echo "key=${ANTHROPIC_API_KEY:-unset}" > "$CLOG.c.env"
  note='## Summary\nFixture session condensed by the stub.\n## People\n- Pat: fixture person\n## Projects\n- project-alpha: a change\n## Decisions\n- none\n## Facts\n- 2026-10-01: secret was sk-ant-api03-EEEEEEEEEEEEEEEEEEEEEEEEEE\n## Open items\n- none'
  case "${CONDENSE_MODE:-ok}" in
    ok) printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":%s,"result":"%s"}\n' "${CONDENSE_COST:-0.01}" "$note" ;;
    fail) echo '{"type":"result","subtype":"error_during_execution","is_error":true,"total_cost_usd":0.02}'; exit 1 ;;
    unparsed) echo 'not json' ;;
  esac
  exit 0 ;;
esac
: > "$CLOG"; for a in "$@"; do printf '%s\n' "$a" >> "$CLOG"; done
cat > "$CLOG.prompt"
echo call >> "$CLOG.calls"
pwd -P > "$CLOG.cwd"; ls -A > "$CLOG.ls"
find notes -type f | LC_ALL=C sort > "$CLOG.notes"; find notes -type f -exec cat {} + > "$CLOG.notetext"
echo "key=${ANTHROPIC_API_KEY:-unset}" > "$CLOG.env"
d="$(date +%F)"
entry() { printf '\n## [%s] ingest | n notes\n%s\n' "$d" "${1:-fixture}" >> log.md; }
ok() { echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"total_cost_usd\":${1:-0.42},\"result\":\"1 page\"}"; }
case "${CLAUDE_MODE:-ok}" in
  ok)
    mkdir -p wiki/topics; echo "# Topic (raw/digests/x.md)" > "wiki/topics/fixture page é.md"
    echo "- [Topic](wiki/topics/fixture page é.md): fixture" >> index.md; entry; ok ;;
  fail)
    mkdir -p wiki/topics; echo partial > wiki/topics/partial.md; entry
    echo '{"type":"result","subtype":"error_max_turns","is_error":true,"total_cost_usd":0.1}'; exit 1 ;;
  nocost) entry; echo '{"type":"result","subtype":"success","is_error":false}' ;;
  unparsed) echo 'not json at all' ;;
  secret)
    mkdir -p wiki/topics; printf 'key %s\n' "sk-ant-api03-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" > wiki/topics/leak.md
    entry; ok 0.0 ;;
  secret2) mkdir -p wiki/topics; printf 'ODOO_KEY=%s\n' "Zz9fakefake1" > wiki/topics/leak2.md; entry; ok 0.0 ;;
  stray) echo "changed" >> CLAUDE.md; entry; ok 0.2 ;;
  straynote) echo "changed" >> "$(find notes -type f | head -1)"; entry; ok 0.2 ;;
  strayfile) echo x > sources.md; entry; ok 0.2 ;;
  nolog) mkdir -p wiki/topics; echo x > wiki/topics/x.md; ok 0.1 ;;
  rewrite) sed -i.bak '1s/.*/# Log rewritten/' log.md; rm -f log.md.bak; entry; ok 0.1 ;;
  hand) sed -i.bak 's/^owner line$/changed by claude/' wiki/topics/hand.md; rm -f wiki/topics/hand.md.bak; entry "hand: wiki/topics/hand.md"; ok 0.1 ;;
  handquiet) echo "added line" >> wiki/topics/hand.md; entry; ok 0.1 ;;
  handok) echo "added line" >> wiki/topics/hand.md; entry "added to wiki/topics/hand.md"; ok 0.1 ;;
  strayown) echo "changed" >> "$(find notes/_raw-notes -type f | head -1)"; entry; ok 0.2 ;;
  strayownnew) echo x > notes/_raw-notes/extra.md; entry; ok 0.2 ;;
  noteedit) printf 'edited during the run\n' >> "$BR/raw/notes/sub/later.md"
    git -C "$BR" -c user.email=t@t -c user.name=t commit -qm "note: edit" -- raw/notes/sub/later.md; entry; ok 0.1 ;;
  term) kill -TERM "$(cat "$BR/raw/.state/ingest.lock/pid")"; entry; ok 0.05 ;;
esac
SH
for c in docker tailscale; do printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/$c"; done
chmod +x "$TMP/bin/"*
export CLOG="$TMP/clog"
export ANTHROPIC_API_KEY="sk-ant-fake-parent-key-not-real"   # must never reach claude
unset OPENAI_API_KEY BRAIN_INGEST_CHARS BRAIN_COST_CAP_USD BRAIN_RUN_MAX_USD BRAIN_MONTH BRAIN_EXCLUDE \
  BRAIN_LOCAL_URL BRAIN_LOCAL_MODEL BRAIN_LOCAL_CHUNK_TOKENS BRAIN_LOCAL_MAX_SECONDS BRAIN_CONDENSE \
  BRAIN_CONDENSE_MODEL BRAIN_CONDENSE_MIN_USD BRAIN_CONDENSE_RUN_USD BRAIN_CLAUDE_CHUNK_CHARS BRAIN_CONDENSE_CALL_MAX_USD

# --- the Ollama stub ----------------------------------------------------------------------------------
OLOG="$TMP/ollama.log"; : > "$OLOG"; echo ok > "$TMP/ollama.mode"
cat > "$TMP/ollama.py" <<'PY'
import json, sys, http.server
log, mode = sys.argv[1], sys.argv[2]
NOTE = """## Summary
Fixture session about project alpha.
Work went well.
Something was decided.
## People
- Pat: fixture person
## Projects
- project-alpha: a change
## Decisions
- 2026-10-01: use the fixture, because tests
## Facts
- 2026-10-01: a fact
- 2026-10-01: secret was sk-ant-api03-DDDDDDDDDDDDDDDDDDDDDDDDDD
## Open items
- none
"""
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        user = body["messages"][-1]["content"]
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "model": body["model"], "num_ctx": body["options"]["num_ctx"],
                                "temperature": body["options"]["temperature"], "user_chars": len(user),
                                "fenced": user.startswith("<transcript>"), "system": len(body["messages"][0]["content"])}) + "\n")
        m = open(mode).read().strip()
        text = ("Sure! Here is the note.\n" + NOTE) if m == "chatty" else NOTE
        out = json.dumps({"message": {"role": "assistant", "content": text}, "prompt_eval_count": 100}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(out))); self.end_headers()
        self.wfile.write(out)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
python3 "$TMP/ollama.py" "$OLOG" "$TMP/ollama.mode" > "$TMP/ollama.port" 2>/dev/null &
OPID=$!
for _ in $(seq 50); do [ -s "$TMP/ollama.port" ] && break; sleep 0.1; done
OURL="http://127.0.0.1:$(cat "$TMP/ollama.port")"
DEAD="http://127.0.0.1:9"   # discard port: nothing listens

# --- a brain with a bare origin -----------------------------------------------------------------------
BR="$TMP/brain"; OR="$TMP/origin.git"; export BR
git init -q --bare "$OR"; git init -q "$BR"
g() { git -C "$BR" -c user.email=t@t -c user.name=t "$@"; }
mkdir -p "$BR/wiki/topics" "$BR/raw/notes"
printf '# schema\n' > "$BR/CLAUDE.md"; printf '# Index\n' > "$BR/index.md"; printf '# Log\n\n## [2026-01-01] seed\n' > "$BR/log.md"; printf '# Sources\n' > "$BR/sources.md"
touch "$BR/wiki/topics/.gitkeep" "$BR/raw/notes/.gitkeep"
printf 'raw/chats/**\n!raw/chats/**/\nraw/digests/**\nraw/.state/**\nraw/notes-condensed/**\n' > "$BR/.gitignore"
g add -A; g commit -qm init; g branch -M main; g remote add origin "$OR"; g push -q -u origin main
git config --global user.email t@t; git config --global user.name t   # the hermetic HOME's identity for the job's commits

# --- fixtures: synthetic sessions ---------------------------------------------------------------------
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
# work: excluded by folder, by cwd, and a claude.ai conversation by title
w(os.path.join(cc, "-Users-o-src-gitea-employerco-voice/w1.jsonl"), [base("user", "2026-10-02T09:00:00Z", message={"role": "user", "content": "WORKMARK one"})])
w(os.path.join(cc, "-proj-d/w2.jsonl"), [base("user", "2026-10-02T09:00:00Z", cwd="/home/o/src/wrk/thing", message={"role": "user", "content": "WORKMARK two"})])
ai = os.path.join(brain, "raw/chats/claude-ai/acct1/2026-10-05")
os.makedirs(ai, exist_ok=True)
json.dump([{"uuid": "c-1", "name": "AI chat title", "created_at": "2026-10-20T00:00:00Z", "updated_at": "2026-10-21T00:00:00Z",
            "chat_messages": [{"sender": "human", "text": "AIOWNER " + secret}, {"sender": "assistant", "content": [{"type": "text", "text": "AICLAUDE"}]}]},
           {"uuid": "c-2", "name": "employerco pitch", "created_at": "2026-10-20T00:00:00Z", "updated_at": "2026-10-21T00:00:00Z",
            "chat_messages": [{"sender": "human", "text": "WORKMARK three"}]}],
          open(os.path.join(ai, "conversations.json"), "w"))
PY
D="$BR/raw/digests"; DIG="$TMP/scripts/brain_digest.py"; CON="$TMP/scripts/brain_condense.py"; MRG="$TMP/scripts/brain_merge.py"

# --- digests ------------------------------------------------------------------------------------------
# A first pass with nothing excluded (as an older version would have made), then the default: the
# work digests already in the index must go.
BRAIN_EXCLUDE='^nomatch$' python3 "$DIG" digest "$BR" >/dev/null
eq "exclusion off: work digests made" 3 "$(grep -rl 'WORKMARK' "$D" | wc -l | tr -d ' ')"
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
eq "digests are private" 600 "$(stat -c %a "$S1" 2>/dev/null || stat -f %Lp "$S1")"
eq "the summary prints counts only" 0 "$(printf '%s\n' "$out" | grep -c 'OWNERPHRASE\|sk-')"
eq "work excluded: by folder, by cwd, by conversation title" 3 "$(printf '%s\n' "$out" | sed -n 's/.*excluded=\([0-9]*\).*/\1/p')"
eq "work excluded: no digest anywhere" 0 "$(grep -rl 'WORKMARK' "$D" | wc -l | tr -d ' ')"
eq "work excluded: not in the index" 0 "$(grep -c 'w1.md\|w2.md\|c-2.md' "$BR/raw/.state/digests.json")"
eq "work excluded: never queued" 0 "$(python3 "$DIG" queue "$BR" 99999999 | grep -c 'w1.md\|w2.md\|c-2.md')"
out="$(python3 "$DIG" digest "$BR")"
eq "second pass: nothing rewritten" 0 "$(printf '%s\n' "$out" | grep -c 'written_')"
eq "BRAIN_EXCLUDE replaces the default" 1 "$(printf '# S\n- project folder: -x-gitea-y\n\nOwner: hi\n' > "$TMP/x.md"; BRAIN_EXCLUDE='nomatch' python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import brain_digest as b; print(0 if b.excluded(b.excluder(), open(sys.argv[2]).read()) else 1)' "$TMP/scripts" "$TMP/x.md")"

m() { printf '%s' "$1" | python3 "$DIG" mask; }
eq "masking keeps paths and folder names" "-Users-o-src-github-com-example-x /a/b/c/AcmeCo42/d/e/f/g" "$(m '-Users-o-src-github-com-example-x /a/b/c/AcmeCo42/d/e/f/g')"
eq "masking: provider keys" "[REDACTED] [REDACTED] [REDACTED] [REDACTED]" "$(m 'AKIAABCDEFGHIJKLMNOP ghp_abcdefghijklmnopqrstuvwxyz0123 xoxb-1234-5678-abcdefgh AIzaSyA1234567890abcdefghijklmnopqrstu')"
eq "masking: card-like numbers, not dates" "[REDACTED] 2026-10-23" "$(m '4111 1111 1111 1111 2026-10-23')"
eq "masking: Amex 4-6-5 layout" "card [REDACTED] and [REDACTED]" "$(m 'card 3700 000000 00002 and 3700-000000-00002')"
eq "masking: NAME_KEY=value" "ODOO_KEY=[REDACTED]" "$(m 'ODOO_KEY=Zz9fakefake1')"
eq "masking: export NAME_KEY=\"value\"" 'export SVC_API_KEY="[REDACTED]"' "$(m 'export SVC_API_KEY="fakeValue123"')"
eq "masking: DB_PASS=value (letters only)" "DB_PASS=[REDACTED]" "$(m 'DB_PASS=hunterfake')"
eq "masking: X_PWD=value" "X_PWD=[REDACTED]" "$(m 'X_PWD=fake9pwd')"
eq "masking: password: letters only, 8+" "password: [REDACTED]" "$(m 'password: Sunflowerfake')"
eq "masking: password: letters and a digit" "password: [REDACTED]" "$(m 'password: Letters8+')"
eq "masking: prose after password: kept" "password: required" "$(m 'password: required')"
eq "masking: prose after Token: kept" "Token: the next step" "$(m 'Token: the next step')"
eq "masking: identifiers named *_key kept" "sort_key=name cache_key=user.id primary_key: id" "$(m 'sort_key=name cache_key=user.id primary_key: id')"
eq "masking: monkey= and bypass= are not key names" "monkey=abc123456 bypass=abc123456" "$(m 'monkey=abc123456 bypass=abc123456')"
eq "masking: a key path is not a key" "ssh_key=~/.ssh/id_ed25519" "$(m 'ssh_key=~/.ssh/id_ed25519')"
eq "scan: a commit hash in a page is not a secret" 0 "$(printf 'commit 0123456789abcdef0123456789abcdef01234567\n' | python3 "$DIG" scan >/dev/null; echo $?)"
eq "scan: a key is" 1 "$(printf 'x sk-ant-api03-CCCCCCCCCCCCCCCCCCCCCCCC\n' | python3 "$DIG" scan >/dev/null; echo $?)"
eq "scan: NAME_KEY=value is (shared pattern)" 1 "$(printf 'ODOO_KEY=Zz9fakefake1\n' | python3 "$DIG" scan >/dev/null; echo $?)"
eq "scan: sort_key=name is not" 0 "$(printf 'sort_key=name\n' | python3 "$DIG" scan >/dev/null; echo $?)"

# --- stage A: condensed notes ---------------------------------------------------------------------------
export BRAIN_LOCAL_URL="$OURL"
eq "condense: one call per digest under the chunk limit" 1 "$(: > "$OLOG"; python3 "$CON" one "$S1" > "$TMP/n1.md" 2>/dev/null; grep -c . "$OLOG")"
eq "condense: six sections in order" "Summary,People,Projects,Decisions,Facts,Open items" "$(sed -n 's/^## //p' "$TMP/n1.md" | paste -sd, -)"
eq "condense: the header names the source" 1 "$(grep -c "^- source: $S1\$" "$TMP/n1.md")"
eq "condense: an empty section says none" 1 "$(sed -n '/^## Open items/,$p' "$TMP/n1.md" | grep -c '^- none$')"
eq "condense: the note is masked" 0 "$(grep -c 'sk-ant' "$TMP/n1.md")"
eq "condense: default model, temperature 0, fenced transcript" '"qwen2.5:14b-instruct" 0 true' "$(python3 -c 'import json,sys; d=json.loads(open(sys.argv[1]).readline()); print(json.dumps(d["model"]), d["temperature"], str(d["fenced"]).lower())' "$OLOG")"
HUGE="$D/claude-code/h1/-proj-c/huge.md"
: > "$OLOG"; BRAIN_LOCAL_CHUNK_TOKENS=4000 python3 "$CON" one "$HUGE" > "$TMP/n2.md" 2> "$TMP/n2.err"
eq "chunking: a 60k digest at 4000 tokens is several chunks" 1 "$(awk 'END {print (NR >= 4)}' "$OLOG")"
eq "chunking: each request within the chunk (plus header and instructions)" 0 "$(python3 -c 'import json,sys; print(sum(1 for l in open(sys.argv[1]) if json.loads(l)["user_chars"] > 4000*3.2 + 600))' "$OLOG")"
eq "chunking: num_ctx covers chunk, prompt and output" 6560 "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["num_ctx"])' "$OLOG")"
eq "chunking: merged notes keep each line once" 1 "$(grep -c '^- Pat: fixture person$' "$TMP/n2.md")"
eq "chunking: the summary stays at most 5 lines" 1 "$(sed -n '/^## Summary/,/^## People/p' "$TMP/n2.md" | grep -c '^- ' | awk '{print ($1 <= 5)}')"
eq "chunking: the note says how many chunks" 1 "$(grep -c '^- chunks: [0-9]*$' "$TMP/n2.md")"
eq "condense: a local note says which model wrote it" 1 "$(grep -c '^- condensed-by: qwen2.5:14b-instruct$' "$TMP/n2.md")"
echo chatty > "$TMP/ollama.mode"
eq "format: text outside the sections is a format failure" false "$(python3 "$CON" one "$S1" 2>&1 >/dev/null | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["format_ok"]).lower())')"
echo ok > "$TMP/ollama.mode"
eq "note path: claude-code drops the source kind" "raw/notes-condensed/h1/-proj-a/s1.md" "$(python3 "$CON" note raw/digests/claude-code/h1/-proj-a/s1.md)"
eq "condense unreachable: exit 3, nothing written" 3 "$(BRAIN_CONDENSE=local BRAIN_LOCAL_URL="$DEAD" python3 "$CON" condense "$BR" >/dev/null; echo $?)"
eq "condense unreachable: no notes" no "$([ -d "$BR/raw/notes-condensed" ] && echo yes || echo no)"

# --- the job --------------------------------------------------------------------------------------------
unset BRAIN_LOCAL_URL
SW="$HOME/.local/state/swarm/t"; mkdir -p "$SW"
printf 'SWARM_PROFILE=light\nSWARM_MACHINE=m1\nSWARM_BRAIN_DIR=%s\nBRAIN_LOCAL_URL=%s\nBRAIN_INGEST_CHARS=70000\nBRAIN_CONDENSE=local\n' "$BR" "$OURL" > "$SW/.env"
printf 'role=primary\nepoch=1\n' > "$SW/.role"
HELD="$SW/backups/alerts-held.log"
job() { : > "$CLOG.calls"; bash "$TMP/scripts/brain-ingest.sh" --swarm t "$@" > "$TMP/out" 2>&1; echo $?; }
calls() { cat "$CLOG.calls" 2>/dev/null | wc -l | tr -d ' '; }
ingested() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$BR/raw/.state/ingested.json" 2>/dev/null || echo 0; }
spent() { python3 "$DIG" cost "$BR" month; }
zero_costs() { python3 - "$BR" <<'PY'
import json, sys, os
p = os.path.join(sys.argv[1], "state/costs.json"); d = json.load(open(p))
for m in d.values(): m["usd"] = 0.0; m["runs"] = []; m["alerted"] = False
json.dump(d, open(p, "w"))
PY
g commit -qm "ingest: cost reset (test)" -- state/costs.json >/dev/null || true; g push -q; }
clean() { eq "$1: tree clean, nothing staged" "" "$(g -c core.quotePath=false status --porcelain | grep -v ' raw/' || true)"; }
head0="$(g rev-parse HEAD)"

# a standby never ingests
printf 'role=standby\nepoch=1\n' > "$SW/.role"
eq "standby: exit 0" 0 "$(job run)"; eq "standby: no claude" 0 "$(calls)"
printf 'role=primary\nepoch=1\n' > "$SW/.role"

# the local model is down: no claude, nothing spent, alert
sed -i.bak "s|^BRAIN_LOCAL_URL=.*|BRAIN_LOCAL_URL=$DEAD|" "$SW/.env"
eq "local model down: non-zero exit" 1 "$(job run)"
eq "local model down: no claude" 0 "$(calls)"
eq "local model down: alert names the class" 1 "$(grep -c '(local-model)' "$HELD")"
sed -i.bak "s|^BRAIN_LOCAL_URL=.*|BRAIN_LOCAL_URL=$OURL|" "$SW/.env"

# I7: a live lock stops a second run; a stale one is taken over
mkdir -p "$BR/raw/.state/ingest.lock"; sleep 300 & LIVE=$!; echo "$LIVE" > "$BR/raw/.state/ingest.lock/pid"
eq "lock held: exit 0" 0 "$(job run)"; eq "lock held: no claude" 0 "$(calls)"
eq "lock held: says so" 1 "$(grep -c 'another ingest' "$TMP/out")"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
echo 999999 > "$BR/raw/.state/ingest.lock/pid"

# the cap: $9.6 spent, cap $10, under $0.5 usable: skipped, alerted once a month; the record is committed
python3 "$DIG" cost "$BR" add 9.6 ingest 0
eq "cap: exit 0" 0 "$(job run)"; eq "cap: no claude" 0 "$(calls)"
eq "stale lock taken over" 1 "$(grep -c 'stale lock' "$TMP/out")"
eq "lock released after the run" no "$([ -d "$BR/raw/.state/ingest.lock" ] && echo yes || echo no)"
eq "cap: one alert held" 1 "$(grep -c 'brain: ingest paused, monthly cap reached' "$HELD")"
eq "cap: says so" 1 "$(grep -c 'ingest paused' "$TMP/out")"
eq "I6: the spend is tracked in the brain" "state/costs.json" "$(g ls-files state)"
eq "I6: and pushed" "$(g rev-parse HEAD)" "$(git -C "$OR" rev-parse main)"
job run >/dev/null
eq "cap: still one alert after a second run" 1 "$(grep -c 'brain: ingest paused' "$HELD")"
# I6: another machine's clone of the brain sees the same month
git clone -q -b main "$OR" "$TMP/brain2"
eq "I6: a failover host sees the month's spend" "9.60" "$(python3 "$DIG" cost "$TMP/brain2" month)"
zero_costs

# stage A ran during those runs: notes exist, private, gitignored
NOTE1="$BR/raw/notes-condensed/h1/-proj-a/s1.md"
eq "stage A: notes written" yes "$([ -f "$NOTE1" ] && echo yes || echo no)"
eq "stage A: notes are private" 600 "$(stat -c %a "$NOTE1" 2>/dev/null || stat -f %Lp "$NOTE1")"
eq "stage A: per-note timing recorded" 1 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(int(all("seconds" in v for v in d.values()) and len(d) > 0))' "$BR/raw/.state/condensed.json")"
eq "stage A: notes never tracked" "" "$(g ls-files raw/notes-condensed)"

# I3: failure at the turn limit: nothing marked, spend recorded and committed, the queue halves
echo 70000 > "$BR/raw/.state/queue-chars"
rc="$(CLAUDE_MODE=fail job run)"
eq "failure: non-zero exit" 1 "$([ "$rc" != 0 ] && echo 1 || echo 0)"
eq "failure: nothing marked" 0 "$(ingested)"
eq "failure: alert names the class" 1 "$(grep -c 'brain: ingest failed on m1 (claude-error_max_turns-exit1)' "$HELD")"
eq "failure: the spend still counts" "0.10" "$(spent)"
eq "failure: the spend is committed" "ingest: cost $(date +%F) (\$0.1," "$(g log -1 --format=%s | cut -d' ' -f1-4)"
eq "failure: no wiki commit" "" "$(g log --format=%s "$head0"..HEAD | grep -v '^ingest: cost' || true)"
clean "failure"
taken="$(sed -n 's/.*ingest: [0-9]* notes, \([0-9]*\) characters.*/\1/p' "$TMP/out")"
eq "I3: the queue limit halves to half of what was taken" "$(( taken / 2 ))" "$(cat "$BR/raw/.state/queue-chars")"

# I2: a result without a cost, or that cannot be read, counts the whole run budget
rm -f "$BR/raw/.state/queue-chars"
CLAUDE_MODE=nocost job run >/dev/null
eq "I2: no total_cost_usd -> the budget (\$2) is recorded" "2.10" "$(spent)"
CLAUDE_MODE=unparsed job run >/dev/null
eq "I2: unparsed result -> the budget is recorded" "4.10" "$(spent)"
eq "I2: unparsed is a failure class" 1 "$(grep -c '(claude-unparsed-exit0)' "$HELD")"
zero_costs

# the per-run budget: the smaller of BRAIN_RUN_MAX_USD and the remainder less the margin
python3 "$DIG" cost "$BR" add 9.0 ingest 0
CLAUDE_MODE=unparsed job run >/dev/null
eq "budget: clamped to remainder minus margin (10 - 9 - 0.25)" "0.75" "$(grep -A1 -x -- '--max-budget-usd' "$CLOG" | tail -1)"
zero_costs

# stray writes in the temp dir: refused, the brain untouched
for mode in stray straynote strayfile; do
  rc="$(CLAUDE_MODE=$mode job run)"
  eq "$mode: refused" 1 "$([ "$rc" != 0 ] && echo 1 || echo 0)"
  eq "$mode: alert" 1 "$(tail -1 "$HELD" | grep -c '(stray-writes)')"
  clean "$mode"
done
eq "stray: the brain's CLAUDE.md never changed" "# schema" "$(cat "$BR/CLAUDE.md")"
rc="$(CLAUDE_MODE=nolog job run)"; eq "no log entry: refused" 1 "$(tail -1 "$HELD" | grep -c '(no-log-entry)')"
rc="$(CLAUDE_MODE=rewrite job run)"; eq "log rewritten: refused" 1 "$(tail -1 "$HELD" | grep -c '(log-rewritten)')"
clean "log checks"

# a secret written into the wiki: refused, nothing copied back, nothing marked
for mode in secret secret2; do
  rc="$(CLAUDE_MODE=$mode job run)"
  eq "$mode in wiki: refused" 1 "$(tail -1 "$HELD" | grep -c '(secret-in-wiki)')"
  eq "$mode in wiki: nothing marked" 0 "$(ingested)"
  clean "$mode in wiki"
  eq "$mode in wiki: the value is not in the job's output" 0 "$(grep -c 'sk-ant\|Zz9fake' "$TMP/out")"
done

# I1: an uncommitted hand edit stops the run, whatever its name; untracked raw/ notes do not count
echo "hand edit" >> "$BR/index.md"
eq "dirty tracked: refused" 1 "$(job run)"; eq "dirty tracked: no claude" 0 "$(calls)"
eq "dirty tracked: the edit kept" 1 "$(grep -c '^hand edit$' "$BR/index.md")"
g checkout -q -- index.md
printf 'draft\n' > "$BR/wiki/topics/ünïcode draft page.md"
eq "I1: an untracked wiki page with a space and non-ASCII name is dirty" 1 "$(job run)"
eq "I1: ... no claude" 0 "$(calls)"
rm -f "$BR/wiki/topics/ünïcode draft page.md"
echo note > "$BR/raw/notes/n1.md"

# I5: pages last committed by hand are append-only and must be named in the log entry
printf '# Hand\nowner line\n' > "$BR/wiki/topics/hand.md"; g add wiki/topics/hand.md; g commit -qm "owner: hand page"; g push -q
eq "I5: hand pages listed" "wiki/topics/hand.md" "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import brain_merge as m; print(" ".join(m.hand_pages(sys.argv[2])))' "$TMP/scripts" "$BR")"
eq "baseline: a page last committed by the bootstrap (brain:) is the job's" "wiki/topics/hand.md" "$(printf '# Seed\n' > "$BR/wiki/topics/seed.md"; g add wiki/topics/seed.md; g commit -qm "brain: seed page"; g push -q; python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import brain_merge as m; print(" ".join(m.hand_pages(sys.argv[2])))' "$TMP/scripts" "$BR")"
nskip() { python3 -c 'import json,sys; print(sum(1 for v in json.load(open(sys.argv[1])).values() if v["why"] == "hand-edit"))' "$BR/raw/.state/skipped.json" 2>/dev/null || echo 0; }
nalert() { grep -c 'skipped a note that would change a hand-edited page (hand-edit' "$HELD" || true; }
# several notes: refused, no alert, the next run takes one note
echo 999999 > "$BR/raw/.state/queue-chars"
rc="$(CLAUDE_MODE=hand job run)"
eq "I5: changing a hand line (several notes): refused" 1 "$rc"
eq "I5: ... the queue shrinks to one note" 1 "$(cat "$BR/raw/.state/queue-chars")"
eq "I5: ... nothing skipped, no alert" "0 0" "$(nskip) $(nalert)"
eq "I5: ... nothing marked" 0 "$(ingested)"
# one note: skipped (it leaves the queue), one alert
rc="$(CLAUDE_MODE=hand job run)"
eq "I5: changing a hand line (one note): skipped" "1 1 1" "$(nskip) $(nalert) $(ingested)"
eq "I5: ... recorded" 1 "$(grep -c 'skipped 1 note (hand-edit)' "$BR/raw/.state/last-run")"
rc="$(CLAUDE_MODE=handquiet job run)"; eq "I5: adding without naming it: that note skipped too" "2 2" "$(nskip) $(nalert)"
eq "I5: the prompt lists the hand page" 1 "$(grep -c '^- wiki/topics/hand.md$' "$CLOG.prompt")"
clean "I5"
eq "I5: adding and naming it: accepted" 0 "$(CLAUDE_MODE=handok job run)"
eq "I5: the owner's line kept, the addition in" "owner line|added line" "$(sed -n '2,3p' "$BR/wiki/topics/hand.md" | paste -sd'|' -)"
rm -f "$BR/raw/.state/ingested.json" "$BR/raw/.state/queue-chars" "$BR/raw/.state/skipped.json"
head1="$(g rev-parse HEAD)"

# I1/minor: a failed commit leaves nothing staged and removes the pages it created
printf '#!/bin/sh\ngrep -q "notes$" "$1" && exit 1\nexit 0\n' > "$BR/.git/hooks/commit-msg"; chmod +x "$BR/.git/hooks/commit-msg"
rc="$(job run)"
eq "commit fails: refused" 1 "$(tail -1 "$HELD" | grep -c '(git-commit)')"
clean "commit fails"
eq "commit fails: the created page removed" no "$([ -f "$BR/wiki/topics/fixture page é.md" ] && echo yes || echo no)"
eq "commit fails: nothing marked" 0 "$(ingested)"
rm -f "$BR/.git/hooks/commit-msg"

# INT/TERM: the run stops, the lock goes, nothing copied back
rc="$(CLAUDE_MODE=term job run)"
eq "TERM: exit 130" 130 "$rc"
eq "TERM: lock released" no "$([ -d "$BR/raw/.state/ingest.lock" ] && echo yes || echo no)"
eq "TERM: recorded" 1 "$(grep -c 'failed interrupted' "$BR/raw/.state/last-run")"
clean "TERM"
zero_costs
head1="$(g rev-parse HEAD)"

# success; I3: the first run (no queue size yet) takes one note
eq "success: exit 0" 0 "$(job run)"
eq "success: claude called once" 1 "$(calls)"
eq "I3: first run takes one note" "1 notes" "$(grep -o '^## \[[0-9-]*\] ingest | [0-9]* notes' "$CLOG.prompt" | sed 's/.*| //')"
eq "success: commit message" "ingest: $(date +%F) 1 notes" "$(g log -1 --format=%s)"
eq "success: only the wiki, index and log in the commit" "index.md|log.md|wiki/topics/fixture page é.md" "$(g -c core.quotePath=false show --name-only --format= HEAD | sort | paste -sd'|' -)"
eq "success: the spend in its own commit" 1 "$(g log --format=%s "$head1"..HEAD | grep -c '^ingest: cost ')"
eq "success: the dropped note is not committed and is kept" yes "$([ -f "$BR/raw/notes/n1.md" ] && [ -z "$(g ls-files raw/notes/n1.md)" ] && echo yes || echo no)"
eq "success: raw never tracked" "raw/notes/.gitkeep" "$(g ls-files raw)"
eq "success: pushed" "$(g rev-parse HEAD)" "$(git -C "$OR" rev-parse main)"
eq "success: the queue marked" 1 "$(ingested)"
eq "I3: the queue limit grows after a success" 1 "$(awk '{print ($1 > 1)}' "$BR/raw/.state/queue-chars")"
eq "success: the log has no digest or note text" 0 "$(grep -c 'OWNERPHRASE\|CLAUDEPHRASE\|sk-ant\|lorem\|Pat: fixture' "$TMP/out")"
eq "the prompt names notes by path, without their text" 0 "$(grep -c 'OWNERPHRASE\|lorem\|sk-ant\|Pat: fixture' "$CLOG.prompt")"
eq "the prompt lists the queued note" 1 "$(grep -c '^- notes/h1/-proj-c/huge.md$' "$CLOG.prompt")"
eq "the prompt keeps work out" 1 "$(grep -c 'skipped: work' "$CLOG.prompt" | awk '{print ($1 > 0)}')"

# C1: claude ran in a temp dir with only what it needs; no raw/, not inside the brain; no API key
eq "C1: cwd holds only CLAUDE.md, index.md, log.md, notes, wiki" "CLAUDE.md index.md log.md notes wiki" "$(sort "$CLOG.ls" | paste -sd' ' -)"
eq "C1: cwd is not inside the brain" 1 "$(case "$(cat "$CLOG.cwd")" in "$(cd "$BR" && pwd -P)"*) echo 0 ;; *) echo 1 ;; esac)"
eq "C1: the temp dir is gone after the run" no "$([ -e "$(cat "$CLOG.cwd")" ] && echo yes || echo no)"
eq "claude gets no ANTHROPIC_API_KEY" "key=unset" "$(cat "$CLOG.env")"

# the claude argv: file tools only, writes confined, no shell
argv="$(tr '\n' ' ' < "$CLOG")"
eq "argv: no Bash anywhere" 0 "$(grep -c 'Bash' "$CLOG")"
eq "argv: tools are the file tools" "Read,Write,Edit,Glob,Grep" "$(grep -A1 -x -- '--tools' "$CLOG" | tail -1)"
eq "argv: allowed writes only under wiki/, index.md, log.md" \
  "Read,Glob,Grep,Edit(wiki/**),Write(wiki/**),Edit(index.md),Write(index.md),Edit(log.md),Write(log.md)" "$(grep -A1 -x -- '--allowedTools' "$CLOG" | tail -1)"
eq "argv: headless, json, sonnet, dontAsk, no persistence" 5 "$(printf '%s\n' "$argv" | grep -o -- '-p \|--output-format json\|--model sonnet\|--permission-mode dontAsk\|--no-session-persistence' | wc -l | tr -d ' ')"
eq "argv: restricted, no MCP servers" 2 "$(grep -cx -- '--restricted\|--strict-mcp-config' "$CLOG")"

# the next run takes more; status reports
job run >/dev/null
eq "next run: more marked" 1 "$(ingested | awk '{print ($1 > 1)}')"
eq "status: exit 0" 0 "$(job status)"
eq "status: spend against the cap" 1 "$(grep -c 'this month ([0-9-]*): \$0.84 of \$10' "$TMP/out")"
eq "status: last run and queues" 2 "$(grep -cE '^(last run: .* ok |queue: [0-9]+ digests .* next note by local)' "$TMP/out")"

# --- stage A through Claude ------------------------------------------------------------------------------
# Direct calls of the condenser: the stub claude first on PATH, the real one never reachable.
CPATH="$TMP/bin:/usr/bin:/bin"; CST="$BR/raw/.state/condensed.json"
reset_notes() { rm -rf "$BR/raw/notes-condensed" "$CST"; : > "$CLOG.ccalls"; }
ccalls() { cat "$CLOG.ccalls" 2>/dev/null | grep -c . || true; }
npend() { python3 "$DIG" pending "$BR" | cut -d' ' -f1; }
models() { python3 -c 'import json,sys; print(" ".join(sorted(set(v["model"] for v in json.load(open(sys.argv[1])).values()))))' "$CST"; }
zero_costs; reset_notes
NP="$(npend)"
out="$(PATH="$CPATH" BRAIN_CONDENSE=claude BRAIN_LOCAL_URL="$DEAD" python3 "$CON" condense "$BR")"; rc=$?
eq "claude condense: works with the local model down" 0 "$rc"
eq "claude condense: one call per pending digest" "$NP" "$(ccalls)"
eq "claude condense: the counts line" 1 "$(printf '%s\n' "$out" | grep -c "^condensed=$NP claude=$NP local=0 ")"
eq "claude condense argv: the owner's flags" "-p|--no-session-persistence|--output-format|json|--model|sonnet|--max-turns|1|--tools||--restricted|--setting-sources||--strict-mcp-config" "$(head -14 "$CLOG.c" | paste -sd'|' -)"
eq "claude condense argv: the same system prompt as the local model" 1 "$(grep -cx -- '--system-prompt' "$CLOG.c")"
eq "claude condense argv: a per-call ceiling" "0.50" "$(grep -A1 -x -- '--max-budget-usd' "$CLOG.c" | tail -1)"
eq "claude condense: the transcript is fenced, on stdin" "<transcript>" "$(cat "$CLOG.c.stdin")"
eq "claude condense: an empty cwd" "" "$(cat "$CLOG.c.ls")"
eq "claude condense: cwd outside the brain, removed after" "1 no" "$(case "$(cat "$CLOG.c.cwd")" in "$(cd "$BR" && pwd -P)"*) printf 0 ;; *) printf 1 ;; esac) $([ -e "$(cat "$CLOG.c.cwd")" ] && echo yes || echo no)"
eq "claude condense: no ANTHROPIC_API_KEY" "key=unset" "$(cat "$CLOG.c.env")"
eq "claude condense: notes say claude:sonnet" "claude:sonnet" "$(models)"
eq "claude condense: header line" 1 "$(grep -c '^- condensed-by: claude:sonnet$' "$NOTE1")"
eq "claude condense: the note is masked" 0 "$(grep -rc 'sk-ant' "$BR/raw/notes-condensed" | awk -F: '{s+=$2} END {print s+0}')"
eq "claude condense: every call's cost in the month, kind condense" "$NP $(python3 -c "print('%.2f' % ($NP * 0.01))")" "$(python3 -c 'import json,sys,os; d=json.load(open(os.path.join(sys.argv[1],"state/costs.json"))); r=[x for m in d.values() for x in m["runs"] if x["kind"]=="condense"]; print(len(r))' "$BR") $(spent)"
out="$(PATH="$CPATH" BRAIN_CONDENSE=claude python3 "$CON" condense "$BR")"
eq "claude condense: a second pass calls nothing" 0 "$(ccalls | awk -v n="$NP" '{print $1 - n}')"
eq "claude condense: the queue takes Claude notes" "$NP" "$(BRAIN_CONDENSE=claude python3 "$CON" queue "$BR" 99999999 | grep -c .)"
eq "claude condense: local mode accepts them too" "$NP" "$(BRAIN_CONDENSE=local python3 "$CON" queue "$BR" 99999999 | grep -c .)"
# a failing claude: stop after two failures, exit 4, the spend still counts
zero_costs; reset_notes
eq "claude condense failing: exit 4" 4 "$(PATH="$CPATH" CONDENSE_MODE=fail BRAIN_CONDENSE=claude python3 "$CON" condense "$BR" >/dev/null; echo $?)"
eq "claude condense failing: two calls, both paid" "2 0.04" "$(ccalls) $(spent)"
zero_costs; reset_notes
PATH="$CPATH" CONDENSE_MODE=unparsed BRAIN_CONDENSE=claude python3 "$CON" condense "$BR" >/dev/null
eq "claude condense unparsed: counts the call ceiling" "1.00" "$(spent)"
# the per-run ceiling: no new Claude note after BRAIN_CONDENSE_RUN_USD; the rest wait
zero_costs; reset_notes
out="$(PATH="$CPATH" CONDENSE_COST=0.3 BRAIN_CONDENSE_RUN_USD=0.5 BRAIN_CONDENSE=auto python3 "$CON" condense "$BR")"
eq "run ceiling: two notes, the rest wait" "2 $((NP - 2))" "$(ccalls) $(printf '%s\n' "$out" | sed -n 's/.* waiting=\([0-9]*\).*/\1/p')"

# auto: under BRAIN_CONDENSE_MIN_USD left in the month, the local model, marked; later redone by Claude
zero_costs; reset_notes; python3 "$DIG" cost "$BR" add 9.5 ingest 0
eq "auto, \$0.50 left of \$10: next note by local" local "$(BRAIN_CONDENSE=auto python3 "$CON" backend "$BR")"
out="$(PATH="$CPATH" BRAIN_CONDENSE=auto BRAIN_LOCAL_URL="$OURL" python3 "$CON" condense "$BR")"
eq "auto, low budget: no claude, all local" "0 qwen2.5:14b-instruct" "$(ccalls) $(models)"
eq "auto, low budget: the note says condensed-by the local model" 1 "$(grep -c '^- condensed-by: qwen2.5:14b-instruct$' "$NOTE1")"
eq "auto, low budget: local notes are queued" "$NP" "$(BRAIN_CONDENSE=auto python3 "$CON" queue "$BR" 99999999 | grep -c .)"
eq "auto, a higher cap for the month: claude again" claude "$(BRAIN_COST_CAP_USD=20 BRAIN_CONDENSE=auto python3 "$CON" backend "$BR")"
zero_costs
eq "auto, budget back: local notes are not current" 0 "$(BRAIN_CONDENSE=auto python3 "$CON" queue "$BR" 99999999 | grep -c .)"
out="$(PATH="$CPATH" BRAIN_CONDENSE=auto BRAIN_LOCAL_URL="$DEAD" python3 "$CON" condense "$BR")"
eq "auto, budget back: every local note redone by Claude" "$NP claude:sonnet" "$(ccalls) $(models)"
eq "claude mode, no money: notes wait, nothing local" "wait" "$(python3 "$DIG" cost "$BR" add 9.5 ingest 0; BRAIN_CONDENSE=claude python3 "$CON" backend "$BR")"
zero_costs

# the cap for one month: BRAIN_COST_CAP_<YYYY>_<MM> in .env beats BRAIN_COST_CAP_USD
reset_notes
BRAIN_MONTH=2031-02 python3 "$DIG" cost "$BR" add 9.0 ingest 0
printf 'BRAIN_COST_CAP_2031_02=20\n' >> "$SW/.env"
BRAIN_MONTH=2031-02 CLAUDE_MODE=unparsed job run >/dev/null
eq "month cap: stage B budget from the month's cap (min 2, 20 - 9 - 0.25)" "2.00" "$(grep -A1 -x -- '--max-budget-usd' "$CLOG" | tail -1)"
BRAIN_MONTH=2031-02 job status >/dev/null
eq "month cap: status shows it" 1 "$(grep -c 'this month (2031-02): \$11.00 of \$20' "$TMP/out")"
BRAIN_MONTH=2031-03 job status >/dev/null
eq "month cap: other months keep BRAIN_COST_CAP_USD" 1 "$(grep -c 'this month (2031-03): \$0.00 of \$10 ' "$TMP/out")"
sed -i.bak '/^BRAIN_COST_CAP_2031_02=/d' "$SW/.env"

# the job with Claude condensing, end to end: stage A spend committed, then the merge
sed -i.bak "s|^BRAIN_CONDENSE=.*|BRAIN_CONDENSE=auto|; s|^BRAIN_LOCAL_URL=.*|BRAIN_LOCAL_URL=$DEAD|" "$SW/.env"
reset_notes; rm -f "$BR/raw/.state/ingested.json" "$BR/raw/.state/queue-chars"; head2="$(g rev-parse HEAD)"; NP="$(npend)"
eq "job, claude condense: exit 0 with Ollama down" 0 "$(job run)"
eq "job, claude condense: stage A calls, one merge" "$NP 1" "$(ccalls) $(calls)"
eq "job, claude condense: stage A spend committed on its own" 1 "$(g log --format=%s "$head2"..HEAD | grep -c '^ingest: cost .* (condense)$')"
eq "job, claude condense: the month holds both stages" "$(python3 -c "print('%.2f' % ($NP * 0.01 + 0.42))")" "$(spent)"
eq "job, claude condense: the merged note is Claude's" 1 "$(grep -c '^- condensed-by: claude:sonnet$' "$NOTE1")"
eq "job, claude condense: no digest or note text in the log" 0 "$(grep -c 'OWNERPHRASE\|sk-ant\|Pat: fixture' "$TMP/out")"
clean "job, claude condense"
reset_notes; rm -f "$BR/raw/.state/ingested.json"
eq "job, claude condense failing: refused" 1 "$(CONDENSE_MODE=fail job run)"
eq "job, claude condense failing: no merge, alert names the class" "0 1" "$(calls) $(tail -1 "$HELD" | grep -c '(condense-claude)')"
eq "job, claude condense failing: the spend committed" 1 "$(g log -1 --format=%s | grep -c '^ingest: cost .* (condense)$')"
clean "job, claude condense failing"
sed -i.bak "s|^BRAIN_CONDENSE=.*|BRAIN_CONDENSE=local|; s|^BRAIN_LOCAL_URL=.*|BRAIN_LOCAL_URL=$OURL|" "$SW/.env"
zero_costs

# --- owner notes: raw/notes, committed, never condensed, merged before any chat --------------------------
rm -f "$BR/raw/.state/ingested.json" "$BR/raw/.state/skipped.json" "$BR/raw/.state/queue-chars"
GN="raw/notes/2026-10-20 garden é.md"
mkdir -p "$BR/raw/notes/sub"
printf '# Garden\n- 2026-10-20: planted garlic OWNNOTEMARK\n' > "$BR/$GN"
printf '# Later\n- a second note\n' > "$BR/raw/notes/sub/later.md"
printf '# Keys\n- the key is %s\n' "sk-ant-api03-FFFFFFFFFFFFFFFFFFFFFFFFFFFF" > "$BR/raw/notes/leak.md"
printf '# employerco pitch\n- WORKMARK four\n' > "$BR/raw/notes/pitch.md"
g add -- "$GN" raw/notes/sub/later.md raw/notes/leak.md raw/notes/pitch.md; g commit -qm "note: four notes"; g push -q
printf '# Draft\n' > "$BR/raw/notes/draft.md"   # not committed: it waits (with n1.md from above)
out="$(python3 "$DIG" notes "$BR" check)"
eq "notes check: two queued, a secret and a work note skipped, two uncommitted" "queued=2 skipped_secret=1 skipped_work=1 uncommitted=2" "$(printf '%s\n' "$out" | grep -o 'queued=[0-9]*\|skipped_[a-z]*=[0-9]*\|uncommitted=[0-9]*' | paste -sd' ' -)"
eq "notes check: skips named by path and class" "skipped secret: raw/notes/leak.md|skipped work: raw/notes/pitch.md" "$(printf '%s\n' "$out" | grep -o 'skipped [a-z]*: raw/notes/[a-z]*\.md' | paste -sd'|' -)"
eq "notes check: prints no note text" 0 "$(printf '%s\n' "$out" | grep -c 'sk-ant\|OWNNOTEMARK\|WORKMARK')"
eq "notes check: skipped.json keeps why" "secret work" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["raw/notes/leak.md"]["why"], d["raw/notes/pitch.md"]["why"])' "$BR/raw/.state/skipped.json")"
eq "notes pending: count and uncommitted" "2 2" "$(python3 "$DIG" notes "$BR" pending | awk '{print $1, $3}')"
eq "queue: one character still takes one owner note" "$GN" "$(python3 "$CON" queue "$BR" 1)"
BRAIN_CONDENSE=local BRAIN_LOCAL_URL="$OURL" python3 "$CON" condense "$BR" >/dev/null
BRAIN_CONDENSE=local python3 "$CON" queue "$BR" 99999999 > "$TMP/q"
eq "queue: owner notes first, then the (older) chats" "raw/notes|raw/notes|raw/digests" "$(head -3 "$TMP/q" | cut -d/ -f1-2 | paste -sd'|' -)"
eq "queue: no skipped or uncommitted note" 0 "$(grep -c 'leak\|pitch\|draft\|n1\.md' "$TMP/q")"
eq "notes are never condensed" 0 "$(find "$BR/raw/notes-condensed" -path '*garden*' -o -path '*later*' 2>/dev/null | wc -l | tr -d ' ')"
# a run with the queue at one character: the oldest owner note alone
rc="$(job run)"
eq "owner note run: exit 0" 0 "$rc"
eq "owner note run: the note alone in the work dir" "notes/_raw-notes/2026-10-20 garden é.md" "$(cat "$CLOG.notes")"
eq "owner note run: the prompt cites the raw/notes path and its commit date" 1 "$(grep -cxF -- "- notes/_raw-notes/2026-10-20 garden é.md (owner note: cite $GN, $(g log -1 --format=%cs -- "$GN"))" "$CLOG.prompt")"
eq "owner note run: the prompt says merge owner notes first" 1 "$(grep -c 'Merge them first' "$CLOG.prompt")"
eq "owner note run: marked at its content hash" "$(shasum -a 256 "$BR/$GN" | cut -d' ' -f1)" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$BR/raw/.state/ingested.json" "$GN")"
eq "owner note run: the queue grows by the note's size" "$(( $(python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read()))' "$BR/$GN") * 2 ))" "$(cat "$BR/raw/.state/queue-chars")"
eq "owner note run: the log line" 1 "$(grep -c 'owner notes: .*queued=2 ' "$TMP/out")"
eq "owner notes: no secret or work text reached the merge or the log" 0 "$(cat "$CLOG.prompt" "$CLOG.notetext" "$TMP/out" | grep -c 'sk-ant\|WORKMARK')"
eq "owner notes: the note's text never in the job's log" 0 "$(grep -c 'OWNNOTEMARK' "$TMP/out")"
clean "owner note run"
# a big queue: the next owner note listed first, condensed notes after it
echo 99999999 > "$BR/raw/.state/queue-chars"
rc="$(job run)"
eq "big run: exit 0" 0 "$rc"
eq "big run: the owner note leads the list, chats follow" "notes/_raw-notes/sub/later.md|notes/h1" "$(grep '^- notes/' "$CLOG.prompt" | head -2 | sed 's/^- //; s/ (owner note.*//; s|^\(notes/h1\)/.*|\1|' | paste -sd'|' -)"
eq "unchanged notes are not queued again" "0 2" "$(python3 "$DIG" notes "$BR" pending | awk '{print $1, $3}')"
# an uncommitted edit waits; a committed edit comes back; a fixed secret note comes back
printf 'more\n' >> "$BR/raw/notes/sub/later.md"
eq "an uncommitted edit waits" "0 3" "$(python3 "$DIG" notes "$BR" pending | awk '{print $1, $3}')"
g commit -qm "note: edit" -- raw/notes/sub/later.md
printf '# Keys\n- the key lives in the vault\n' > "$BR/raw/notes/leak.md"; g commit -qm "note: fix" -- raw/notes/leak.md; g push -q
eq "a committed edit and a fixed note are queued again" "2 2" "$(python3 "$DIG" notes "$BR" pending | awk '{print $1, $3}')"
# an edit committed while the merge runs: the copy the merge saw is what gets marked
echo 999999 > "$BR/raw/.state/queue-chars"
rc="$(CLAUDE_MODE=noteedit job run)"
eq "edit during the run: exit 0" 0 "$rc"
eq "edit during the run: that note comes back next time" "1 raw/notes/sub/later.md" "$(python3 "$DIG" notes "$BR" pending | awk '{print $1}') $(python3 "$CON" queue "$BR" 1)"
# stray writes to owner notes in the work dir
for mode in strayown strayownnew; do
  rc="$(CLAUDE_MODE=$mode job run)"
  eq "$mode: refused" 1 "$(tail -1 "$HELD" | grep -c '(stray-writes)')"
  clean "$mode"
done
eq "the owner's notes never changed by a run" "# Garden|- 2026-10-20: planted garlic OWNNOTEMARK" "$(paste -sd'|' - < "$BR/$GN")"
job status >/dev/null
eq "status: the owner notes queue" 1 "$(grep -c '^owner notes (raw/notes): 1 queued, [0-9]* characters, merged before any chat; 2 not committed' "$TMP/out")"
eq "status: the digest queue line unchanged" 1 "$(grep -cE '^queue: [0-9]+ digests ' "$TMP/out")"
# a merge that writes a secret from a single owner note: that note skipped, not a failure every night
echo 1 > "$BR/raw/.state/queue-chars"
rc="$(CLAUDE_MODE=secret job run)"
eq "owner note, secret in the merge: refused" 1 "$rc"
eq "owner note, secret in the merge: skipped with the class" "secret-in-wiki" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["raw/notes/sub/later.md"]["why"])' "$BR/raw/.state/skipped.json")"
eq "owner note, secret in the merge: it leaves the queue" 0 "$(python3 "$DIG" notes "$BR" pending | awk '{print $1}')"
eq "owner note, secret in the merge: one alert" 1 "$(grep -c 'skipped an owner note whose merge would write a secret' "$HELD")"
clean "owner note, secret in the merge"
rm -f "$BR/raw/notes/draft.md"
zero_costs

# the merge helpers directly: rollback removes created files and unstages
W="$TMP/w/brain"; mkdir -p "$W/wiki/topics"; cp "$BR/index.md" "$BR/log.md" "$W/"; cp -R "$BR/wiki/." "$W/wiki/"
echo new > "$W/wiki/topics/new one.md"; echo changed >> "$W/index.md"
python3 "$MRG" apply "$BR" "$W" "$TMP/created" >/dev/null; g add -A wiki index.md
python3 "$MRG" rollback "$BR" "$TMP/created" >/dev/null
clean "rollback helper"

# the unit: a two-hour ceiling
eq "systemd: TimeoutStartSec=2h" 1 "$(grep -c '^TimeoutStartSec=2h$' "$TMP/infra/systemd/swarm-brain-ingest.service.tmpl")"

# --- the gate (gates/brain-ingest.sh): no new chat and no digest due, so Claude never starts ------------
python3 "$DIG" digest "$BR" >/dev/null; python3 "$DIG" queue "$BR" 999999999 | python3 "$DIG" mark "$BR" >/dev/null
eq "fresh: nothing new after a digest pass" 0 "$(python3 "$DIG" fresh "$BR")"
eq "pending: nothing due" "0 0" "$(python3 "$DIG" pending "$BR")"
gated() { : > "$CLOG.forbidden"; : > "$OLOG"; NO_CLAUDE=1 job run; }
eq "gated: exit 0" 0 "$(gated)"
eq "gated: neither claude nor the local model called" "0 0" "$(grep -c . "$CLOG.forbidden") $(grep -c . "$OLOG")"
eq "gated: one log line with the reason" 1 "$(grep -c ' gated: no new chats and no digest to ingest$' "$TMP/out")"
eq "gated: the last run says so" 1 "$(grep -c '^[0-9T:-]* gated: no new chats and no digest to ingest$' "$BR/raw/.state/last-run")"
clean "gated"
NEW="$BR/raw/chats/claude-code/h1/-proj-e/n1.jsonl"; mkdir -p "$(dirname "$NEW")"
printf '%s\n' '{"type":"user","timestamp":"2026-10-03T09:00:00Z","sessionId":"n1","cwd":"/home/o/x","message":{"role":"user","content":"hello"}}' > "$NEW"
eq "fresh: a new chat counts" 1 "$(python3 "$DIG" fresh "$BR")"
eq "gate: a new chat opens it" 0 "$(bash "$TMP/gates/brain-ingest.sh" "$BR" >/dev/null; echo $?)"
printf '%s\n' '{"type":"user","timestamp":"2026-10-03T09:01:00Z","sessionId":"n1","message":{"role":"user","content":"more"}}' >> "$NEW"
python3 "$DIG" digest "$BR" >/dev/null
eq "fresh: none once digested" 0 "$(python3 "$DIG" fresh "$BR")"
eq "gate: a digest due opens it" 0 "$(bash "$TMP/gates/brain-ingest.sh" "$BR" >/dev/null; echo $?)"
# the swarm's own gate beats the repo's
mkdir -p "$SW/gates"; printf 'echo "owner pause"\nexit 10\n' > "$SW/gates/brain-ingest"
eq "swarm gate: exit 0" 0 "$(gated)"
eq "swarm gate: its reason, no claude" "1 0" "$(grep -c '^[0-9T:-]* gated: owner pause$' "$BR/raw/.state/last-run") $(grep -c . "$CLOG.forbidden")"
python3 "$DIG" queue "$BR" 999999999 | python3 "$DIG" mark "$BR" >/dev/null
printf 'exit 0\n' > "$SW/gates/brain-ingest"
eq "swarm gate says run: the job runs" "0 1" "$(gated) $(grep -c ' ok 0 notes$' "$BR/raw/.state/last-run")"
printf 'echo broken >&2\nexit 7\n' > "$SW/gates/brain-ingest"
eq "broken gate: the job runs anyway" "0 1" "$(gated) $(grep -c ' ok 0 notes$' "$BR/raw/.state/last-run")"
eq "broken gate: warned, its stderr in the log" "1 1" "$(grep -c 'gate .*brain-ingest failed (exit 7); running anyway' "$TMP/out") $(grep -cx broken "$TMP/out")"
rm -rf "$SW/gates"
eq "gate: the log has counts only" 0 "$(grep -c 'hello\|more' "$TMP/out")"
# a quiet night with one committed owner note waiting: the gate opens; once it is ingested, gated again
eq "gate: quiet night, no note: gated" 10 "$(bash "$TMP/gates/brain-ingest.sh" "$BR" >/dev/null; echo $?)"
printf '# Quiet\n- a note on a quiet night\n' > "$BR/raw/notes/quiet.md"
eq "gate: an uncommitted note keeps it shut" 10 "$(bash "$TMP/gates/brain-ingest.sh" "$BR" >/dev/null; echo $?)"
g add raw/notes/quiet.md; g commit -qm "note: quiet"; g push -q
eq "gate: a committed note waiting opens it" 0 "$(bash "$TMP/gates/brain-ingest.sh" "$BR" >/dev/null; echo $?)"
echo 1 > "$BR/raw/.state/queue-chars"
eq "gate: the quiet night's run merges the note" "0 1" "$(job run) $(grep -c '^- notes/_raw-notes/quiet.md ' "$CLOG.prompt")"
eq "gate: ingested, it shuts again" 10 "$(bash "$TMP/gates/brain-ingest.sh" "$BR" >/dev/null; echo $?)"

# no brain configured
grep -v '^SWARM_BRAIN_DIR=' "$SW/.env" > "$SW/.env.new" && mv "$SW/.env.new" "$SW/.env"
eq "no SWARM_BRAIN_DIR: refused" 1 "$(job run)"
eq "... saying so" 1 "$(grep -c 'SWARM_BRAIN_DIR is not set' "$TMP/out")"

fails="$(nfails)"; [ "$fails" = 0 ] && echo "all ok" || { echo "$fails failed"; exit 1; }
