# Renovate as a GitHub App

**What this replaces.** `RENOVATE_TOKEN` was a **classic PAT** with the `repo` and
`workflow` scopes. Classic PAT scopes are *account-wide*: that one secret reached every
repository the account can see, and `workflow` let whoever held it rewrite
`.github/workflows/*` — the push path itself. It was the only credential in the estate that
reached beyond this repo
([SEC-1](../../architecture-review-2026-08-20.md#sec-1--github-account-compromise-equals-nas-root)).

**Why an App and not a fine-grained PAT.** Renovate needs to read **check runs** before it
automerges, and `Checks` is not among the permissions a fine-grained PAT can hold. A GitHub
App can hold `Checks: read` **and** be installed on a single repository. That is the whole
reason this swap is possible, and it was already recorded in
[`renovate.yml`](../../../.github/workflows/renovate.yml) before the swap happened.

Two workflows consume it:

| Consumer | Token | Permissions minted |
| --- | --- | --- |
| [`renovate.yml`](../../../.github/workflows/renovate.yml) → `renovatebot/github-action` | App installation token | the installation's full set (below) |
| [`renovate-pr-review.yml`](../../../.github/workflows/renovate-pr-review.yml) → `window-merge` (`MERGE_TOKEN`) | App installation token, **narrowed** | `contents: write`, `pull-requests: write` only |

The sweep's token is narrowed per job with `permission-*` inputs, so the credential that does
the unattended merging **cannot write workflow files** even though the App may.

---

## 1. Create the App

Everything here is done as `drizzelat`, in the browser. It cannot be scripted — App creation
has no API for a user-owned App.

1. <https://github.com/settings/apps/new> (avatar → **Settings** → **Developer settings** at
   the very bottom of the left sidebar → **GitHub Apps** → **New GitHub App**).
2. **GitHub App name**: `nas-renovate`. Globally unique across GitHub — if it is taken, use
   `nas-renovate-drizzelat`. This name becomes the bot login `nas-renovate[bot]`, which is the
   PR author and the merge author from here on.
3. **Homepage URL**: `https://github.com/drizzelat/NAS`. Required field, never used.
4. **Webhook** → untick **Active**, and clear the Webhook URL field. Renovate polls; nothing
   calls in. Leaving it active creates deliveries that fail forever.
5. **Repository permissions** — set exactly these, leave every other row on **No access**:

   | Permission | Access | Needed for |
   | --- | --- | --- |
   | Metadata | Read-only | mandatory, GitHub sets it automatically |
   | Contents | Read and write | create `renovate/*` branches, commit pin bumps, `--delete-branch` after a merge |
   | Pull requests | Read and write | open, update and merge PRs |
   | Workflows | Read and write | `helpers:pinGitHubActionDigests` edits `.github/workflows/*`; without it **any** push touching those paths is refused |
   | Checks | Read-only | **the reason this is an App** — read the `validate` / `docs-drift` check runs before automerging |
   | Commit statuses | Read-only | `renovate-review` is a *commit status*, a different resource from a check run; both are read |
   | Issues | Read and write | the Dependency Dashboard issue (`config:recommended` turns it on) |
   | Dependabot alerts | Read-only | `vulnerabilityAlerts` / `osvVulnerabilityAlerts` in [`renovate.json`](../../../renovate.json) |

6. **Organization permissions** and **Account permissions**: nothing. Leave all on **No access**.
7. **Where can this GitHub App be installed?** → **Only on this account**.
8. **Create GitHub App**.

## 2. Client ID and private key

You land on the App's **General** page.

9. Copy the **Client ID** — it looks like `Iv23liAbCdEf...`. That is the value for
   `RENOVATE_APP_CLIENT_ID`. The numeric **App ID** just above it is the legacy input;
   `actions/create-github-app-token` v3 deprecates `app-id` in favour of `client-id`, so use
   the Client ID and ignore the App ID.
10. Scroll to **Private keys** → **Generate a private key**. A `.pem` downloads immediately.
    **GitHub keeps no copy** — lose it and you generate a new one.

## 3. Install it on this repo only

11. Left sidebar of the App page → **Install App** → the row for `drizzelat` → **Install**.
12. **Only select repositories** → pick `drizzelat/NAS` → **Install**.

This is the step that makes the token repo-scoped. "All repositories" would recreate exactly
the account-wide reach being removed.

## 4. Store the secrets

```sh
gh secret set RENOVATE_APP_CLIENT_ID --repo drizzelat/NAS --body 'Iv23li…'
gh secret set RENOVATE_APP_PRIVATE_KEY --repo drizzelat/NAS < ~/Downloads/nas-renovate.*.private-key.pem
gh secret list --repo drizzelat/NAS | grep RENOVATE
```

The `.pem` must go in whole, `-----BEGIN RSA PRIVATE KEY-----` line and all — hence the
redirect rather than `--body`. Put a copy in Bitwarden, then delete the download; it is a
credential that can mint tokens for this repo until the key is revoked.

## 5. Cut over

Order matters: the workflow expects the secrets, so set them **before** the next hourly run
or `renovate` goes red every hour.

1. Merge the workflow change.
2. Set both secrets (step 4).
3. Force a run and watch it:

   ```sh
   gh workflow run renovate.yml --repo drizzelat/NAS
   gh run list --workflow=renovate.yml --repo drizzelat/NAS --limit 1
   ```

4. **Read the log, not the tick.** `renovatebot/github-action` exits 0 even when Renovate
   aborted, so a broken token still paints the job green. The only verdict that counts is the
   `Repository finished` line:

   ```
   INFO: Repository finished (repository=drizzelat/NAS)
         "result": "done"
   ```

   `"result": "external-host-error"` means Renovate authenticated but was refused something —
   see the failure table below. (`isGHApp` / `renovateUsername` are logged at *debug* level and
   are invisible at this workflow's `LOG_LEVEL: info`; don't look for them.)
5. Confirm nothing was duplicated:

   ```sh
   gh pr list --repo drizzelat/NAS --state open --json number,headRefName,author
   ```

   One PR per `renovate/*` branch. `RENOVATE_IGNORE_PR_AUTHOR: "true"` in
   [`renovate.yml`](../../../.github/workflows/renovate.yml) is what makes Renovate adopt the PRs
   the old PAT opened instead of opening a second one beside each. It is a global-only option:
   putting it in `renovate.json` earns a config warning on the Dependency Dashboard and is
   ignored — see the note in that file.
6. Exercise the merge path **without merging**:

   ```sh
   gh workflow run renovate-pr-review.yml --repo drizzelat/NAS -f ignore_window=true -f dry_run=true
   ```

   A line per cleared PR — `#<n>: WOULD MERGE (dry run).` — proves the mint step, the token
   and the whole read path work. Nothing is merged. Run this after **any** change to the
   sweep or to the App's permissions.
7. Only once 3–6 are green, revoke the old credential:

   ```sh
   gh secret delete RENOVATE_TOKEN --repo drizzelat/NAS
   ```

   Then delete the PAT itself at **Settings → Developer settings → Personal access tokens →
   Tokens (classic)** → the Renovate token → **Delete**. Removing the repo secret alone
   leaves a live account-wide token in the account, which is the finding.

**Rollback.** Re-create `RENOVATE_TOKEN` and revert the commit that changed the two
workflows. Nothing else in the estate holds Renovate state.

---

## Reading check status

Whatever else changes here, the sweep must keep reading check state through the **REST**
endpoints — `/pulls/{n}`, `/commits/{sha}/status`, `/commits/{sha}/check-runs` — and never
`gh pr view --json statusCheckRollup`. That wrapper goes through GraphQL and needs scope this
token deliberately does not have; it fails in a way that reads like "no checks found" rather
than "denied". The reasoning is in
[renovate-pr-review.md](renovate-pr-review.md#why-the-sweep-reads-rest-and-not-gh-pr-view). Never send a `gh` call's
stderr to `/dev/null` either — a silenced 403 there is a merge that quietly stops happening.

## Common failures

| Symptom | Cause |
| --- | --- |
| `Error: Input required and not supplied: private-key` | The secret is unset, or was set on the wrong repo. |
| Renovate: `Init: Authentication failure` | The private key does not belong to that Client ID, or the App is not installed on `drizzelat/NAS`. |
| Renovate logs `Error: integration-unauthorized` and `"result": "external-host-error"`, **job still green** | HTTP 403 `Resource not accessible by integration` — the token is valid but the installation lacks a permission. The stack trace names the caller: `getPrList`/`closedPrExists` = **Pull requests**, `getVulnerabilityAlerts` = **Dependabot alerts**, `getIssueList` = **Issues**. Fix the permission, then approve it (below). |
| `create-github-app-token` fails with `permissions ... not granted` | Only `window-merge` can hit this: it asks for `contents`+`pull-requests` write, and GitHub 422s a permission the installation does not hold. The step is `continue-on-error`, so the job stays green and the sweep merges nothing — check that step's log. |
| `refusing to allow a GitHub App to create or update workflow ... without `workflows` permission` | The **Workflows** permission is missing. Add it, then approve it (below). |
| Renovate opens a duplicate of every open PR | `RENOVATE_IGNORE_PR_AUTHOR` was dropped from `renovate.yml`'s `env:`. Setting it in `renovate.json` does not work — it is global-only and Renovate ignores it there. |
| PRs sit with automerge never firing, log says the branch status is pending | **Checks** or **Commit statuses** read is missing — `renovate-review` is a status, `validate` is a check run, and Renovate needs both. |
| Sweep logs `no merge token`, job still green | The mint step failed; it is `continue-on-error` on purpose, so look at that step's own log. Nothing merged, and `stale-clearance` will alarm within a day. |
| Everything 401s roughly an hour into a sweep | Installation tokens live 1 h. `window-merge` has `timeout-minutes: 45` to stay inside that; do not raise it past ~55. |

**Changing permissions after installing.** GitHub does not apply a permission change to an
existing installation until it is accepted: **Settings → Applications → Installed GitHub Apps
→ `nas-renovate` → Configure** shows a *Review request* banner. Until you approve it the
tokens keep the old permission set, which looks exactly like the change not having been saved.
