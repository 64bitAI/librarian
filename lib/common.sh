# shellcheck shell=bash
# The few helpers lib/ingest.sh, lib/collect.sh and bin/librarian share. Sourced, never run.
#
# Settings come from the environment first, then the config file (LIBRARIAN_CONFIG, default
# ~/.config/librarian/librarian.toml; lib/config.py maps its keys to the names below), then each
# script's defaults. The wiki is LIBRARIAN_WIKI_DIR, else SWARM_BRAIN_DIR from the environment, else
# wiki_dir from the config.
LIBRARIAN_HOME="${LIBRARIAN_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$LIBRARIAN_HOME/lib"

# load_config: export every setting the config file holds that the environment does not already set.
load_config() {
  local f req="" out line k v
  f="${LIBRARIAN_CONFIG:-}"
  if [ -n "$f" ]; then req=--required; else f="${XDG_CONFIG_HOME:-$HOME/.config}/librarian/librarian.toml"; fi
  # the older name for the wiki still works, and beats the config file like any environment value
  [ -n "${LIBRARIAN_WIKI_DIR:-}" ] || [ -z "${SWARM_BRAIN_DIR:-}" ] || export LIBRARIAN_WIKI_DIR="$SWARM_BRAIN_DIR"
  out="$(python3 "$LIB/config.py" "$f" $req)" || exit 2
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    k="${line%%=*}"; v="${line#*=}"
    [ -n "${!k:-}" ] || export "$k=$v"
  done <<< "$out"
}

# envget KEY [DEFAULT]: the setting (environment, after load_config), else DEFAULT.
envget() { local v="${!1:-}"; printf '%s\n' "${v:-${2:-}}"; }

log() { printf '%s %s\n' "$(date +%FT%T)" "$*"; }

# host_name: the name this host's chats are filed under (raw/chats/<kind>/<host>/) and that alerts
# name: LIBRARIAN_HOST, else SWARM_MACHINE, else the short host name.
host_name() { envget LIBRARIAN_HOST "$(envget SWARM_MACHINE "$(hostname -s)")"; }

# local_url: the Ollama stage A may use: BRAIN_LOCAL_URL, else this machine's.
local_url() { local u; u="$(envget BRAIN_LOCAL_URL http://127.0.0.1:11434)"; printf '%s\n' "${u%/}"; }

# state_dir: where collect keeps its lock and its hourly stamp.
state_dir() { envget LIBRARIAN_STATE_DIR "${XDG_STATE_HOME:-$HOME/.local/state}/librarian"; }

# abs_path NAME VALUE: VALUE with a leading ~ expanded and trailing slashes dropped; a relative path
# is refused (status 1, one line naming NAME).
abs_path() {
  local v="$2"
  # shellcheck disable=SC2088  # a literal ~ is what is matched
  case "$v" in "~") v="$HOME" ;; "~/"*) v="$HOME/${v#\~/}" ;; esac
  [ -n "$v" ] || return 0
  while [ "${#v}" -gt 1 ] && [ "${v%/}" != "$v" ]; do v="${v%/}"; done
  case "$v" in /*) printf '%s\n' "$v" ;; *) echo "$1 must be an absolute path (got '$v')" >&2; return 1 ;; esac
}

# alert TEXT: the alert command (alert_cmd, LIBRARIAN_ALERT_CMD) gets TEXT on stdin; with none set
# TEXT goes to stderr. A failing command is reported on stderr, never fatal.
alert() {
  local cmd; cmd="$(envget LIBRARIAN_ALERT_CMD)"
  if [ -z "$cmd" ]; then echo "alert: $1" >&2; return 0; fi
  printf '%s\n' "$1" | sh -c "$cmd" || echo "alert command failed (exit $?); the alert was: $1" >&2
}

# run_gate WIKI: whether the ingest has anything to do, asked before any model starts. The gate is
# gate_cmd (LIBRARIAN_GATE_CMD, a script run with bash and WIKI) when set and present, else
# lib/gate.sh. Exit 0: run.
# Exit 10: nothing to do; its first line (200 characters at most) is left in GATE_REASON and
# run_gate returns 10. Any other exit means the gate is broken: one warning on stderr and the
# ingest runs anyway (fail open). Call it as `rc=0; run_gate WIKI || rc=$?` under set -e.
run_gate() {
  local g out rc=0; GATE_REASON=""
  g="$(envget LIBRARIAN_GATE_CMD "$LIB/gate.sh")"
  [ -f "$g" ] || { echo "gate $g not found; using the built-in gate" >&2; g="$LIB/gate.sh"; }
  out="$(bash "$g" "$@")" || rc=$?
  case "$rc" in
    0) return 0 ;;
    10) out="${out%%$'\n'*}"; GATE_REASON="$(printf '%s' "$out" | tr -d '\000-\037' | cut -c1-200)"
        GATE_REASON="${GATE_REASON:-nothing to do}"; return 10 ;;
    *) echo "gate $g failed (exit $rc); running anyway" >&2; return 0 ;;
  esac
}
