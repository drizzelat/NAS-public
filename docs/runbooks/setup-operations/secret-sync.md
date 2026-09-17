# Runbook: Encrypted secret sync (age, one passphrase)

Share every stack's `.env` across devices by committing an **encrypted** copy to this
repo. One passphrase unlocks everything. No cloud service, no third party.

- **Tool:** [`scripts/secrets.sh`](../../../scripts/secrets.sh) (wraps [age](https://github.com/FiloSottile/age)).
- **Plaintext** lives under gitignored `secrets/` — the per-stack env (`secrets/portainer-env/*.env`)
  **and** the SSH keys (`secrets/ssh/*`: the NAS and both VPS hosts, the CI forced-command keys,
  Synapse's signing key) — **never committed**.
- **Ciphertext** lives in `secrets.enc/` — **committed**.

`lock`/`unlock`/`status` cover both the env and the SSH keys. After `unlock`, the SSH keys land in
`secrets/ssh/`, and the SSH commands in the other docs use them from there, relative to the repo root.

## Why this design (one passphrase, and the key never leaves your workstation)

```
        ┌─ secrets.enc/age-recipient.txt   public key   → locks secrets (no passphrase)
age key ─┤
        └─ private key ── secrets.enc/age-key.age   wrapped with YOUR passphrase (committed)
```

- **You:** type one passphrase → unwrap the private key → decrypt everything.
- **Locking** new secrets needs only the *public* key — no passphrase.

`secrets.enc/age-key.age` is a private key **encrypted with your passphrase**, so it is
safe to commit — security rests entirely on passphrase strength. Use a strong one (a
password-manager entry). Keep the repo private regardless (it already is).

> **The key is not a GitHub secret, and must never become one.** It decrypts the *whole*
> vault — every stack env **and** every host SSH key, including the other hosts. A GitHub
> secret is readable by any job on the self-hosted runner, so anyone who can land a commit
> on `main` would get the estate. `AGE_IDENTITY` was removed from the repo on 2026-08-22
> — [SEC-1 step 2](../../architecture-review-2026-08-20.md#step-3--remove-age_identity-from-ci).
> Everything that used to decrypt in CI now runs from here with `scripts/secrets.sh push`.

## Committed vs. never-committed

| Path | Committed? | What |
| --- | --- | --- |
| `secrets.enc/age-recipient.txt` | ✅ | Public key (not secret) |
| `secrets.enc/age-key.age` | ✅ | Private key, wrapped with your passphrase |
| `secrets.enc/portainer-env/<stack>.env.age` | ✅ | Encrypted per-stack env |
| `secrets.enc/ssh/<name>.age` | ✅ | Encrypted SSH keys (hosts, CI probe keys, Synapse signing key) |
| `secrets/portainer-env/<stack>.env` | ❌ gitignored | Plaintext env (device-local) |
| `secrets/ssh/<name>` | ❌ gitignored | Plaintext SSH keys (device-local) |
| `secrets/age-key.txt` | ❌ gitignored | Unwrapped private key (device-local) |

## First-time setup (do this once, on your main device)

```bash
scripts/secrets.sh init
```

This generates the keypair, prompts for your passphrase (twice), encrypts the existing
`secrets/portainer-env/*.env`, and writes `secrets.enc/`. Then commit the vault:

```bash
git add secrets.enc .gitignore scripts/secrets.sh
git commit -m "feat(secrets): encrypted secret vault (age)"
git push
```

Store the passphrase in your password manager. If you lose it **and** every unwrapped
`secrets/age-key.txt` on all devices, the secrets are unrecoverable — re-key from
whatever plaintext you still have.

## Switching to another device

```bash
git clone <repo> && cd NAS
scripts/secrets.sh unlock      # prompts for the passphrase, once per device
```

`age` auto-bootstraps to `scripts/.bin/` if not installed. Plaintext lands in
`secrets/portainer-env/`. The unwrapped key is cached in `secrets/age-key.txt` so later
`unlock`s on this device don't re-prompt.

## Daily use

Editing the vault and getting the value into Komodo are **two separate acts**. The commit ships the
ciphertext to the repo; `push` writes the Komodo Variables and deploys the stack. Do both, in this
order:

```bash
scripts/secrets.sh edit mealie     # decrypt→$EDITOR→re-encrypt one stack
scripts/secrets.sh push mealie     # Variables → Komodo, then deploy that stack
scripts/secrets.sh status          # show plaintext/ciphertext drift
git add secrets.enc && git commit -m "chore(secrets): update mealie env" && git push
```

Nothing in CI reacts to a `secrets.enc/**` push — committing without `push`ing leaves Komodo on the
old value, silently.

## Pushing env into Komodo (`scripts/secrets.sh push`)

Komodo interpolates a Stack's env from Variables at deploy time and never reads the vault. `push`
closes that gap from your workstation:

```bash
scripts/secrets.sh push mealie paperless   # named stacks
scripts/secrets.sh push --all              # every owned stack in the vault
```

- It reads the **ciphertext**, so what you push is exactly what you commit. If the plaintext is newer
  than the `.age` file it refuses and tells you to `lock` first.
- It writes the stack's Variables exactly as `komodo-vars` does (below), then runs `DeployStack`
  and follows the update record. It does not health-check; dispatch `deploy-stacks` for that.
- **Only stacks in [`komodo/owned-stacks`](../../../komodo/owned-stacks).** `--all` skips the rest,
  which includes `komodo` itself: write its Variables with `komodo-vars komodo`, then press Deploy in
  the UI.
- **A stack with no Komodo Stack yet is refused.** For a new stack, run `komodo-vars` and merge its
  PR; `deploy-stacks` creates it ([deploy-stacks.md](deploy-stacks.md#adding-a-stack)).
- It needs no setup beyond `unlock`: the admin API key comes from `komodo.env` in the vault.

> Until 2026-09-17 `push` also created and redeployed Portainer stacks through
> `PUT /api/stacks/{id}/git/redeploy`, with its git-credential workarounds. That path went with SVC-2
> Phase 3; the history is in git. Before that it was the `sync-secrets` workflow, deleted with
> `AGE_IDENTITY`.

## Komodo Variables (`scripts/secrets.sh komodo-vars`)

Komodo Stacks do not get an env array. Each entry in
[`komodo/resources.toml`](../../../komodo/resources.toml) names **Variables** instead,
`KEY=[[<STACK>__<KEY>]]` (for example `PG_PASS=[[AUTHENTIK__PG_PASS]]`), and Komodo interpolates
them at deploy time. `komodo-vars` writes those Variables from the vault:

```bash
scripts/secrets.sh komodo-vars --dry-run --all   # what would change; prints names, never values
scripts/secrets.sh komodo-vars a1-vps-matrix     # create or update one stack's Variables
```

- It writes **exactly what resources.toml references**. A referenced key missing from the vault
  is an error and nothing is written for that stack. A vault key nothing references is a warning
  and is not written. A `<STACK>__*` Variable nothing references any more is reported and left
  alone; delete it in the UI.
- **Secret by default.** `KOMODO_NON_SECRET` in the script lists the identifiers that stay plain
  (the Authentik image, tag and ports). A secret Variable is masked everywhere in Komodo's deploy
  logs, so a short common value garbles them (komodo-migration.md F18).
- It reads the **ciphertext**, like `push`, and the admin API key from `komodo.env` in the vault.
  Values go into `jq` and `curl` on file descriptors, never argv or stdout.
- **Komodo's update history keeps what you write.** `CreateVariable` logs the whole Variable and
  `UpdateVariableValue` logs the new value, secret or not (F19). Only admins can read those
  records, and admins can read the Variables anyway, but a rotated secret stays in Core's database
  and its daily backup.

### Ordering when a change needs both env and compose

If a compose file starts referencing a *new* env var, get the Variable into Komodo **before** the
compose lands, or `deploy-stacks` deploys with it unset, fails its health gate, and auto-reverts the
commit:

1. `scripts/secrets.sh edit <stack>`, add the `KEY=[[<STACK>__<KEY>]]` line to its `resources.toml`
   entry in the PR, and run `scripts/secrets.sh komodo-vars <stack>` (it reads the entry from your
   checkout).
2. Merge the PR **with `[skip ci]`**, so the push does not deploy before Komodo knows the new
   Variable. Execute the ResourceSync after reading its diff; the Stack's `environment` then names it.
   Dispatch `deploy-stacks` for the stack.

The ordering matters because `deploy-stacks` fires on the compose push and interpolates whatever
Komodo holds at that moment.

## Rotating the passphrase or the key

- **Passphrase only:** unwrap and re-wrap the key —
  `age -d secrets.enc/age-key.age | age -p -o secrets.enc/age-key.age`, commit.
- **Full re-key** (key possibly leaked): `unlock` everywhere you can, delete
  `secrets.enc/`, `rm secrets/age-key.txt`, `scripts/secrets.sh init` again, rotate the
  actual secret **values** too (a leaked key means the old ciphertext is compromised),
  then `scripts/secrets.sh push --all` so Komodo gets the new values. There is no CI
  copy of the key to update — that is the point of
  [SEC-1 step 2](../../architecture-review-2026-08-20.md#step-3--remove-age_identity-from-ci).
```
