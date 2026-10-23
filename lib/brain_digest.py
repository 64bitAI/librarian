#!/usr/bin/env python3
"""The brain's digests, ingest queue and spend record (stdlib only; called by brain-ingest.sh).

  brain_digest.py digest BRAIN            raw chats -> raw/digests/ (masked, capped); prints counts
  brain_digest.py queue  BRAIN CHARS      digests not yet ingested, oldest first, within CHARS; one path per line
  brain_digest.py mark   BRAIN < paths    record those digests as ingested (their current content hash)
  brain_digest.py pending BRAIN           count and characters of digests not yet ingested
  brain_digest.py cost   BRAIN add USD KIND N   append one run's spend to this month
  brain_digest.py cost   BRAIN month      this month's spend in USD
  brain_digest.py cost   BRAIN alerted    exit 0 if this month's cap alert was already sent
  brain_digest.py cost   BRAIN set-alerted
  brain_digest.py mask   < text           mask secrets on stdin (for tests)
  brain_digest.py scan   < text           exit 1 (printing a count only) if masking would change any line

Digests are derived and gitignored: raw/digests/claude-code/<host>/<project>/<session>.md and
raw/digests/claude-ai/<account>/<conversation>.md. State lives in raw/.state/ (digested.json,
digests.json, ingested.json, costs.json). Nothing here prints digest contents.
"""
import datetime
import hashlib
import json
import os
import re
import sys
from collections import Counter

CAP = 60000
HEAD = 40000
TAIL = 15000
R = "[REDACTED]"

# --- masking --------------------------------------------------------------------------------------
_PEM = re.compile(r"-----BEGIN [A-Z0-9 ]*-----.*?(?:-----END [A-Z0-9 ]*-----|\Z)", re.S)
_SPECIFIC = [
    re.compile(r"(?<![A-Za-z0-9])sk-ant-[A-Za-z0-9_\-]{8,}"),
    re.compile(r"(?<![A-Za-z0-9])sk-(?:proj-|svcacct-|live_|test_)?[A-Za-z0-9_\-]{16,}"),
    re.compile(r"(?<![A-Za-z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![0-9A-Z])"),
    re.compile(r"(?<![A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"(?<![A-Za-z0-9])github_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"(?<![A-Za-z0-9])xox[bpas]-[A-Za-z0-9\-]{8,}"),
    re.compile(r"(?<![A-Za-z0-9])AIza[0-9A-Za-z_\-]{30,}"),
    re.compile(r"(?<![A-Za-z0-9])eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"),
    re.compile(r"(?i)(?<=bearer )[A-Za-z0-9._~+/\-]{16,}=*"),
]
# NAME=value / "name": "value" for credential-like names; the name is kept, the value masked.
_KV = re.compile(
    r"""(?ix)
    (?P<k>["']?[A-Za-z0-9_\-]*(?:password|passwd|passphrase|secret|token|api[_\-]?key|apikey|access[_\-]?key|private[_\-]?key|client[_\-]?secret|auth[_\-]?key|credentials?)["']?)
    (?P<sep>\s*(?:=|:)\s*)
    (?P<q>["']?)
    (?P<v>[^\s"'&,;<>)\]}]+)
    """
)
_HEX = re.compile(r"(?<![A-Za-z0-9])[0-9a-fA-F]{32,}(?![A-Za-z0-9])")
_B64 = re.compile(r"(?<![A-Za-z0-9+/_\-])[A-Za-z0-9+/_]{32,}={0,2}(?![A-Za-z0-9+/_\-])")
_CARD = re.compile(r"(?<![\d\-])(?:\d{13,19}|\d{4}(?:[ \-]\d{4}){2,3}(?:[ \-]\d{1,3})?)(?![\d\-])")


def _kv(m):
    v = m.group("v")
    if v == R or v.startswith("[REDACTED"):
        return m.group(0)
    sep = m.group("sep")
    # "Token: the next step" is prose; a colon form needs a value that looks like one.
    if ":" in sep and not (len(v) >= 8 and re.search(r"\d", v) and not re.fullmatch(r"[a-z]+", v)):
        return m.group(0)
    if "=" in sep and len(v) < 4:
        return m.group(0)
    # Placeholders and references, not values.
    if v.startswith(("$", "{{", "<", "%", "process.env", "os.environ", "env.")) or v.lower() in (
        "none", "null", "true", "false", "redacted", "xxx", "xxxx", "changeme", "example", "...",
    ):
        return m.group(0)
    return m.group("k") + sep + m.group("q") + R


def _b64(m):
    s = m.group(0)
    core = s.rstrip("=")
    if not (re.search(r"\d", core) and re.search(r"[a-z]", core) and re.search(r"[A-Z]", core)):
        return s
    # Paths have short segments; a key is one long run.
    if max(len(p) for p in core.split("/")) < 24:
        return s
    return R


def mask(text):
    text = _PEM.sub(R, text)
    for rx in _SPECIFIC:
        text = rx.sub(R, text)
    text = _KV.sub(_kv, text)
    text = _HEX.sub(R, text)
    text = _B64.sub(_b64, text)
    text = _CARD.sub(R, text)
    return text


def strict(text):
    """The high-confidence patterns only, for scanning wiki pages: no generic hex or base64 runs
    (a 40-character commit hash in a page is not a secret)."""
    text = _PEM.sub(R, text)
    for rx in _SPECIFIC:
        text = rx.sub(R, text)
    text = _KV.sub(_kv, text)
    return _CARD.sub(R, text)


def cap(text):
    if len(text) <= CAP:
        return text
    omitted = len(text) - HEAD - TAIL
    return text[:HEAD] + "\n\n[... %d characters omitted ...]\n\n" % omitted + text[-TAIL:]


# --- Claude Code sessions -------------------------------------------------------------------------
_NOISE_START = (
    "<task-notification>", "<bash-input>", "<bash-stdout>", "<bash-stderr>", "<local-command-",
    "<command-name>", "<command-message>", "<command-args>", "<user-prompt-submit-hook>",
    "[Request interrupted", "Caveat: The messages below", "This session is being continued",
)
_STRIP = re.compile(
    r"<(system-reminder|local-command-[a-z]+|command-[a-z]+|bash-[a-z]+|task-notification|user-prompt-submit-hook)\b[^>]*>.*?</\1>",
    re.S,
)
_CHANNEL = re.compile(r"<channel\b[^>]*>(.*?)</channel>", re.S)


def owner_text(rec):
    if rec.get("isMeta") or rec.get("isCompactSummary") or rec.get("toolUseResult") is not None:
        return ""
    m = rec.get("message") or {}
    c = m.get("content")
    if isinstance(c, str):
        parts = [c]
    elif isinstance(c, list):
        parts = [b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text"]
    else:
        parts = []
    out = []
    for t in parts:
        t = t.strip()
        if not t or t.startswith(_NOISE_START):
            continue
        t = _STRIP.sub("", t)
        t = _CHANNEL.sub(lambda mm: mm.group(1), t).strip()
        if t:
            out.append(t)
    return "\n\n".join(out)


def claude_parts(rec):
    m = rec.get("message") or {}
    c = m.get("content")
    texts, tools = [], Counter()
    if isinstance(c, str):
        texts.append(c)
    elif isinstance(c, list):
        for b in c:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "text" and b.get("text", "").strip():
                texts.append(b["text"].strip())
            elif b.get("type") == "tool_use":
                tools[b.get("name") or "tool"] += 1
    return texts, tools


def digest_session(path, project, sidechain_ok):
    first = last = cwd = branch = title = sid = None
    turns = []  # [role, [texts], Counter]
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if not isinstance(rec, dict):
                continue
            t = rec.get("type")
            if t == "ai-title" and rec.get("aiTitle"):
                title = rec["aiTitle"]
                continue
            if t not in ("user", "assistant"):
                continue
            if rec.get("isSidechain") and not sidechain_ok:
                continue
            ts = rec.get("timestamp")
            if ts:
                first = first or ts
                last = ts
            cwd = rec.get("cwd") or cwd
            branch = rec.get("gitBranch") or branch
            sid = rec.get("sessionId") or sid
            if t == "user":
                txt = owner_text(rec)
                if txt:
                    turns.append(["Owner", [txt], Counter()])
            else:
                texts, tools = claude_parts(rec)
                if not texts and not tools:
                    continue
                if turns and turns[-1][0] == "Claude":
                    turns[-1][1].extend(texts)
                    turns[-1][2].update(tools)
                else:
                    turns.append(["Claude", texts, tools])
    n_owner = sum(1 for x in turns if x[0] == "Owner")
    n_claude = sum(1 for x in turns if x[0] == "Claude")
    head = ["# Session %s" % (sid or os.path.basename(path)[:-6])]
    if title:
        head.append("- title: %s" % title)
    head += [
        "- project folder: %s" % project,
        "- first: %s" % (first or "unknown"),
        "- last: %s" % (last or "unknown"),
        "- cwd: %s" % (cwd or "unknown"),
    ]
    if branch:
        head.append("- git branch: %s" % branch)
    head.append("- messages: %d owner, %d Claude" % (n_owner, n_claude))
    body = []
    for role, texts, tools in turns:
        para = "\n\n".join(texts).strip()
        if role == "Claude" and tools:
            summary = "[tools: %s]" % ", ".join("%s x%d" % (k, v) for k, v in tools.most_common())
            para = (para + "\n" + summary) if para else summary
        if para:
            body.append("%s: %s" % (role, para))
    return "\n".join(head) + "\n\n" + "\n\n".join(body) + "\n", first or "", last or "", n_owner + n_claude


# --- claude.ai exports ----------------------------------------------------------------------------
def ai_message_text(msg):
    c = msg.get("content")
    if isinstance(c, list):
        parts = [b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text" and b.get("text")]
        if parts:
            return "\n\n".join(p.strip() for p in parts).strip()
    return (msg.get("text") or "").strip()


def digest_ai_conversation(conv, account):
    msgs = conv.get("chat_messages") or []
    head = [
        "# Conversation %s" % (conv.get("uuid") or "?"),
        "- title: %s" % (conv.get("name") or "(untitled)"),
        "- account: %s" % account,
        "- created: %s" % (conv.get("created_at") or "unknown"),
        "- updated: %s" % (conv.get("updated_at") or "unknown"),
        "- messages: %d" % len(msgs),
    ]
    body = []
    for m in msgs:
        who = "Owner" if m.get("sender") == "human" else "Claude"
        t = ai_message_text(m)
        if t:
            body.append("%s: %s" % (who, t))
    return "\n".join(head) + "\n\n" + "\n\n".join(body) + "\n", conv.get("created_at") or "", conv.get("updated_at") or "", len(msgs)


# --- state ----------------------------------------------------------------------------------------
def load(p, default):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save(p, obj):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=1, sort_keys=True)
    os.chmod(tmp, 0o600)
    os.replace(tmp, p)


def write_digest(brain, rel, text):
    p = os.path.join(brain, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, p)


def sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def cmd_digest(brain):
    sd = os.path.join(brain, "raw", ".state")
    done = load(os.path.join(sd, "digested.json"), {})
    index = load(os.path.join(sd, "digests.json"), {})
    stats = Counter()
    largest = 0
    cc = os.path.join(brain, "raw", "chats", "claude-code")
    for root, dirs, files in os.walk(cc):
        dirs.sort()
        for fn in sorted(files):
            if not fn.endswith(".jsonl"):
                continue
            p = os.path.join(root, fn)
            parts = os.path.relpath(p, cc).split(os.sep)
            if len(parts) < 3:
                continue
            host, project = parts[0], parts[1]
            if len(parts) == 3:
                kind, out = "session", "%s/%s/%s.md" % (host, project, fn[:-6])
            elif len(parts) == 5 and parts[3] == "subagents":
                # A subagent's sidechain: only when its parent session is not here.
                if os.path.exists(os.path.join(cc, host, project, parts[2] + ".jsonl")):
                    stats["subagent_skipped"] += 1
                    continue
                kind, out = "subagent", "%s/%s/%s-%s.md" % (host, project, parts[2], fn[:-6])
            else:
                continue
            st = os.stat(p)
            key = os.path.relpath(p, brain)
            sig = {"size": st.st_size, "mtime": int(st.st_mtime)}
            if done.get(key) == sig:
                stats["unchanged"] += 1
                continue
            text, first, last, n = digest_session(p, project, kind == "subagent")
            rel = os.path.join("raw", "digests", "claude-code", out)
            if n == 0:
                stats["empty"] += 1
                done[key] = sig
                continue
            text = cap(mask(text))
            write_digest(brain, rel, text)
            index[rel] = {"first": first, "last": last, "chars": len(text), "sha": sha(text), "source": key}
            done[key] = sig
            stats["written_" + kind] += 1
            stats["chars"] += len(text)
            largest = max(largest, len(text))
    ai = os.path.join(brain, "raw", "chats", "claude-ai")
    exports = []
    for root, dirs, files in os.walk(ai):
        if "conversations.json" in files:
            exports.append(os.path.join(root, "conversations.json"))
    for p in sorted(exports):  # date folders sort oldest first, so a later export wins
        account = os.path.relpath(p, ai).split(os.sep)[0]
        st = os.stat(p)
        key = os.path.relpath(p, brain)
        sig = {"size": st.st_size, "mtime": int(st.st_mtime)}
        if done.get(key) == sig:
            stats["unchanged"] += 1
            continue
        convs = load(p, [])
        if not isinstance(convs, list):
            stats["bad_export"] += 1
            continue
        for conv in convs:
            if not isinstance(conv, dict) or not conv.get("uuid"):
                continue
            text, first, last, n = digest_ai_conversation(conv, account)
            if n == 0:
                stats["empty"] += 1
                continue
            text = cap(mask(text))
            rel = os.path.join("raw", "digests", "claude-ai", account, re.sub(r"[^A-Za-z0-9_\-]", "_", conv["uuid"]) + ".md")
            old = index.get(rel)
            if old and old.get("sha") == sha(text):
                continue
            write_digest(brain, rel, text)
            index[rel] = {"first": first, "last": last, "chars": len(text), "sha": sha(text), "source": key}
            stats["written_conversation"] += 1
            stats["chars"] += len(text)
            largest = max(largest, len(text))
        done[key] = sig
    save(os.path.join(sd, "digested.json"), done)
    save(os.path.join(sd, "digests.json"), index)
    stats["largest"] = largest
    stats["total_digests"] = len(index)
    print(" ".join("%s=%d" % (k, v) for k, v in sorted(stats.items())))


def pending(brain):
    sd = os.path.join(brain, "raw", ".state")
    index = load(os.path.join(sd, "digests.json"), {})
    ing = load(os.path.join(sd, "ingested.json"), {})
    rows = [(v.get("first") or "", rel, v) for rel, v in index.items() if ing.get(rel) != v.get("sha")
            and os.path.exists(os.path.join(brain, rel))]
    rows.sort()
    return rows


def cmd_queue(brain, budget):
    total = 0
    for _, rel, v in pending(brain):
        c = v.get("chars", 0)
        if total and total + c > budget:
            break
        total += c
        print(rel)
        if total >= budget:
            break


def cmd_pending(brain):
    rows = pending(brain)
    print("%d %d" % (len(rows), sum(v.get("chars", 0) for _, _, v in rows)))


def cmd_mark(brain):
    sd = os.path.join(brain, "raw", ".state")
    index = load(os.path.join(sd, "digests.json"), {})
    ing = load(os.path.join(sd, "ingested.json"), {})
    n = 0
    for line in sys.stdin:
        rel = line.strip()
        if rel in index:
            ing[rel] = index[rel]["sha"]
            n += 1
    save(os.path.join(sd, "ingested.json"), ing)
    print(n)


def month():
    return os.environ.get("BRAIN_MONTH") or datetime.date.today().strftime("%Y-%m")


def cmd_cost(brain, args):
    p = os.path.join(brain, "raw", ".state", "costs.json")
    costs = load(p, {})
    m = costs.setdefault(month(), {"usd": 0.0, "runs": [], "alerted": False})
    op = args[0] if args else "month"
    if op == "add":
        usd = float(args[1])
        m["usd"] = round(m["usd"] + usd, 6)
        m["runs"].append({"at": datetime.datetime.now().isoformat(timespec="seconds"), "usd": usd,
                          "kind": args[2] if len(args) > 2 else "ingest", "items": int(args[3]) if len(args) > 3 else 0})
        save(p, costs)
    elif op == "month":
        print("%.2f" % m["usd"])
    elif op == "alerted":
        sys.exit(0 if m.get("alerted") else 1)
    elif op == "set-alerted":
        m["alerted"] = True
        save(p, costs)
    else:
        sys.exit("unknown cost op")


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    op = argv[1]
    if op == "mask":
        sys.stdout.write(cap(mask(sys.stdin.read())))
        return
    if op == "scan":
        n = sum(1 for line in sys.stdin.read().splitlines() if strict(line) != line)
        if n:
            print("%d line(s) look like secrets" % n)
            sys.exit(1)
        return
    if len(argv) < 3:
        sys.exit(__doc__)
    brain = os.path.abspath(argv[2])
    if op == "digest":
        cmd_digest(brain)
    elif op == "queue":
        cmd_queue(brain, int(argv[3]) if len(argv) > 3 else 250000)
    elif op == "pending":
        cmd_pending(brain)
    elif op == "mark":
        cmd_mark(brain)
    elif op == "cost":
        cmd_cost(brain, argv[3:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
