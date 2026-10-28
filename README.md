# librarian

Librarian keeps a private git wiki of what you have learned with an AI assistant. Each night it
copies your Claude Code chats into the wiki repo, turns them into masked digests and short notes,
and has Claude merge those notes, together with notes you drop in by hand, into wiki pages. Then it
checks the result, commits it and pushes it. It is also a Claude Code plugin with one small skill,
which tells your sessions how to read the wiki and how to add a note to it.

It is shell plus standard-library Python. It needs `bash`, `git`, `rsync`, `python3` and
the `claude` CLI. A local model through Ollama is optional; stage A can use one when
the month's budget runs low.

## The wiki it expects

Any git repo laid out like this (you write `CLAUDE.md`; the ingest maintains the rest):

```
CLAUDE.md          the schema and rules the merging model follows
index.md           one line per page, by section
log.md             append-only, one "## [YYYY-MM-DD] ingest | n notes" entry per run
wiki/              people/, projects/, decisions/, topics/, datasets/ (pages cite their sources)
raw/notes/         notes you or an agent drop in; committed; merged before any chat
raw/chats/         copied chats (git-ignored)
raw/digests/       masked digests (git-ignored)
raw/notes-condensed/  condensed notes (git-ignored)
raw/.state/        the job's state, with ingest.lock (git-ignored)
state/costs.json   the month's spend (tracked, so the cap follows the wiki)
```

A `.gitignore` with `raw/chats/**`, `!raw/chats/**/`, `raw/digests/**`, `raw/.state/**` and
`raw/notes-condensed/**` keeps chats, digests and state out of git. `docs/guide.md` describes the
pattern and the privacy rules in more depth.

## How a run works

1. Collect: this host's chats are copied into `raw/chats/claude-code/<host>/`. Work folders
   (`exclude`) and temp folders never leave the host.
2. Gate: with no new chat, no digest due and no committed note waiting, the run stops before any
   model starts.
3. Stage A: new chats become masked digests. Each digest becomes a condensed note, written by
   Claude (one turn, no tools) or by the local model.
4. Stage B: tonight's notes are merged by headless Claude. It runs in a temp copy that holds only
   `wiki/`, `index.md`, `log.md`, `CLAUDE.md` and the notes, and its tools can write only to
   `wiki/**`, `index.md` and `log.md`.
5. Checks: the job refuses stray writes, a missing or rewritten log entry, changes to pages you
   edited by hand, and secrets. Then it copies back only those three paths, commits and pushes.

Run it on one machine only: the wiki has one writer. A lock (`raw/.state/ingest.lock`) stops
overlapping runs. Other tools that write into the wiki can take the same lock.

## Config

`librarian.toml` (the path from `--config`, else `LIBRARIAN_CONFIG`, else
`~/.config/librarian/librarian.toml`) holds flat `key = value` lines:

```toml
wiki_dir = "/home/me/wiki"           # the git wiki (required)
collect_from = "/home/me/.claude/projects"   # default ~/.claude/projects
host = "laptop"                      # the name chats are filed under; default the host name
exclude = 'acme|(?<![a-z0-9])acme-'  # a regex: work folders, titles and accounts never collected
budget_usd = 10                      # monthly cap for both stages
condense = "auto"                    # auto | claude | local
condense_model = "sonnet"
ingest_model = "sonnet"
local_model = "qwen2.5:14b-instruct"
local_url = "http://127.0.0.1:11434" # Ollama
lock_wait = 1800                     # seconds to wait for a held ingest lock, then exit 75
alert_cmd = "notify-send librarian"  # gets the alert text on stdin; none: stderr
gate_cmd = ""                        # a script (run with bash WIKI) to use instead of the built-in gate
```

The environment beats the file. The older names still work: `SWARM_BRAIN_DIR` for the wiki and
the `BRAIN_*` and `SWARM_BRAIN_LOCK_*` settings. Any UPPERCASE key in the file is passed through
under its own name (for example `BRAIN_INGEST_CHARS = 70000` or `BRAIN_COST_CAP_2026_10 = 20`).
`lib/ingest.sh` lists every knob. There is no default exclusion: set `exclude` if you use Claude for
work you must keep out.

## CLI

```
librarian [--config FILE] ingest [--dry-run]   collect, gate, digest, condense, merge, commit, push
librarian [--config FILE] collect [--hourly] [--to DIR | --to host:/dir --rsh "ssh ..."]
librarian [--config FILE] status
librarian version
```

`--dry-run` runs every stage, including the model calls, which cost money. It pulls, commits,
pushes and marks nothing, and prints the files the merge would create or change. `collect --to`
sends this host's chats into another machine's wiki, which is how a second machine feeds the one
that ingests.

Exit status: 0 for success, a gated run or a paused (capped) run; 1 for a failed run (the class is
alerted); 2 for a usage or config error; 75 when the ingest lock stayed held.

## Install

The CLI: clone the repo and link `bin/librarian` onto your `PATH`. To run it nightly, render
`units/systemd/` (Linux) or `units/launchd/` (macOS); each file's header says how.

The plugin: in Claude Code, `/plugin marketplace add <path or URL of this repo>`, then
`/plugin install librarian@librarian`. Its skill tells sessions to read `index.md` first, never to
edit the wiki, and to add knowledge as a note in `raw/notes/`.

## Tests

`bash tests/run.sh`. The suites stub `claude`, Ollama and `rsync`, use throwaway repos and a temp
`HOME`, and unset every API key. No model is ever called.

## License

MIT. See `LICENSE`.
