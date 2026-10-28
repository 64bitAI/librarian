#!/usr/bin/env bash
# Copies this host's chats into the brain's raw/chats/ for the nightly ingest (brain-ingest.sh):
# Claude Code ($(claude_config_dir)/projects -> claude-code/<host>/<project>/).
# <host> is SWARM_MACHINE (else the short hostname). The list is made here, before anything moves
# (brain_digest.py collect-list): work material (BRAIN_EXCLUDE) and temp folders never leave this
# host. rsync -a keeps each file's mtime (the
# digest pass's signature); nothing is ever deleted at the brain.
#   primary  copies into its own brain (this swarm's SWARM_BRAIN_DIR)
#   standby  pushes to the primary over the pair ssh, into the brain directory the primary names
#            (stack-role.sh brain); an unreachable or old-code primary is one log line, exit 0
# Only a swarm whose .env sets SWARM_BRAIN_DIR collects (another swarm's Claude home never travels);
# the brain and the Claude config come from that .env, never from the calling session's environment.
# Never prints a chat's contents: counts and paths of directories only.
#   scripts/brain-collect.sh [run]   collect now (brain-ingest.sh run, before its gate)
#   scripts/brain-collect.sh hourly  the same, unless the last collection was under an hour ago
#                                    (standby-sync.sh's standby pass; the stamp is $STATE/.brain-collected)
set -euo pipefail
. "$(dirname "$0")/common.sh"
swarm_init "$@" || exit 1; set -- "${SWARM_ARGS[@]+"${SWARM_ARGS[@]}"}"
umask 077
log() { printf '%s %s\n' "$(date +%FT%T)" "$*"; }
STAMP="$STATE/.brain-collected"; LOCK="$STATE/.brain-collect.lock"

case "${1:-run}" in
  run) ;;
  hourly)
    last="$(cat "$STAMP" 2>/dev/null || echo 0)"; case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $(( $(date +%s) - last )) -ge 3600 ] || exit 0 ;;
  *) echo "usage: $0 [run|hourly]" >&2; exit 2 ;;
esac

[ -n "$(envfile_get SWARM_BRAIN_DIR)" ] || { log "brain collect: SWARM_BRAIN_DIR is not set in this swarm's .env; nothing collected"; exit 0; }
# One collection at a time; a lock whose holder is gone is taken over.
if ! mkdir "$LOCK" 2>/dev/null; then
  pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then log "brain collect: another collection is running; skipped"; exit 0; fi
  rm -rf "$LOCK"; mkdir "$LOCK" || exit 0
fi
echo $$ > "$LOCK/pid"
LINKS="$(mktemp -d "${TMPDIR:-/tmp}/brain-collect.XXXXXX")"; LIST="$LINKS.list"
trap 'rm -rf "$LINKS" "$LIST" "$LOCK"' EXIT

role="$(role_get role)"
case "$role" in
  primary) dest="$(_abs_path SWARM_BRAIN_DIR "$(envfile_get SWARM_BRAIN_DIR)")" || exit 0 ;;
  standby)
    t="$(envget SWARM_PAIR_SSH)"
    [ -n "$t" ] || { log "brain collect: standby with no SWARM_PAIR_SSH; nothing to push to"; exit 0; }
    if ! m="$(on_swarm_tailnet 2>&1)"; then log "brain collect: $m"; exit 0; fi
    if ! m="$(pair_identity_gate 2>&1)"; then log "brain collect: $m; chats not copied"; exit 0; fi
    dest="$(pair_brain_dir || true)"
    case "$dest" in
      /*) ;;
      *) log "brain collect: cannot ask $t for its brain directory (SWARM_BRAIN_DIR there); chats not copied"; exit 0 ;;
    esac ;;
  *) log "brain collect: role $role; skipped"; exit 0 ;;
esac

export BRAIN_EXCLUDE; BRAIN_EXCLUDE="$(envget BRAIN_EXCLUDE)"
# The swarm's own Claude config (its .env, else ~/.claude), never one exported by the session that
# runs this: a work session's SWARM_CLAUDE_CONFIG must not send its chats.
cc="$( unset SWARM_CLAUDE_CONFIG; claude_config_dir )" && [ -n "$cc" ] || { log "brain collect: no Claude config directory for this swarm; nothing collected"; exit 0; }
python3 "$ROOT/scripts/brain_digest.py" collect-list "$(envget SWARM_MACHINE "$(hostname -s)")" "$LINKS" \
  "$cc/projects" > "$LIST"
n="$(wc -l < "$LIST" | tr -d ' ')"
[ "$n" -gt 0 ] || { log "brain collect: no chats to copy"; date +%s > "$STAMP"; exit 0; }

# --copy-links: the links dir holds one per listed file at its brain path; the file itself is sent.
# A push to the primary stops after 300 s without I/O (and the pair ssh's keepalives end a dead
# session), so a stalled push never freezes the standby.
if [ "$role" = primary ]; then
  mkdir -p "$dest/raw/chats"
  if rsync -aL --files-from="$LIST" "$LINKS/" "$dest/raw/chats/" 2>/dev/null; then
    log "brain collect: collected $n chat files into the brain"
  else log "brain collect: could not copy chats into $dest/raw/chats"; exit 0; fi
else
  if rsync -aL --timeout=300 -e "$(swarm_rsync_rsh)" --files-from="$LIST" "$LINKS/" "$t:$dest/raw/chats/" 2>/dev/null; then
    log "brain collect: copied $n chat files to the primary ($t)"
  else log "brain collect: could not copy chats to the primary ($t)"; exit 0; fi
fi
date +%s > "$STAMP"
