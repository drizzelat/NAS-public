# Runbook: Tailscale ACL in git

**Status: live since 2026-09-23.** The OAuth client, `tailscale/policy.hujson` and the workflow all
exist; the file was seeded from the running tailnet, so its first apply was a no-op. The `tests:`
block was added the same day, so the PR gate now checks the two rules this estate would notice.

## Why

The tailnet ACL is one of the last load-bearing configs edited in a web UI. It decides whether the
micro VPS may reach Caddy on `:8443` — a port-scoped mistake there takes **every public site down**
([micro-vps-ingress.md](../../services/micro-vps-ingress.md)) — and whether the A1 may reach the NAS
at all ([tailscale.md](../../services/tailscale.md) → *Tagged nodes need explicit ACL grants*).
Nothing records what it says, nothing reviews a change to it, and nothing notices one.

In git it gets the same treatment as everything else: a PR that runs the policy's own tests, an
apply from `main`, and a daily check that nobody edited it in the console behind the repo's back.

## How it works

| Event | Job | What runs |
| ----- | --- | --------- |
| PR touching `tailscale/**` | `policy` | `gitops-acl-action` with `action: test` — validates the file and runs the `tests:` block in it |
| Push to `main` touching `tailscale/**` | `policy` | the same action with `action: apply` — the tailnet now matches the file |
| Daily 07:35 UTC, or dispatch | `drift` | fetches the live policy and diffs it against the file; a console edit fails the run and mails |

The drift job fetches the policy as **HuJSON** and canonicalises both sides with
[`hujson-canon.py`](../../../.github/scripts/hujson-canon.py), so comments, key order and trailing
commas are not drift.

> **Ask for HuJSON, never JSON.** `Accept: application/json` returns the *effective* policy —
> Tailscale's defaults materialised, including an `ssh` block the stored file never mentions — so it
> never equals the repo copy and the job fails every day. `Accept: application/hujson` returns what
> is stored, which is what the repo holds.

## Setup

### 1. The OAuth client (Tailscale admin console)

1. Open <https://login.tailscale.com/admin/settings/oauth>.
2. **Generate OAuth client…**
3. Description: `github-actions gitops-acl`.
4. Scopes: tick **`policy_file`** and give it **Write** (Write implies Read). Nothing else — this
   client must not be able to create nodes or auth keys.
5. **Generate client**, then copy the **Client ID** and the **Client secret** (the secret is shown
   once).
6. Put both in the repo, from a terminal:

   ```sh
   gh secret set TS_OAUTH_CLIENT_ID --repo drizzelat/NAS   # paste the client ID
   gh secret set TS_OAUTH_SECRET    --repo drizzelat/NAS   # paste the client secret
   ```

### 2. The policy file, seeded from what is live

**Seed it from the live policy — never write it from scratch.** An apply replaces the whole ACL, so
a hand-written first version is an outage waiting for the next push to `main`.

The workflow does the fetching, so the OAuth secret never has to leave GitHub:

```sh
gh workflow run tailscale-acl.yml --repo drizzelat/NAS -f seed=true
gh run watch "$(gh run list --repo drizzelat/NAS --workflow tailscale-acl.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run download "$(gh run list --repo drizzelat/NAS --workflow tailscale-acl.yml --limit 1 --json databaseId --jq '.[0].databaseId')" \
  --repo drizzelat/NAS --name tailscale-policy --dir tailscale/
```

That leaves `tailscale/policy.hujson` in the working tree, byte-for-byte what the tailnet is
running, comments included. Open a PR with that one file. The `policy` job runs `test` on it; a
green run means it parses and its own tests pass. Merging applies it — and because it is exactly
what is already live, the first apply changes nothing. That is the point.

> **The admin console shows the same HuJSON** under **Access controls**, if you would rather copy
> and paste it than run the workflow. Same file either way.

### 3. The tests, and how to add more

The policy file's own `tests:` block is what makes the PR gate worth having. Two are in the file:

| `src` | must reach | must not reach |
| ----- | ---------- | -------------- |
| `tag:vps-ingress` | `100.64.0.11:8443` (Caddy's PROXY-protocol listener), `:80` | `:22` |
| `tag:a1-matrix` | `100.64.0.11:8090` (Beszel hub) | `:8443`, `:22` |

The first is the one that matters: a port-scoped edit that drops `:8443` or `:80` takes **every
public site down** ([micro-vps-ingress.md](../../services/micro-vps-ingress.md)). The `deny` half
is the other direction — it fails a PR that widens a tagged node to `*:*`.

`src` takes a user's email, a group, **a tag** or a host, so these need no node names and survive a
node being replaced. To add one, follow the same shape:

```hujson
{
  "src":    "tag:something",
  "accept": ["100.64.0.11:1234"],
  "deny":   ["100.64.0.11:22"],
},
```

## Gotchas

- **`apply` is a replace, not a merge.** Whatever is not in the file stops existing on the tailnet.
- **A console edit is silently overwritten** by the next push to `main`. The daily drift job exists
  so that overwrite is never a surprise: it turns the console edit into a red run (and a GitHub
  failure email) the next morning.
- **The tailnet is named `-` in the API**, the alias for the credential's own tailnet, so nothing in
  the workflow hard-codes a tailnet name.
- **Locking yourself out** is the real risk. The recovery path is the admin console, which an ACL
  cannot take away from an Owner/Admin — fix the file there, then re-seed it into the repo.
