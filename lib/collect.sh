#!/usr/bin/env bash
# Copies this host's Claude Code chats into the wiki's raw/chats/ for the ingest (lib/ingest.sh):
# <collect_from> (default ~/.claude/projects) -> raw/chats/claude-code/<host>/<project>/, where
# <host> is host_name (lib/common.sh). The list is made here, before anything moves
# (brain_digest.py collect-list): work material (BRAIN_EXCLUDE) and temp folders never leave this
# host. rsync -a keeps each file's mtime (the digest pass's signature); nothing is ever deleted at
# the wiki. Never prints a chat's contents: counts and paths of directories only.
#   librarian collect [--hourly] [--to DEST [--rsh CMD]]
#     (no DEST)   copy into this host's wiki (wiki_dir)
#     --to DEST   copy into DEST/raw/chats/ instead: a local directory, or host:/dir pushed over
#                 rsync's remote shell (--rsh CMD, e.g. "ssh -o BatchMode=yes"); a push stops after
#                 300 s without I/O, so a stalled peer never freezes the caller
#     --hourly    do nothing when the last collection was under an hour ago (the stamp is
#                 <state_dir>/.brain-collected)
# A failed copy is one log line and exit 0: collection is best effort, the ingest goes on with what is
# there. One collection at a time (<state_dir>/.brain-collect.lock); a lock whose holder is gone is
# taken over.
set -euo pipefail
. "$(dirname "$0")/common.sh"
load_config
umask 077
hourly=""; dest=""; rsh=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hourly) hourly=1; shift ;;
    --to) [ $# -ge 2 ] || { echo "usage: librarian collect [--hourly] [--to DEST [--rsh CMD]]" >&2; exit 2; }; dest="$2"; shift 2 ;;
    --rsh) [ $# -ge 2 ] || { echo "usage: librarian collect [--hourly] [--to DEST [--rsh CMD]]" >&2; exit 2; }; rsh="$2"; shift 2 ;;
    run) shift ;;
    *) echo "usage: librarian collect [--hourly] [--to DEST [--rsh CMD]]" >&2; exit 2 ;;
  esac
done
SD="$(state_dir)"; mkdir -p "$SD"
STAMP="$SD/.brain-collected"; LOCK="$SD/.brain-collect.lock"
if [ -n "$hourly" ]; then
  last="$(cat "$STAMP" 2>/dev/null || echo 0)"; case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $(( $(date +%s) - last )) -ge 3600 ] || exit 0
fi

remote=""
if [ -z "$dest" ]; then
  w="$(envget LIBRARIAN_WIKI_DIR)"
  [ -n "$w" ] || { log "brain collect: no wiki set (wiki_dir, LIBRARIAN_WIKI_DIR); nothing collected"; exit 0; }
  dest="$(abs_path wiki_dir "$w")" || exit 0
else
  case "$dest" in
    /*) ;;
    *:/*) remote=1 ;;
    *) log "brain collect: --to $dest is neither an absolute path nor host:/path; nothing collected"; exit 0 ;;
  esac
fi
src="$(abs_path collect_from "$(envget LIBRARIAN_COLLECT_FROM "$HOME/.claude/projects")")" || exit 0

if ! mkdir "$LOCK" 2>/dev/null; then
  pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then log "brain collect: another collection is running; skipped"; exit 0; fi
  rm -rf "$LOCK"; mkdir "$LOCK" || exit 0
fi
echo $$ > "$LOCK/pid"
LINKS="$(mktemp -d "${TMPDIR:-/tmp}/brain-collect.XXXXXX")"; LIST="$LINKS.list"
trap 'rm -rf "$LINKS" "$LIST" "$LOCK"' EXIT

python3 "$LIB/brain_digest.py" collect-list "$(host_name)" "$LINKS" "$src" > "$LIST"
n="$(wc -l < "$LIST" | tr -d ' ')"
[ "$n" -gt 0 ] || { log "brain collect: no chats to copy"; date +%s > "$STAMP"; exit 0; }

# --copy-links: the links dir holds one per listed file at its wiki path; the file itself is sent.
if [ -z "$remote" ]; then
  mkdir -p "$dest/raw/chats"
  if rsync -aL --files-from="$LIST" "$LINKS/" "$dest/raw/chats/" 2>/dev/null; then
    log "brain collect: collected $n chat files into the brain"
  else log "brain collect: could not copy chats into $dest/raw/chats"; exit 0; fi
else
  if rsync -aL --timeout=300 ${rsh:+-e "$rsh"} --files-from="$LIST" "$LINKS/" "$dest/raw/chats/" 2>/dev/null; then
    log "brain collect: copied $n chat files to ${dest%%:*}"
  else log "brain collect: could not copy chats to ${dest%%:*}"; exit 0; fi
fi
date +%s > "$STAMP"
