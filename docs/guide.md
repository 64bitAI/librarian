# The brain with any agent

A short guide to the brain, the owner's second-brain wiki, written so that anyone can adopt the
pattern with whatever agent they use. It leans on open formats rather than on any one tool.
Anything marked "not built yet" is a recommendation, not something running today.

## What it is

The brain is a private git repo of plain Markdown, kept by an LLM in the pattern of Karpathy's
"LLM Wiki". The data stays where it already lives; the wiki records what has been learned from it.

- `raw/`: material with no other durable home (chat exports, session files, the owner's notes).
  Raw is never edited. Everything else is listed, not copied.
- `sources.md`: where the rest of the raw data lives (Drive folders, plugin data, datasets) and how
  to read it.
- `wiki/`: pages by type (`people/`, `projects/`, `decisions/`, `topics/`, `datasets/`). Each page
  cites its sources. The wiki is derived and can be rebuilt from raw.
- `index.md`: the catalog, one line per page with a link and a summary.
- `log.md`: append-only history, one heading per operation (`## [YYYY-MM-DD] ingest | subject`).
- `CLAUDE.md`: the schema and rules for whoever reads or writes the repo.

A collector (`scripts/brain-collect.sh`) copies each host's Claude Code, Codex and Gemini chats
into the brain's git-ignored `raw/chats/`: the primary into its own clone before the ingest, the
standby over the pair's ssh at most hourly. The list of files is made on the host that has them
(`brain_digest.py collect-list`), so work sessions (`BRAIN_EXCLUDE`), temp folders, our own Codex
consults and Gemini sessions with no recorded folder never leave it.

A nightly ingest (`scripts/brain-ingest.sh` in this repo, on the swarm's primary) keeps it current
in two stages. Stage A turns new raw chats into masked digests and then into short condensed notes.
Stage B merges the night's notes, the owner's notes from `raw/notes/` first, into `wiki/`, `index.md` and `log.md` in a sandboxed temp copy;
the job checks the result, copies back only those paths, commits and pushes. The README's "The
brain" section has the details.

Read rules: read `index.md` first, then only the pages it points to; answer with citations to page
paths. Write rules: there is one writer, the ingest. Agents and people never edit `wiki/`,
`index.md` or `log.md` directly; to add something they write to their own store or drop a new file
in `raw/notes/` and commit it. The next ingest folds committed notes in, ahead of any chat and even
on a night with no new chats (the ingest's gate opens for a waiting note): they are
not condensed, a note that would carry a secret (the same masker as the wiki check), is work
material by name or title, or is over 20,000 characters (split it) is skipped and logged, and citations name
the note's `raw/notes/` path and commit date, so they can be checked from any clone. An edited and
committed note is merged again; an unchanged one is not. A note that is not committed waits.
The owner may edit a page by hand (commit it as `edit: ...`); the ingest then only appends to that
page.

## The standards it relies on

### Markdown and git as the store

Every file is plain Markdown in git. Any editor, any agent with file access, and any viewer
(Obsidian, a code host, `less`) can read it. Every change is a diffable commit with a subject that
says who made it (`ingest:` for the job, anything else for a person), and the repo is backed up
like any other (the swarm's backup includes a git bundle of it). Nothing about the store depends
on a particular model or vendor.

### AGENTS.md as the portable entry point

`AGENTS.md` (agents.md) is the cross-tool project-instructions file: an agent opened in a
directory reads the nearest `AGENTS.md` as standing instructions. Codex, Cursor, Copilot's coding
agent, Zed, Aider, goose, opencode and others read it directly; Gemini CLI reads it once
`.gemini/settings.json` sets `context.fileName` to `AGENTS.md`; Hermes injects `AGENTS.md` (and
`CLAUDE.md`) into its system prompt. Claude Code reads `CLAUDE.md`.

Recommendation (not built yet): the brain ships an `AGENTS.md` that says the same as its
`CLAUDE.md`, or one file holds the rules and the other is a one-line pointer to it, so every agent
gets the same read and write rules. That is the owner's call: the brain repo is written only by
its ingest and by the owner, never by other agents, so this file cannot be added from here.

### Agent Skills for the "brain" skill

Agent Skills (agentskills.io) is an open format: a folder holding `SKILL.md`, whose YAML
frontmatter has at least `name` and `description`, followed by instructions. Agents load only the
name and description up front and read the rest when a task matches, so a skill costs little
until it is used.

The "brain" skill for Codex and Gemini is built: `infra/agents-skills/brain/SKILL.md.tmpl`, which
`scripts/engines.sh render` writes to `~/.agents/skills/brain/SKILL.md` with the swarm's
`SWARM_BRAIN_DIR` (a hand-written file there is left alone; the managed line in it lets render
replace it). It tells Gemini to add the brain with `--include-directories`, as its file tools
refuse paths outside the workspace. A brain clone on a standby machine is fast-forwarded by
`standby-sync.sh` (clean clones only). The skill says:

- When to consult the brain: questions about the owner's people, projects, decisions, datasets or
  history, before guessing or asking.
- How: read `index.md` first, open only the pages it lists, cite page paths in the answer, and
  check `sources.md` for where underlying data lives.
- How to add something: write one new file in `raw/notes/` (dated, plain words, no secrets or
  health details), commit it alone and push; never touch `wiki/`, `index.md` or `log.md`. When the
  sandbox cannot write to the brain or run git there, give the note text to the owner instead.

Where each tool looks for skills (check your tool's current docs; these move):

- Codex: `.agents/skills/` from the working directory up to the repo root, and `~/.agents/skills/`.
- Gemini CLI: `.gemini/skills/` and the shared alias `.agents/skills/`, per workspace and user.
- Claude Code: `skills/<name>/SKILL.md` inside a plugin, or `.claude/skills/` and
  `~/.claude/skills/`.
- Hermes: its own skills folder, plus extra folders listed under `skills.external_dirs` in its
  `config.yaml`.

One copy of the skill in `~/.agents/skills/brain/` serves Codex and Gemini; Claude Code and
Hermes can be pointed at the same folder by a plugin or a symlink and by `external_dirs`.

### MCP for remote access

An agent on another machine can read the brain through the Model Context Protocol (not built yet
for the brain). Point any MCP filesystem or git server at a clone, read-only. The reference
filesystem server only limits which directories it serves; its write tools are merely marked as
such, so enforce read-only outside it: run it in a container with the clone mounted `ro`, or serve
a clone the server's user cannot write. If remote agents should add notes, give them a second,
writable mount of `raw/notes/` only, or have them send notes through the owner's usual channel
instead.

### An llms.txt-style index

llms.txt (llmstxt.org) is a proposed Markdown file: an H1 title, an optional summary, then lists of
links with one-line descriptions, so an agent can find what to read. `index.md` already plays that
role. Publishing a literal `llms.txt` is optional and only useful if the brain is ever served over
HTTP (not built yet, not needed).

## Keeping the ingest portable

The ingest is shell plus stdlib Python calling a model from the command line. Most of it is
model-neutral: finding new chats, masking secrets (`brain_digest.py`), queueing, the sandboxed temp
copy, the checks on the result (`brain_merge.py`: no stray writes, the log only appended to, hand
edits kept, no added secret), the commit and the monthly spend cap.

What is Claude-specific today:

- Stage A calls `claude -p` with no tools, one turn, the digest on stdin. It already falls back to
  a local model through Ollama's HTTP API (`BRAIN_CONDENSE=local` or `auto` when the month's money
  runs low), so stage A can run with no Claude at all.
- Stage B calls `claude -p` with restricted file tools in the temp copy. Another agent CLI that can
  edit files in a given directory without other tools could do the same job, since the checks
  after it do not care who wrote the files. A local or non-Claude stage B is not built yet; a
  model without reliable file editing would need the merge rewritten as "return the changed
  pages", which the existing checks could still verify.
- Cost tracking reads Claude's reported cost; a local model counts as free.
- The raw sources it digests today are Claude Code session files, claude.ai exports, Codex
  rollouts and Gemini CLI sessions, each with its own reader in `brain_digest.py` writing the same
  digest header, so the exclusion and masking rules apply unchanged. Another agent's transcripts
  would need a reader of their own.

## Privacy and safety rules that travel with it

- One brain per identity. Personal and work knowledge never share a repo; work sessions are
  excluded before a digest is written (`BRAIN_EXCLUDE`).
- No PHI and no secrets in the wiki. Digests are masked before any model sees them; health appears
  only as a pointer to where it is kept, unless the owner opts a topic in.
- Raw chats are git-ignored and leave the machine they were made on only after the filter there:
  work folders and titles (`BRAIN_EXCLUDE`), temp folders and scratchpads, our own headless Codex
  consults and Gemini sessions with no recorded folder are dropped before anything is copied, so
  work material never leaves the work machine. What arrives is kept as it came (nothing is deleted
  at the brain) and goes into the swarm's encrypted backup set as `brain-chats.tgz`, since the
  brain's git bundle never holds it. Digests, condensed notes and job state are git-ignored too.
- The merging model sees only the night's notes and the wiki, never `raw/` (owner notes from
  `raw/notes/` are copied in after their checks, not read in place).
- One writer, and the owner's hand edits win.

## Adopting it

1. Create a private git repo with `raw/notes/`, `wiki/<types>/`, `index.md`, `log.md`,
   `sources.md`, and a schema file (`AGENTS.md`, with `CLAUDE.md` pointing to it if you use Claude
   Code). Copy the shape, not anyone's content.
2. Write the rules into the schema first: identity, no secrets or PHI, one writer, read
   `index.md` first, cite sources.
3. Add a `.gitignore` for raw chats, digests and job state before the first export lands.
4. List your existing stores in `sources.md` rather than copying them.
5. Install a "brain" skill where your agents look for skills, and add the read rule to each
   project's `AGENTS.md`.
6. Run one ingest by hand, read the diff, then schedule it on one machine only, with a spend cap
   or a local model.
7. For other machines, clone it read-only or serve it through a read-only MCP server.
8. Back it up like any other repo.
