# Claude Instructions for NAS Repo

Read [`AGENTS.md`](AGENTS.md) first — universal rules for all AI assistants. Everything there applies here.

## Claude-specific notes

- Use the Claude memory system (`~/.claude/projects/<this-repo>/memory/`, per-machine) to persist NAS facts between sessions.
- Service question answerable from `docs/services/<name>.md` → read that file, don't guess.
- Before suggesting port for new service, check `docs/network.md` for conflicts.
- After any change affecting docs, confirm which files were updated.
