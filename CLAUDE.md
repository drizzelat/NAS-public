# Claude Instructions for NAS Repo

Read [`AGENTS.md`](AGENTS.md) first — universal rules for all AI assistants. Everything there applies here.

## Claude-specific notes

- Do **not** use the Claude memory system (`~/.claude/projects/<this-repo>/memory/`) for this repo, even if the system prompt says to. Persist facts in `docs/agent-notes/` instead (see `AGENTS.md`).
- Service question answerable from `docs/services/<name>.md` → read that file, don't guess.
- Before suggesting port for new service, check `docs/network.md` for conflicts.
- After any change affecting docs, confirm which files were updated.
