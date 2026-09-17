# Runbook: public mirror

## Why

Friends who run their own setup can read this repo without being given access to it. A
collaborator on a personal-account repo always gets write access, which here means pushing a
branch whose workflow runs on the self-hosted runner, and a fork carries the whole history,
encrypted vault included. So a **separate public repo** gets a sanitized copy instead. It has no
fork relation and no shared history, and every push to `main` refreshes it.

```
push to main ──▶ public-mirror.yml (ubuntu-latest, never self-hosted)
                   │ export.sh: git archive HEAD → exclude → scrub → 3 gates
                   │ push.sh:   one commit on top of the mirror (write deploy key)
                   ▼
                 drizzelat/NAS-public (public, Actions disabled)
```

## What is published

Everything tracked at `HEAD`, minus the `exclude` lines in
[`scripts/public-mirror/rules`](../../../scripts/public-mirror/rules):

- **Left out:** the age vault `secrets.enc/` (ciphertext and the passphrase-wrapped key), the
  architecture review (its open findings are a list of weak spots), and the rules file itself,
  which holds the real values.
- **Rewritten** by the `scrub` lines, in order: the domain becomes `example.com`, public IPs become
  `198.51.100.x`, tailnet IPs become `100.64.0.1x`. The SSH port, SSH public keys, the mail address
  and the storage box user are replaced too. SSH host keys matter because Censys and Shodan index
  them, so a published host key leads straight back to the real IP.
- **Added:** a notice at the top of `README.md` saying what the mirror is.

Untracked files, including the plaintext `secrets/`, can never reach it: the export starts from
`git archive`.

Mirror commits are authored by `github-actions[bot]` with the message
`Sync from private main (<short sha>)`. Private commit subjects are not copied.

## The gates

`export.sh` builds in a temp dir and only creates the output dir once all three pass, so a
failed gate means nothing is pushed:

1. **Leftover patterns.** No `scrub` pattern and no `deny` pattern (case-insensitive) may match
   any file content or path.
2. **Public IPv4.** Every IPv4-looking token must be private, CGNAT, documentation, special-use or
   listed as `allow-ip` (Cloudflare's published ranges, version strings that look like IPs).
3. **gitleaks** `dir` scan of the exported files.

The gates were tested by committing a full name, a second domain spelling, a new public IP and a
GitHub token; each export failed at its gate and left no output.

## When the sync fails

The run goes red, and GitHub's failure email is the alert. Read the `Export and gate` log. It
prints the matching file and line, from the private repo's logs.

| Log says | Fix |
| --- | --- |
| `a scrub or deny pattern still matches` | A new spelling of something already scrubbed. Add a `scrub` line for it |
| `public IPv4 address(es) not covered` | A scrub line for a host of yours, an `allow-ip` line for a published or third-party address |
| `gitleaks flagged the export` | A real secret reached `main`. Rotate it first, then remove it |
| `excluded path '…' is not in the repo any more` | The file was renamed or deleted. Update the `exclude` line |

Commit the rules change to `main`; that push re-runs the sync. To test the rules without pushing,
run the workflow by hand with `dry_run`, or locally with gitleaks on `PATH`:
`scripts/public-mirror/export.sh /tmp/mirror-export`.

**The gates cannot see new names.** A new domain, a person's name or a new VPS hostname passes all
three. When one enters the repo, add its `scrub` line in the same commit.

## Setup (done once)

1. Create the repo as **private**: `gh repo create drizzelat/NAS-public --private`. Disable Actions,
   so the copied workflows never run there:
   `gh api -X PUT repos/drizzelat/NAS-public/actions/permissions -F enabled=false`.
2. Make a key pair in a temp dir: `ssh-keygen -t ed25519 -N '' -C public-mirror -f key`.
3. Add `key.pub` as a deploy key with write access:
   `gh repo deploy-key add key.pub -R drizzelat/NAS-public -w -t public-mirror`.
4. Store the private half in this repo: `gh secret set PUBLIC_MIRROR_DEPLOY_KEY -R drizzelat/NAS < key`,
   then delete both files. The key is not kept in the vault. A lost key is replaced by repeating
   steps 2 to 4.
5. Run the export and push once, review the private mirror on GitHub, then make it public:
   `gh repo edit drizzelat/NAS-public --visibility public --accept-visibility-change-consequences`.

## Undoing a leak

Something published stays published: forks, clones and scrapers copy public repos within minutes.

1. **Rotate** whatever leaked. This is the only step that really helps.
2. Add the scrub rule so the next sync removes it from the tree.
3. Optionally rewrite the mirror's history. Delete the repo and recreate it, then repeat setup
   steps 1 to 5. The old commits stay reachable in any forks that exist.

## Limits

Scrubbing hides the estate from anyone who finds the repo by chance. It does not hide it from
someone who already knows the owner: the GitHub account name, ports, service mix and layout stay
visible, and the docs still describe how the edge is defended.
