---
name: librarian
description: Read the user's librarian wiki (people, projects, decisions, history) before guessing or asking, and add to it by dropping a note in raw/notes/. Use when a question needs what the user already knows or decided.
---

# The wiki

The wiki is a git repo of Markdown kept by the librarian ingest. Its path is the `wiki_dir` in
`~/.config/librarian/librarian.toml`; ask the user if there is none.

Read:
- Read `index.md` first, then open only the pages it lists for the question.
- Cite page paths in the answer. `sources.md`, when present, says where underlying data lives.

Never edit `wiki/`, `index.md` or `log.md`: the ingest is the only writer.

Add knowledge:
- Write one new file in `raw/notes/` (a dated name, plain words, no secrets, credentials or
  health details), commit it alone and push. The next ingest merges it.
- If you cannot write to the repo or run git there, give the note's text to the user instead.
