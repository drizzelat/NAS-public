# Runbook: NAS repo auto-pull (cron scripts run from a live clone)

## Why

The TrueNAS cron jobs (config-email, pg-dump, cloudsync-chain) used to run from
**hand-copied** files under `/mnt/apps/scripts/`. Editing a script in this repo did
nothing on the host until someone `scp`'d the new file over — so fixes silently
never arrived.

Now the host keeps a **clone of this repo** at `/mnt/apps/scripts/nas`, a cron job
fast-forwards it to `origin/main` every 15 min, and each backup cron runs the script
**straight out of the clone**. A push to `main` ("release") is the only step needed —
the next cron run executes the released version.

```
push to main ──▶ GitHub ──(deploy key, read-only)──▶ git-pull-nas.sh (cron, */15)
                                                          │ git reset --hard origin/main
                                                          ▼
                            /mnt/apps/scripts/nas/scripts/*.sh  ◀── backup crons run these
```

## Layout on the host

| Path | What | Managed by |
| --- | --- | --- |
| `/mnt/apps/scripts/nas/` | full clone of this repo (`origin/main`) | auto-pull, **do not edit** |
| `/mnt/apps/scripts/nas/scripts/*.sh` | the scripts the backup crons execute | the repo (edit here, push) |
| `/mnt/apps/scripts/git-pull-nas.sh` | the puller itself — **out-of-band on purpose** | edit by hand on host |
| `/root/.ssh/id_ed25519` | read-only deploy key for the clone | host only, never in git |
| `/var/log/nas-repo-pull.log` | puller log (only logs when HEAD moves) | rotating by hand if ever needed |

> The puller lives **outside** the clone deliberately: if a bad commit broke the
> puller, a repo that could overwrite its own updater could not self-recover. The
> repo copy at [`scripts/git-pull-nas.sh`](../../../scripts/git-pull-nas.sh) is reference/history;
> the *running* copy is the sibling file on the host, `/mnt/apps/scripts/git-pull-nas.sh`. To
> change the puller, edit the host file by hand — **merging a change to the repo copy does
> nothing.**

> **The puller no longer reloads Caddy** (since 2026-09-17, CPX-2 #4a). Caddy's config and the
> Authentik blueprints are mounted from Komodo's clone at `/mnt/apps/komodo/repos/nas`. The deploy
> pulls that clone, and the `caddy` Stack's `post_deploy` reloads Caddy
> ([caddy.md](../../services/caddy.md)). Log lines reading `caddy reloaded` before that date came
> from here.
>
> `observability` and `files` moved to Komodo's clone the same day, so **no container mounts this
> clone any more.** It exists for the host cron scripts, and stays for good (§7 #4b).

## Cron jobs (TrueNAS → System → Advanced → Cron Jobs, run as root)

| id | Schedule | Command |
| --- | --- | --- |
| 5 | `7,22,37,52 * * * *` | `/bin/sh /mnt/apps/scripts/git-pull-nas.sh` |
| 3 | `15 2 * * *` | `/bin/sh /mnt/apps/scripts/nas/scripts/truenas-config-email.sh` |
| 2 | `30 2 * * *` | `/bin/sh /mnt/apps/scripts/nas/scripts/pg-dump-backup.sh` |
| 4 | `0 3 * * *` | `/bin/sh /mnt/apps/scripts/nas/scripts/cloudsync-chain.sh` |

These are the original four. Every other script cron — A1 file sync, NVMe SMART tests, image
prune, the healthchecks.io heartbeat and the five `*-trigger.sh` dispatchers —
runs from the clone the same way; the full list is in [scheduled-tasks.md](../../scheduled-tasks.md)
(`midclt call cronjob.query` below prints the live one with ids).

- The pull runs at **:07/:22/:37/:52** — offset from every other script cron's start minute
  except the every-minute heartbeat (a pull mid-launch could swap a script under a running shell).
- Backup crons invoke `/bin/sh <path>` (not the bare path) so they work regardless of
  the file's exec bit — the repo is authored on Windows and the exec bit is carried by
  the git index, but `/bin/sh` makes it moot.

## Auth (read-only deploy key)

The clone pulls over SSH with a repo-scoped **deploy key** (no account access, no write,
no expiry):

- Private key `/root/.ssh/id_ed25519` (no passphrase — cron is non-interactive).
- Public key registered at GitHub → repo **Settings → Deploy keys**, "Allow write access"
  **off**.
- `github.com` host key pinned in `/root/.ssh/known_hosts` (else non-interactive git fails
  host verification).

Rotate: `ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519`, replace the deploy key on
GitHub, `sudo /bin/sh /mnt/apps/scripts/git-pull-nas.sh` to confirm.

## Verify / operate

```sh
# force a pull now and watch it
sudo /bin/sh /mnt/apps/scripts/git-pull-nas.sh; sudo cat /var/log/nas-repo-pull.log

# clone in sync with main?
sudo git -C /mnt/apps/scripts/nas rev-parse --short HEAD
sudo git -C /mnt/apps/scripts/nas rev-parse --short origin/main   # must match

# list the cron jobs
sudo midclt call cronjob.query '[]' '{"select":["id","description","command","schedule","enabled"]}'

# run one backup cron on demand (by id)
sudo midclt call cronjob.run 2 true      # pg-dump
```

## Gotchas

- **Local edits are blown away.** The puller does `git reset --hard origin/main`; never
  edit files inside `/mnt/apps/scripts/nas` on the host — they revert on the next tick.
  Edit in the repo and push.
- **First clone / key change is manual.** A private repo needs the deploy key on GitHub
  before the first clone succeeds.
- **The old loose copies** (`/mnt/apps/scripts/{cloudsync-chain,pg-dump-backup,truenas-config-email,convert_datasets}.sh`)
  are no longer referenced by cron and are dead — **never run them by hand**; they are older than
  the repo versions. The live files beside them are `git-pull-nas.sh`, `nas-health-probe.sh` and
  `nas-health-smart.sh`, installed out of band on purpose. `dockge-backup.sh` is not in the repo —
  leave it.
- **Puller broken?** It's out-of-band, so fix the host file directly, or
  `cd /mnt/apps/scripts/nas && sudo git fetch origin main && sudo git reset --hard origin/main`
  by hand.
