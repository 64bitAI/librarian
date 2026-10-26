#!/usr/bin/env python3
"""The brain's digests, ingest queue and spend record (stdlib only; called by brain-ingest.sh).

  brain_digest.py digest BRAIN            raw chats -> raw/digests/ (masked, capped); prints counts
  brain_digest.py queue  BRAIN CHARS      digests not yet ingested, oldest first, within CHARS; one path per line
  brain_digest.py mark   BRAIN [SHAS] < paths  record those digests and owner notes as ingested (their
                                          content hash; an owner note's from SHAS, the JSON prepare
                                          wrote, when it is there)
  brain_digest.py skip   BRAIN WHY [SHAS] < paths  the same, recorded as skipped for WHY (raw/.state/skipped.json)
  brain_digest.py pending BRAIN           count and characters of digests not yet ingested
  brain_digest.py fresh  BRAIN            how many raw chats are new or changed since the last digest pass
  brain_digest.py notes  BRAIN check      owner notes (raw/notes) that fail a check leave the queue as
                                          skipped (secret, work, too-large); prints counts and the
                                          skipped paths with their class
  brain_digest.py notes  BRAIN pending    count and characters of owner notes waiting, and how many
                                          are not committed yet (they wait for a commit)
  brain_digest.py cost   BRAIN add USD KIND N   append one run's spend to this month (state/costs.json, tracked)
  brain_digest.py cost   BRAIN month      this month's spend in USD
  brain_digest.py cost   BRAIN alerted    exit 0 if this month's cap alert was already sent
  brain_digest.py cost   BRAIN set-alerted
  brain_digest.py mask   < text           mask secrets on stdin (for tests)
  brain_digest.py scan   < text           exit 1 (printing a count only) if masking would change any line
  brain_digest.py collect-list HOST STAGE CLAUDE_PROJECTS CODEX_SESSIONS GEMINI_TMP
                                          the chats this host may copy to the brain, one path per line
                                          relative to raw/chats/ (BRAIN_EXCLUDE and temp folders left
                                          out); with STAGE (else ""), each is also linked there

Digests are derived and gitignored: raw/digests/claude-code/<host>/<project>/<session>.md,
raw/digests/claude-ai/<account>/<conversation>.md, raw/digests/codex/<host>/<rollout>.md and
raw/digests/gemini/<host>/<slug>/<session>.md. Owner notes (raw/notes/**/*.md, written by the
owner or an agent and committed) are sources in their own right: never digested or condensed, queued
while committed and unchanged in the work tree, and keyed by content hash in ingested.json like a
digest, so an edited note comes back and an unchanged one does not. State lives in raw/.state/ (digested.json,
digests.json, ingested.json); the month's spend in state/costs.json, which the job commits. Nothing here prints digest contents.
"""
import datetime
import hashlib
import json
import os
import re
import subprocess
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
# NAME=value / "name": "value" for credential-like names; the name is kept, the value masked. Strong
# names (password, token, api_key, ...) anywhere in the name; weak suffixes (_key, _pass, _pwd, _pw)
# only after a _ or - (so monkey= and bypass= are not names), and then only for a value that looks
# like one (below).
_KV = re.compile(
    r"""(?ix)
    (?P<k>["']?(?:
        (?P<strong>[A-Za-z0-9_\-]*(?:password|passwd|passphrase|secret|token|api[_\-]?key|apikey|access[_\-]?key|private[_\-]?key|client[_\-]?secret|auth[_\-]?key|credentials?))
       |(?P<weak>[A-Za-z0-9]+(?:[_\-][A-Za-z0-9]+)*[_\-](?:key|pass|pwd|pw))
    )["']?)
    (?P<sep>\s*(?:=|:)\s*)
    (?P<q>["']?)
    (?P<v>[^\s"'&,;<>)\]}]+)
    """
)
_PASSWORDISH = re.compile(r"(?i)pass(?:word|wd|phrase)?$|pwd$|pw$")
_HEX = re.compile(r"(?<![A-Za-z0-9])[0-9a-fA-F]{32,}(?![A-Za-z0-9])")
_B64 = re.compile(r"(?<![A-Za-z0-9+/_\-])[A-Za-z0-9+/_]{32,}={0,2}(?![A-Za-z0-9+/_\-])")
# Card-like numbers: 13-19 digits in a run, 4-4-4-4 groups, and the Amex (4-6-5) and Diners (4-6-4)
# layouts. Dates (2026-10-23) have too few digits to match.
_CARD = re.compile(r"(?<![\d\-])(?:\d{13,19}|\d{4}(?:[ \-]\d{4}){2,3}(?:[ \-]\d{1,3})?|\d{4}[ \-]\d{6}[ \-]\d{4,5})(?![\d\-])")


def _kv(m):
    v = m.group("v")
    if v == R or v.startswith("[REDACTED"):
        return m.group(0)
    sep = m.group("sep")
    name = (m.group("strong") or m.group("weak") or "").strip("\"'")
    # Placeholders and references, not values.
    if v.startswith(("$", "{{", "<", "%", "process.env", "os.environ", "env.")) or v.lower() in (
        "none", "null", "true", "false", "redacted", "xxx", "xxxx", "changeme", "example", "...",
    ):
        return m.group(0)
    if m.group("weak"):
        # sort_key=name, cache_key=user.id, ssh_key=~/.ssh/id: identifiers and paths, not values.
        # A _key value needs six characters and a digit or an inner capital, and no path separator.
        # A password-like suffix (_pass, _pwd, _pw) takes any four characters.
        if "/" in v or len(v) < 4:
            return m.group(0)
        if not _PASSWORDISH.search(name) and (len(v) < 6 or not (re.search(r"\d", v) or re.search(r".[A-Z]", v))):
            return m.group(0)
    elif ":" in sep:
        # "Token: the next step" is prose; a colon form needs a value that looks like one. For a
        # password-like name eight characters that are not one lowercase word are enough
        # ("password: Sunflowers"); for the other names a digit is needed too.
        if len(v) < 8 or re.fullmatch(r"[a-z]+", v):
            return m.group(0)
        if not _PASSWORDISH.search(name) and not re.search(r"\d", v):
            return m.group(0)
    elif len(v) < 4:
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


# Work material never enters the brain (its CLAUDE.md, Identity): a session whose project folder,
# cwd or title, or a conversation whose account or title, matches BRAIN_EXCLUDE (one regular
# expression, case-insensitive) gets no digest at all. The default names the owner's employer's
# folders and forge; set BRAIN_EXCLUDE in the swarm's .env to replace it.
EXCLUDE_DEFAULT = r"employerco|(?<![a-z0-9])wrk(?![a-z0-9])|gitea"


def excluder():
    rx = os.environ.get("BRAIN_EXCLUDE")
    rx = EXCLUDE_DEFAULT if rx is None or not rx.strip() else rx
    return re.compile(rx, re.I)


def header_fields(text):
    """The header values a digest's exclusion is decided on: title, project folder, cwd, account."""
    out = []
    for line in text.split("\n", 12)[:12]:
        for k in ("- title: ", "- project folder: ", "- cwd: ", "- account: "):
            if line.startswith(k):
                out.append(line[len(k):])
    return out


def excluded(rx, text, *extra):
    return any(rx.search(f) for f in list(extra) + header_fields(text) if f)


def drop_digest(brain, index, rel):
    """A digest that is now excluded goes, file and index entry, so it is never queued."""
    if rel in index:
        del index[rel]
    try:
        os.remove(os.path.join(brain, rel))
    except OSError:
        pass


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


# --- Codex and Gemini sessions --------------------------------------------------------------------
def render(title, fields, turns, assistant):
    """A digest in the Claude Code layout: the same header lines (cwd, project folder, first, last), so
    header_fields, excluded() and cap(mask(...)) treat every source alike."""
    n_owner = sum(1 for x in turns if x[0] == "Owner")
    n_other = len(turns) - n_owner
    head = ["# Session %s" % title] + ["- %s: %s" % (k, v) for k, v in fields if v]
    head.append("- messages: %d owner, %d %s" % (n_owner, n_other, assistant))
    body = []
    for role, texts, tools in turns:
        para = "\n\n".join(texts).strip()
        if role != "Owner" and tools:
            summary = "[tools: %s]" % ", ".join("%s x%d" % (k, v) for k, v in tools.most_common())
            para = (para + "\n" + summary) if para else summary
        if para:
            body.append("%s: %s" % (role, para))
    return "\n".join(head) + "\n\n" + "\n\n".join(body) + "\n", n_owner + n_other


def add_turn(turns, role, text, tools=None):
    """Consecutive assistant records (and their tool calls) make one paragraph, as in claude_parts."""
    if role != "Owner" and turns and turns[-1][0] == role:
        if text:
            turns[-1][1].append(text)
        turns[-1][2].update(tools or {})
    else:
        turns.append([role, [text] if text else [], Counter(tools or {})])


def folder_of(cwd):
    """Claude Code's project folder naming for a cwd (/a/b.c -> -a-b-c), so a work folder name matches
    BRAIN_EXCLUDE the same way in either header line."""
    return re.sub(r"[^A-Za-z0-9]", "-", cwd)


def digest_codex(path):
    """(text, first, last, n, why): a Codex rollout. The owner's words are event_msg user_message only,
    of kind plain or none (a response_item user message, or a user_message of kind user_instructions or
    environment_context, carries the injected environment and AGENTS.md context); the
    assistant's are event_msg agent_message; tools are counted, never their inputs or outputs; the
    session_meta instructions are never read. why is "codex_exec" for our own ask.sh consults and
    "no_cwd" when the rollout names no folder, and the text is then empty."""
    meta = None
    first = last = None
    turns = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if not isinstance(rec, dict) or not isinstance(rec.get("payload"), dict):
                continue
            t, p = rec.get("type"), rec["payload"]
            if t == "session_meta":
                meta = meta or p  # a forked rollout repeats its parent's after its own: the first is this one
                continue
            pt = p.get("type")
            msg = p.get("message").strip() if isinstance(p.get("message"), str) else ""
            if t == "event_msg" and pt in ("user_message", "agent_message"):
                if not msg:
                    continue
                # Older releases sent AGENTS.md and the environment as user_message too, with kind
                # user_instructions or environment_context: only a plain (or unmarked) one is the
                # owner's, and one opening with those tags is injected whatever its kind says.
                if pt == "user_message" and (p.get("kind", "plain") != "plain"
                                             or msg.startswith(("<environment_context", "<user_instructions"))):
                    continue
                role, text, tools = "Owner" if pt == "user_message" else "Codex", msg, None
            elif t == "response_item" and pt in ("function_call", "custom_tool_call"):
                role, text, tools = "Codex", "", {p.get("name") or "tool": 1}
            elif t == "event_msg" and pt == "web_search_end":
                role, text, tools = "Codex", "", {"web_search": 1}
            else:
                continue
            ts = rec.get("timestamp")
            if ts:
                first = first or ts
                last = ts
            add_turn(turns, role, text, tools)
    meta = meta or {}
    if meta.get("originator") == "codex_exec":
        return "", "", "", 0, "codex_exec"
    if not any(x[0] == "Owner" for x in turns):
        return "", "", "", 0, None
    cwd = meta.get("cwd") if isinstance(meta.get("cwd"), str) else ""
    if not cwd:
        return "", "", "", 0, "no_cwd"
    git = meta.get("git") if isinstance(meta.get("git"), dict) else {}
    text, n = render(meta.get("id") or os.path.basename(path)[:-6], [
        ("project folder", folder_of(cwd)), ("first", first or "unknown"), ("last", last or "unknown"),
        ("cwd", cwd), ("git branch", git.get("branch")), ("engine", "codex (%s)" % (meta.get("originator") or "unknown")),
    ], turns, "Codex")
    return text, first or "", last or "", n, None


def gemini_root(path):
    """The folder a Gemini session ran in: .project_root beside the session (the brain's layout), or
    beside its chats/ folder (Gemini's own). None when there is none."""
    d = os.path.dirname(path)
    for c in (d, os.path.dirname(d)) if os.path.basename(d) == "chats" else (d,):
        try:
            with open(os.path.join(c, ".project_root"), encoding="utf-8", errors="replace") as f:
                root = f.read().strip()
        except OSError:
            continue
        return root or None
    return None


def gemini_text(c):
    if isinstance(c, str):
        return c.strip()
    if isinstance(c, list):
        return "\n\n".join(b["text"].strip() for b in c if isinstance(b, dict) and isinstance(b.get("text"), str)
                           and b["text"].strip())
    return ""


def digest_gemini(path, slug):
    """(text, first, last, n, why): a Gemini CLI session. Messages of type user are the owner's and
    gemini the assistant's (string or parts with text); thoughts and tool arguments and results are
    never read, tool calls only counted; the header line, {"$set": ...} updates and info, error and
    warning messages are skipped. With no .project_root the session has no cwd, so it gets no digest
    (why "no_cwd"): a work chat must never dodge BRAIN_EXCLUDE."""
    cwd = gemini_root(path)
    if not cwd:
        return "", "", "", 0, "no_cwd"
    sid = first = last = None
    turns = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if not isinstance(rec, dict):
                continue
            if "sessionId" in rec and "type" not in rec:
                sid = sid or rec.get("sessionId")
                continue
            t = rec.get("type")
            if t not in ("user", "gemini"):
                continue
            text = gemini_text(rec.get("content"))
            tools = Counter()
            if t == "gemini" and isinstance(rec.get("toolCalls"), list):
                for c in rec["toolCalls"]:
                    if isinstance(c, dict):
                        tools[c.get("name") or "tool"] += 1
            if not text and not tools:
                continue
            ts = rec.get("timestamp")
            if ts:
                first = first or ts
                last = ts
            add_turn(turns, "Owner" if t == "user" else "Gemini", text, tools)
    if not any(x[0] == "Owner" for x in turns):
        return "", "", "", 0, None
    text, n = render(sid or os.path.basename(path)[:-6], [
        ("project folder", slug), ("first", first or "unknown"), ("last", last or "unknown"), ("cwd", cwd),
        ("engine", "gemini"),
    ], turns, "Gemini")
    return text, first or "", last or "", n, None


# --- the collector's list (brain-collect.sh) ------------------------------------------------------
# Run on the host that has the chats, before anything is copied: work material (BRAIN_EXCLUDE) and
# chats from temp folders (our own consults and scratch runs) never leave it. A chat is kept only
# when every folder it names passes; the digest pass checks again on the brain's host.
TEMP_ROOTS = ("/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp", "/var/folders", "/private/var/folders")
_SCRATCH = re.compile(r"(?:^|/)claude-\d+(?:/|$)")          # a Claude scratchpad, /private/tmp/claude-<uid>
_SCRATCH_FOLDER = re.compile(r"(?:^|-)claude-\d+(?:-|$)")   # the same in a project folder name
_FIELD = re.compile(rb'"(cwd|aiTitle)"\s*:\s*"((?:[^"\\]|\\.)*)"')


def temp_path(p):
    p = os.path.normpath(p) if p else ""
    return any(p == r or p.startswith(r + "/") for r in TEMP_ROOTS) or bool(_SCRATCH.search(p))


def temp_folder(name):
    """A Claude Code project folder (folder_of(cwd)) under a temp root."""
    return any(name == folder_of(r) or name.startswith(folder_of(r) + "-") for r in TEMP_ROOTS) \
        or bool(_SCRATCH_FOLDER.search(name))


def folder_blocked(rx, cwd):
    return bool(rx.search(cwd) or rx.search(folder_of(cwd)) or temp_path(cwd))


def chat_fields(path):
    """Every cwd and Claude Code title a chat file names (one read, no full parse): (cwds, titles)."""
    cwds, titles = set(), set()
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return None
    for m in _FIELD.finditer(data):
        try:
            v = json.loads(b'"' + m.group(2) + b'"')
        except ValueError:
            v = m.group(2).decode("utf-8", "replace")
        (cwds if m.group(1) == b"cwd" else titles).add(v)
    return cwds, titles


def chat_ok(rx, path):
    f = chat_fields(path)
    if f is None:
        return False
    cwds, titles = f
    return not any(folder_blocked(rx, c) for c in cwds if c) and not any(rx.search(t) for t in titles if t)


def collect_claude(rx, top):
    """(dest under raw/chats/claude-code/<host>/, source) for what cc_chats reads: <project>/<session>.jsonl
    and <project>/<session>/subagents/*.jsonl; never memory/ or tool-results/. A project folder whose
    name is excluded or a temp root goes whole; a session whose cwd or title is, with its subagents."""
    for proj in sorted(os.listdir(top)):
        pd = os.path.join(top, proj)
        if not os.path.isdir(pd) or rx.search(proj) or temp_folder(proj):
            continue
        for fn in sorted(os.listdir(pd)):
            p = os.path.join(pd, fn)
            if fn.endswith(".jsonl") and os.path.isfile(p):
                if chat_ok(rx, p):
                    yield "%s/%s" % (proj, fn), p
            elif os.path.isdir(os.path.join(p, "subagents")):
                parent = p + ".jsonl"
                if os.path.isfile(parent) and not chat_ok(rx, parent):
                    continue
                sd = os.path.join(p, "subagents")
                for sub in sorted(os.listdir(sd)):
                    sp = os.path.join(sd, sub)
                    if sub.endswith(".jsonl") and os.path.isfile(sp) and chat_ok(rx, sp):
                        yield "%s/%s/subagents/%s" % (proj, fn, sub), sp


def codex_meta(path):
    """The first session_meta payload of a rollout (the rollout's own; a fork repeats its parent's)."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if i > 50:
                    break
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if isinstance(rec, dict) and rec.get("type") == "session_meta" and isinstance(rec.get("payload"), dict):
                    return rec["payload"]
    except OSError:
        pass
    return None


def collect_codex(rx, top):
    """(dest under raw/chats/codex/<host>/, source) per rollout: one with a session_meta cwd, not a
    consult of ours (originator codex_exec), and no cwd anywhere in it excluded or a temp root."""
    for root, dirs, files in os.walk(top):
        dirs.sort()
        for fn in sorted(files):
            if not (fn.startswith("rollout-") and fn.endswith(".jsonl")):
                continue
            p = os.path.join(root, fn)
            meta = codex_meta(p)
            if not meta or meta.get("originator") == "codex_exec":
                continue
            cwd = meta.get("cwd") if isinstance(meta.get("cwd"), str) else ""
            if not cwd or folder_blocked(rx, cwd) or not chat_ok(rx, p):
                continue
            yield os.path.relpath(p, top).replace(os.sep, "/"), p


def collect_gemini(rx, top):
    """(dest under raw/chats/gemini/<host>/, source) per slug: <slug>/.project_root and its
    chats/session-*.jsonl, flattened to <slug>/. A slug with no .project_root has no folder to check
    and is left out, as is one whose name or folder is excluded or a temp root."""
    for slug in sorted(os.listdir(top)):
        d = os.path.join(top, slug)
        rp = os.path.join(d, ".project_root")
        try:
            with open(rp, encoding="utf-8", errors="replace") as f:
                root = f.read().strip()
        except OSError:
            continue
        if not root or rx.search(slug) or folder_blocked(rx, root):
            continue
        cd = os.path.join(d, "chats")
        sessions = sorted(fn for fn in (os.listdir(cd) if os.path.isdir(cd) else [])
                          if fn.startswith("session-") and fn.endswith(".jsonl") and os.path.isfile(os.path.join(cd, fn)))
        if not sessions:
            continue
        yield "%s/.project_root" % slug, rp
        for fn in sessions:
            yield "%s/%s" % (slug, fn), os.path.join(cd, fn)


def cmd_collect_list(host, stage, claude, codex, gemini):
    """Print the files to copy, relative to raw/chats/; with STAGE, also link each one there at that
    path (the collector rsyncs the stage with --copy-links, so the source layout never matters)."""
    if not host or "/" in host or host in (".", ".."):
        sys.exit("collect-list: bad host name")
    rx = excluder()
    for src, top, walk in (("claude-code", claude, collect_claude), ("codex", codex, collect_codex),
                           ("gemini", gemini, collect_gemini)):
        if not top or not os.path.isdir(top):
            continue
        for rel, p in walk(rx, top):
            dest = "%s/%s/%s" % (src, host, rel)
            if stage:
                link = os.path.join(stage, dest)
                os.makedirs(os.path.dirname(link), exist_ok=True)
                if os.path.lexists(link):
                    os.remove(link)
                os.symlink(os.path.abspath(p), link)
            print(dest)


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


def save_tracked(p, obj):
    """Like save, but readable (0644): the file is committed."""
    save(p, obj)
    os.chmod(p, 0o644)


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


def signature(p):
    st = os.stat(p)
    return {"size": st.st_size, "mtime": int(st.st_mtime)}


def cc_chats(brain):
    """The Claude Code chats a digest pass reads, as (path, host, project, kind, digest path under
    raw/digests/claude-code/): each session (kind "session"), and each subagent sidechain whose parent
    session is not here (kind "subagent"); one whose parent is here comes back with kind None."""
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
                yield p, host, project, "session", "%s/%s/%s.md" % (host, project, fn[:-6])
            elif len(parts) == 5 and parts[3] == "subagents":
                # A subagent's sidechain: only when its parent session is not here.
                if os.path.exists(os.path.join(cc, host, project, parts[2] + ".jsonl")):
                    yield p, host, project, None, None
                else:
                    yield p, host, project, "subagent", "%s/%s/%s-%s.md" % (host, project, parts[2], fn[:-6])


def codex_chats(brain):
    """The Codex rollouts a digest pass reads, in cc_chats' shape: (path, host, None, "codex", digest
    path under raw/digests/codex/). Layout raw/chats/codex/<host>/YYYY/MM/DD/rollout-*.jsonl; the
    digest drops the date folders (a rollout's name carries its time and id)."""
    top = os.path.join(brain, "raw", "chats", "codex")
    for root, dirs, files in os.walk(top):
        dirs.sort()
        for fn in sorted(files):
            if not (fn.startswith("rollout-") and fn.endswith(".jsonl")):
                continue
            p = os.path.join(root, fn)
            parts = os.path.relpath(p, top).split(os.sep)
            if len(parts) < 2:
                continue
            yield p, parts[0], None, "codex", "%s/%s.md" % (parts[0], fn[:-6])


def gemini_chats(brain):
    """The Gemini sessions, in cc_chats' shape: (path, host, slug, "gemini", digest path under
    raw/digests/gemini/). Layout raw/chats/gemini/<host>/<slug>/{session-*.jsonl,.project_root}."""
    top = os.path.join(brain, "raw", "chats", "gemini")
    for root, dirs, files in os.walk(top):
        dirs.sort()
        for fn in sorted(files):
            if not (fn.startswith("session-") and fn.endswith(".jsonl")):
                continue
            p = os.path.join(root, fn)
            parts = os.path.relpath(p, top).split(os.sep)
            if len(parts) < 3:
                continue
            yield p, parts[0], parts[1], "gemini", "%s/%s/%s.md" % (parts[0], parts[1], fn[:-6])


def chats(brain):
    """Every session a digest pass reads, as (source, path, host, project, kind, out): Claude Code,
    Codex and Gemini. The digest goes to raw/digests/<source>/<out>."""
    for src, walk in (("claude-code", cc_chats), ("codex", codex_chats), ("gemini", gemini_chats)):
        for row in walk(brain):
            yield (src,) + row


def chat_signature(p, kind):
    """A Gemini session's signature takes in its .project_root, so one that arrives later (it decides
    the cwd, and with it the exclusion) makes the session fresh again."""
    sig = signature(p)
    if kind == "gemini":
        sig["root"] = sha(gemini_root(p) or "")[:16]
    return sig


def path_fields(rel):
    """The folder names in a digest's path that exclusion also looks at: host and project folder for
    Claude Code and Gemini, the account for claude.ai, the host for Codex. The cwd header decides
    the rest."""
    p = rel.split("/")
    if p[:3] in (["raw", "digests", "claude-code"], ["raw", "digests", "gemini"]):
        return p[3:5]
    return p[3:4]


def ai_exports(brain):
    """The claude.ai exports, as (path, account), oldest first: date folders sort that way, so a later
    export wins."""
    ai = os.path.join(brain, "raw", "chats", "claude-ai")
    exports = []
    for root, dirs, files in os.walk(ai):
        if "conversations.json" in files:
            exports.append(os.path.join(root, "conversations.json"))
    return [(p, os.path.relpath(p, ai).split(os.sep)[0]) for p in sorted(exports)]


def cmd_fresh(brain):
    """How many raw chats are new or changed since the last digest pass (read only; the ingest's gate)."""
    done = load(os.path.join(brain, "raw", ".state", "digested.json"), {})
    n = sum(1 for _, p, _, _, kind, _ in chats(brain) if kind and done.get(os.path.relpath(p, brain)) != chat_signature(p, kind))
    n += sum(1 for p, _ in ai_exports(brain) if done.get(os.path.relpath(p, brain)) != signature(p))
    print(n)


def cmd_digest(brain):
    sd = os.path.join(brain, "raw", ".state")
    done = load(os.path.join(sd, "digested.json"), {})
    index = load(os.path.join(sd, "digests.json"), {})
    stats = Counter()
    largest = 0
    rx = excluder()
    # Digests made before an exclusion applied (an older version, or a wider BRAIN_EXCLUDE now) go
    # too: every indexed digest is checked again on each pass.
    for rel in sorted(index):
        extra = path_fields(rel)
        try:
            with open(os.path.join(brain, rel), encoding="utf-8", errors="replace") as f:
                head = f.read(4000)
        except OSError:
            head = ""
        if excluded(rx, head, *extra):
            stats["excluded"] += 1
            drop_digest(brain, index, rel)
    for src, p, host, project, kind, out in chats(brain):
        if kind is None:
            stats["subagent_skipped"] += 1
            continue
        key, sig = os.path.relpath(p, brain), chat_signature(p, kind)
        if done.get(key) == sig:
            stats["unchanged"] += 1
            continue
        why = None
        if kind == "codex":
            text, first, last, n, why = digest_codex(p)
        elif kind == "gemini":
            text, first, last, n, why = digest_gemini(p, project)
        else:
            text, first, last, n = digest_session(p, project, kind == "subagent")
        rel = os.path.join("raw", "digests", src, out)
        if why or n == 0:
            # A consult of our own, a session with no folder or no owner message: no digest, and one
            # made earlier goes.
            stats[why or "empty"] += 1
            drop_digest(brain, index, rel)
            done[key] = sig
            continue
        if excluded(rx, text, host, project):
            stats["excluded"] += 1
            drop_digest(brain, index, rel)
            done[key] = sig
            continue
        text = cap(mask(text))
        write_digest(brain, rel, text)
        index[rel] = {"first": first, "last": last, "chars": len(text), "sha": sha(text), "source": key}
        done[key] = sig
        stats["written_" + kind] += 1
        stats["chars"] += len(text)
        largest = max(largest, len(text))
    for p, account in ai_exports(brain):
        key, sig = os.path.relpath(p, brain), signature(p)
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
            rel = os.path.join("raw", "digests", "claude-ai", account, re.sub(r"[^A-Za-z0-9_\-]", "_", conv["uuid"]) + ".md")
            if excluded(rx, text, account):
                stats["excluded"] += 1
                drop_digest(brain, index, rel)
                continue
            text = cap(mask(text))
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


def cmd_mark(brain, why=None, shas_file=None):
    """Record the digests and owner notes on stdin as ingested. With WHY, as skipped instead: they
    leave the queue the same way, and raw/.state/skipped.json keeps the reason (a later change
    re-queues them). An owner note is recorded at the hash of the copy the merge saw (SHAS, from
    brain_merge.py prepare), so an edit made during the run comes back the next night."""
    sd = os.path.join(brain, "raw", ".state")
    index = load(os.path.join(sd, "digests.json"), {})
    ing = load(os.path.join(sd, "ingested.json"), {})
    skipped = load(os.path.join(sd, "skipped.json"), {})
    shas = load(shas_file, {}) if shas_file else {}
    n = 0
    for line in sys.stdin:
        rel = line.strip()
        h = None
        if rel in index:
            h = index[rel]["sha"]
        elif rel.startswith(NOTES) and ".." not in rel.split("/"):
            h = shas.get(rel)
            if h is None:
                try:
                    h = note_text(brain, rel)[1]
                except OSError:
                    h = None
        if h:
            ing[rel] = h
            if why:
                skipped[rel] = {"sha": h, "why": why,
                                "at": datetime.datetime.now().isoformat(timespec="seconds")}
            n += 1
    save(os.path.join(sd, "ingested.json"), ing)
    if why:
        save(os.path.join(sd, "skipped.json"), skipped)
    print(n)


# --- owner notes (raw/notes) -----------------------------------------------------------------------
NOTES = "raw/notes/"
NOTE_CAP = 20000


def _git(brain, *args):
    return subprocess.run(["git", "-C", brain, "-c", "core.quotePath=false"] + list(args),
                          capture_output=True, check=True).stdout.decode("utf-8", "surrogateescape")


def _names(out):
    return set(p for p in out.split("\0") if p)


def note_files(brain):
    """(ready, waiting): raw/notes/**/*.md committed at HEAD and unchanged in the work tree, and the
    ones not committed yet (new, or edited since). Only a committed note is queued, so a citation to
    raw/notes/<file> can be checked from any clone."""
    try:
        # Regular files only: a committed symlink (mode 120000) or submodule could point outside.
        head = set(e.split("\t", 1)[1] for e in _git(brain, "ls-tree", "-r", "-z", "HEAD", "--", "raw/notes").split("\0")
                   if "\t" in e and e.split(" ", 1)[0] in ("100644", "100755"))
        changed = _names(_git(brain, "diff", "--name-only", "-z", "HEAD", "--", "raw/notes"))
        new = _names(_git(brain, "ls-files", "-z", "-o", "--exclude-standard", "--", "raw/notes"))
    except (OSError, subprocess.CalledProcessError):
        return [], []
    md = lambda p: p.endswith(".md") and not os.path.basename(p).startswith(".")
    ready = sorted(p for p in head - changed if md(p) and os.path.isfile(os.path.join(brain, p))
                   and inside(brain, p))
    return ready, sorted(p for p in (changed | new) if md(p))


def inside(brain, rel):
    """The note is a plain file under raw/notes: no symlink anywhere on its path, no '..', and
    nothing outside raw/notes once resolved."""
    parts = rel.split("/")
    if not rel.startswith(NOTES) or ".." in parts:
        return False
    if any(os.path.islink(os.path.join(brain, *parts[:i])) for i in range(1, len(parts) + 1)):
        return False
    base = os.path.realpath(os.path.join(brain, NOTES))
    return os.path.realpath(os.path.join(brain, rel)).startswith(base + os.sep)


def note_bytes(brain, rel):
    """A note's bytes, refused (OSError) unless it is a plain file inside raw/notes."""
    if not inside(brain, rel):
        raise OSError("not a plain file inside raw/notes")
    with open(os.path.join(brain, rel), "rb") as f:
        return f.read()


def note_text(brain, rel):
    """(text, sha of the bytes): the hash the queue, the copy into stage B and the mark all use."""
    b = note_bytes(brain, rel)
    return b.decode("utf-8", "replace"), hashlib.sha256(b).hexdigest()


def note_date(brain, rel):
    """The date of the note's last commit (YYYY-MM-DD), the date its citations carry."""
    try:
        return _git(brain, "log", "-1", "--format=%cs", "--", rel).strip() or "unknown"
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def note_problem(rel, text):
    """Why an owner note may not go to the merge, or None. The same strict masker the merge's
    secret-in-wiki check uses, line by line; work material by its name or title (BRAIN_EXCLUDE); a
    note over NOTE_CAP (notes are meant to be short: one too big for a merge would block the queue;
    split it); a name with a newline or control character."""
    if re.search(r"[\x00-\x1f\x7f]", rel):
        return "bad-name"
    if len(text) > NOTE_CAP:
        return "too-large"
    title = next((l.lstrip("#").strip() for l in text.splitlines() if l.startswith("#")), "")
    if excluded(excluder(), text, rel[len(NOTES):], title):
        return "work"
    if any(strict(l) != l for l in text.splitlines()):
        return "secret"
    return None


def pending_notes(brain):
    """Committed owner notes not yet ingested at their current content, oldest commit first:
    (date, rel, {sha, chars, date, problem})."""
    ing = load(os.path.join(brain, "raw", ".state", "ingested.json"), {})
    rows = []
    for rel in note_files(brain)[0]:
        try:
            text, h = note_text(brain, rel)
        except OSError:
            continue
        if ing.get(rel) == h:
            continue
        d = note_date(brain, rel)
        rows.append((d, rel, {"sha": h, "chars": len(text), "date": d, "problem": note_problem(rel, text)}))
    rows.sort()
    return rows


def cmd_notes(brain, op):
    rows = pending_notes(brain)
    if op == "pending":
        ok = [v for _, _, v in rows if not v["problem"]]
        print("%d %d %d" % (len(ok), sum(v["chars"] for v in ok), len(note_files(brain)[1])))
        return
    sd = os.path.join(brain, "raw", ".state")
    ing = load(os.path.join(sd, "ingested.json"), {})
    skipped = load(os.path.join(sd, "skipped.json"), {})
    stats, out = Counter(), []
    for _, rel, v in rows:
        if not v["problem"]:
            stats["queued"] += 1
            stats["chars"] += v["chars"]
            continue
        # Skipped at this content: it leaves the queue, and an edit (a new hash) brings it back.
        ing[rel] = v["sha"]
        skipped[rel] = {"sha": v["sha"], "why": v["problem"],
                        "at": datetime.datetime.now().isoformat(timespec="seconds")}
        stats["skipped_" + v["problem"]] += 1
        out.append("skipped %s: %s%s" % (v["problem"], re.sub(r"[\x00-\x1f\x7f]", "?", rel),
                                          " (split it into notes under %d characters)" % NOTE_CAP
                                          if v["problem"] == "too-large" else ""))
    if out:
        save(os.path.join(sd, "ingested.json"), ing)
        save(os.path.join(sd, "skipped.json"), skipped)
    stats["uncommitted"] = len(note_files(brain)[1])
    print(" ".join(["%s=%d" % (k, v) for k, v in sorted(stats.items())] + out))


def month():
    return os.environ.get("BRAIN_MONTH") or datetime.date.today().strftime("%Y-%m")


def cost_path(brain):
    return os.path.join(brain, "state", "costs.json")


def _costs(brain):
    p = cost_path(brain)
    costs = load(p, None)
    if costs is None:  # a first run starts from the old local record
        costs = load(os.path.join(brain, "raw", ".state", "costs.json"), {})
    m = costs.setdefault(month(), {"usd": 0.0, "runs": [], "alerted": False})
    return p, costs, m


def month_usd(brain):
    """This month's spend so far (ingest, condense and lint together)."""
    return float(_costs(brain)[2]["usd"])


def add_cost(brain, usd, kind="ingest", items=0):
    """Append one Claude call's or run's spend to this month (state/costs.json, tracked)."""
    p, costs, m = _costs(brain)
    m["usd"] = round(m["usd"] + float(usd), 6)
    m["runs"].append({"at": datetime.datetime.now().isoformat(timespec="seconds"), "usd": float(usd),
                      "kind": kind, "items": int(items)})
    save_tracked(p, costs)


def cmd_cost(brain, args):
    # Tracked in the brain (state/costs.json) and committed by the job, so the month's spend moves
    # with the brain to whichever machine is primary.
    p, costs, m = _costs(brain)
    op = args[0] if args else "month"
    if op == "add":
        add_cost(brain, args[1], args[2] if len(args) > 2 else "ingest", args[3] if len(args) > 3 else 0)
    elif op == "month":
        print("%.2f" % m["usd"])
    elif op == "alerted":
        sys.exit(0 if m.get("alerted") else 1)
    elif op == "set-alerted":
        m["alerted"] = True
        save_tracked(p, costs)
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
    if op == "collect-list":
        if len(argv) != 7:
            sys.exit(__doc__)
        cmd_collect_list(*argv[2:7])
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
    elif op == "fresh":
        cmd_fresh(brain)
    elif op == "mark":
        cmd_mark(brain, None, argv[3] if len(argv) > 3 else None)
    elif op == "skip":
        cmd_mark(brain, argv[3] if len(argv) > 3 else "skipped", argv[4] if len(argv) > 4 else None)
    elif op == "notes":
        cmd_notes(brain, argv[3] if len(argv) > 3 else "check")
    elif op == "cost":
        cmd_cost(brain, argv[3:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
