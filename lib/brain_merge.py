#!/usr/bin/env python3
"""Stage B of the brain's ingest, the file side (stdlib only; called by lib/ingest.sh). Claude works
in a temp dir that holds only wiki/, index.md, log.md, CLAUDE.md and tonight's condensed notes;
these steps build that dir, check what came back, and copy back wiki/, index.md and log.md only.

  brain_merge.py dirty BRAIN                  exit 1 (printing a count) when the brain has uncommitted
                                              changes: a tracked file, or an untracked file under wiki/,
                                              index.md or log.md. state/costs.json (the job's own) and
                                              raw/ are not counted.
  brain_merge.py prepare BRAIN WORK QUEUE     copy the four parts, the queued owner notes (raw/notes, to
                                              WORK/notes/_raw-notes/, checked again) and the queued
                                              digests' condensed notes into WORK; write
                                              WORK/../hand-pages (one per line) and WORK/../note-shas.json
                                              (each owner note's hash as copied) and print the note
                                              paths (relative to WORK), an owner note's with its
                                              citation path and date
  brain_merge.py check BRAIN WORK DATE HAND   ok, or the failure class: stray-writes, no-log-entry,
                                              log-rewritten, hand-edit, secret-in-wiki
  brain_merge.py apply BRAIN WORK CREATED     copy changed and new files back; CREATED gets the new
                                              ones (NUL-separated) for a rollback; prints counts
  brain_merge.py plan BRAIN WORK              what apply would copy back, without copying: one
                                              "new PATH" or "changed PATH" line each, then the counts
  brain_merge.py rollback BRAIN CREATED       tracked wiki/, index.md, log.md back to HEAD; the files
                                              in CREATED removed

A hand-edited page is a wiki page whose last commit subject does not start with one of the job's
or the bootstrap's prefixes (JOB_PREFIXES: ingest:, brain:, log:, rules:, design:); every page that
exists from the bootstrap is therefore the job's. Claude may only add lines to a hand-edited page,
and must name it in the night's log entry. Prints paths and counts only.
"""
import filecmp
import hashlib
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import brain_condense as bc  # noqa: E402
import brain_digest as bd  # noqa: E402

COPIED = ("CLAUDE.md", "index.md", "log.md")
# Owner notes go under WORK/notes/ in a folder no host name can take (no underscore in a host name).
OWN = "notes/_raw-notes/"
# Commit subjects that mark a page as the job's (the nightly ingest, and the bootstrap commits that
# wrote the first pages). Any other subject is the owner's hand.
JOB_PREFIXES = ("ingest:", "brain:", "log:", "rules:", "design:")
BACK = ("index.md", "log.md")


def git(brain, *args):
    return subprocess.run(["git", "-C", brain, "-c", "core.quotePath=false"] + list(args),
                          capture_output=True, check=True).stdout


def status(brain):
    """(XY, path) for every entry of `git status --porcelain -z`; names with spaces, quotes or
    non-ASCII come through as they are."""
    out = git(brain, "status", "--porcelain", "-z", "--untracked-files=all").decode("utf-8", "surrogateescape")
    items, parts, i = [], out.split("\0"), 0
    while i < len(parts):
        e = parts[i]
        i += 1
        if len(e) < 4:
            continue
        xy, path = e[:2], e[3:]
        if xy[0] in "RC":  # a rename carries its source as the next field
            i += 1
        items.append((xy, path))
    return items


def cmd_dirty(brain):
    n = 0
    for xy, path in status(brain):
        if path == "state/costs.json" or path.startswith("raw/"):
            continue
        if xy == "??" and not (path.startswith("wiki/") or path in BACK):
            continue
        n += 1
    if n:
        print("%d uncommitted change(s)" % n)
        sys.exit(1)


def walk(root, sub):
    out = []
    base = os.path.join(root, sub)
    for d, dirs, files in os.walk(base):
        dirs.sort()
        for f in sorted(files):
            out.append(os.path.relpath(os.path.join(d, f), root))
    return out


def hand_pages(brain):
    pages = git(brain, "ls-files", "-z", "--", "wiki").decode("utf-8", "surrogateescape").split("\0")
    out = []
    for p in pages:
        if not p or not p.endswith(".md"):
            continue
        subj = git(brain, "log", "-1", "--format=%s", "--", p).decode("utf-8", "replace").strip()
        if subj and not subj.startswith(JOB_PREFIXES):
            out.append(p)
    return out


def cmd_prepare(brain, work, queue):
    os.makedirs(work, exist_ok=True)
    for f in COPIED:
        if os.path.exists(os.path.join(brain, f)):
            shutil.copy2(os.path.join(brain, f), os.path.join(work, f))
    if os.path.isdir(os.path.join(brain, "wiki")):
        shutil.copytree(os.path.join(brain, "wiki"), os.path.join(work, "wiki"), symlinks=True)
    else:
        os.makedirs(os.path.join(work, "wiki"))
    shas = {}
    for rel in open(queue, encoding="utf-8").read().split("\n"):
        rel = rel.strip()
        if not rel:
            continue
        if rel.startswith(bd.NOTES):
            # Copied as bytes, checked again as copied (it may have changed since the queue was made).
            try:
                b = bd.note_bytes(brain, rel)
            except OSError:
                sys.exit("prepare: an owner note is not a plain file inside raw/notes")
            if bd.note_problem(rel, b.decode("utf-8", "replace")):
                sys.exit("prepare: an owner note changed and now fails its check")
            dst = OWN + rel[len(bd.NOTES):]
            os.makedirs(os.path.dirname(os.path.join(work, dst)), exist_ok=True)
            with open(os.path.join(work, dst), "wb") as f:
                f.write(b)
            shas[rel] = hashlib.sha256(b).hexdigest()
            print("%s (owner note: cite %s, %s)" % (dst, rel, bd.note_date(brain, rel)))
            continue
        src = bc.note_rel(rel)
        dst = os.path.join("notes", src[len("raw/notes-condensed/"):])
        os.makedirs(os.path.dirname(os.path.join(work, dst)), exist_ok=True)
        shutil.copy2(os.path.join(brain, src), os.path.join(work, dst))
        print(dst)
    with open(os.path.join(os.path.dirname(work), "hand-pages"), "w", encoding="utf-8") as f:
        for p in hand_pages(brain):
            f.write(p + "\n")
    bd.save(os.path.join(os.path.dirname(work), "note-shas.json"), shas)


def lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().splitlines()
    except OSError:
        return []


def added(old, new):
    """Lines of new that old does not have (as a multiset)."""
    have = {}
    for l in old:
        have[l] = have.get(l, 0) + 1
    out = []
    for l in new:
        if have.get(l, 0):
            have[l] -= 1
        else:
            out.append(l)
    return out


def digest_of(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def cmd_check(brain, work, date, hand_file):
    hand = [l for l in lines(hand_file) if l]
    # Stray writes: CLAUDE.md or a note changed, a new file outside wiki/, or a link anywhere.
    for d, dirs, files in os.walk(work):
        for f in files + dirs:
            p = os.path.join(d, f)
            rel = os.path.relpath(p, work)
            if os.path.islink(p):
                return "stray-writes"
            if os.path.isdir(p):
                continue
            top = rel.split(os.sep)[0]
            if top == "wiki" or rel in BACK:
                continue
            if rel == "CLAUDE.md":
                if digest_of(p) != digest_of(os.path.join(brain, "CLAUDE.md")):
                    return "stray-writes"
                continue
            if rel.replace(os.sep, "/").startswith(OWN):
                # An owner note must be the copy prepare made; a new file there is a stray write.
                want = bd.load(os.path.join(os.path.dirname(work), "note-shas.json"), {}).get(
                    bd.NOTES + rel.replace(os.sep, "/")[len(OWN):])
                if want is None or digest_of(p) != want:
                    return "stray-writes"
                continue
            if top == "notes":
                src = os.path.join(brain, "raw", "notes-condensed", rel[len("notes/"):])
                if not os.path.exists(src) or digest_of(p) != digest_of(src):
                    return "stray-writes"
                continue
            return "stray-writes"
    # The log: append-only, with one entry for tonight.
    old_log, new_log = lines(os.path.join(brain, "log.md")), lines(os.path.join(work, "log.md"))
    if new_log[:len(old_log)] != old_log:
        return "log-rewritten"
    entry, inside = [], False
    for l in new_log[len(old_log):]:
        if l.startswith("## "):
            inside = l.startswith("## [%s] ingest" % date)
        if inside:
            entry.append(l)
    if not entry:
        return "no-log-entry"
    entry_text = "\n".join(entry)
    # Hand-edited pages: kept whole (every line still there), added to only, named in the entry.
    for p in hand:
        old, newp = os.path.join(brain, p), os.path.join(work, p)
        if not os.path.exists(newp):
            return "hand-edit"
        if digest_of(old) == digest_of(newp):
            continue
        if added(lines(newp), lines(old)) or p not in entry_text:
            return "hand-edit"
    # Secrets: every added line of every page, the index and the log through the strict masker.
    for rel in walk(work, "wiki") + list(BACK):
        for l in added(lines(os.path.join(brain, rel)), lines(os.path.join(work, rel))):
            if bd.strict(l) != l:
                return "secret-in-wiki"
    return "ok"


def cmd_apply(brain, work, created_file):
    changed = new = 0
    created = []
    for rel in walk(work, "wiki") + list(BACK):
        src, dst = os.path.join(work, rel), os.path.join(brain, rel)
        if not os.path.exists(src):
            continue
        if os.path.exists(dst):
            if filecmp.cmp(src, dst, shallow=False):
                continue
            changed += 1
        else:
            new += 1
            created.append(rel)
            # Recorded before the copy, so an interrupt in between still removes it.
            with open(created_file, "w", encoding="utf-8") as f:
                f.write("\0".join(created))
            os.makedirs(os.path.dirname(dst) or brain, exist_ok=True)
        shutil.copyfile(src, dst)
    with open(created_file, "w", encoding="utf-8") as f:
        f.write("\0".join(created))
    print("changed=%d new=%d" % (changed, new))


def cmd_plan(brain, work):
    """What apply would do, without doing it: one line per file ("new PATH" or "changed PATH"),
    then the counts line apply prints."""
    changed = new = 0
    for rel in walk(work, "wiki") + list(BACK):
        src, dst = os.path.join(work, rel), os.path.join(brain, rel)
        if not os.path.exists(src):
            continue
        if os.path.exists(dst):
            if filecmp.cmp(src, dst, shallow=False):
                continue
            changed += 1
            print("changed %s" % rel)
        else:
            new += 1
            print("new %s" % rel)
    print("changed=%d new=%d" % (changed, new))


def cmd_rollback(brain, created_file):
    subprocess.run(["git", "-C", brain, "reset", "-q", "--", "wiki", "index.md", "log.md"], capture_output=True)
    subprocess.run(["git", "-C", brain, "checkout", "-q", "--", "wiki", "index.md", "log.md"], capture_output=True)
    try:
        created = open(created_file, encoding="utf-8").read().split("\0")
    except OSError:
        created = []
    n = 0
    for rel in created:
        if rel and (rel.startswith("wiki/") or rel in BACK) and ".." not in rel.split("/"):
            try:
                os.remove(os.path.join(brain, rel))
                n += 1
            except OSError:
                pass
    print("removed=%d" % n)


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    op, brain = argv[1], os.path.abspath(argv[2])
    if op == "dirty":
        cmd_dirty(brain)
    elif op == "prepare":
        cmd_prepare(brain, argv[3], argv[4])
    elif op == "check":
        print(cmd_check(brain, argv[3], argv[4], argv[5]))
    elif op == "apply":
        cmd_apply(brain, argv[3], argv[4])
    elif op == "plan":
        cmd_plan(brain, argv[3])
    elif op == "rollback":
        cmd_rollback(brain, argv[3])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
