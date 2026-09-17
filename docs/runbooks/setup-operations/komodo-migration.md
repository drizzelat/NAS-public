# Plan: Portainer EE → Komodo (SVC-2 / Part 8 step 7)

**Status: DONE 2026-09-17.** Approved in principle 2026-09-08. Phase 0 done 2026-09-14. Phases 1 and 2
done 2026-09-15: Komodo owns all 29 stacks (six on the A1, two on the micro VPS, 21 on the NAS);
Portainer deploys none. `qdirstat` was removed instead of adopted (F24). **Phase 3 started and finished
on 2026-09-17**, ahead of its two-week soak, by decision: Portainer is gone, and the GitHub runner runs
in a VM on the NAS.
The decisions in §13 are settled. **Decision 6 was reversed on 2026-09-17: Portainer is removed
completely** rather than kept as a read-only console (§10, §13).

- **Phase 3 (§8):** done 2026-09-17, in [#428](https://github.com/drizzelat/NAS/pull/428) to [#447](https://github.com/drizzelat/NAS/pull/447) and the close-out. Reading
  for it produced **F26** to **F30**; building it, **F31** to **F35**. What it got wrong is at the end
  of §8 Phase 3.

- **Start gates (§0):** items 0–5 are closed. Item 6 closes 2026-09-18 08:32Z. **Phase 1 started
  before it closed, by decision (2026-09-15)**, keeping the §1 probe green at every step so the
  soak it measures was never interrupted.
- **§5's measurements:** all eight are done, both halves of item 4 included. They produced **F13**,
  **F14**, **F15** and **F16**. Phase 1 added **F17**.
- **Komodo v2.3.3 runs on the estate:** Core + Mongo on the NAS, a periphery on each of four hosts
  (the runner VM since 2026-09-17), all four Servers `Ok`, and every Stack declared through the
  ResourceSync `komodo-resources`. 30 Stacks: the 28 in [`komodo/owned-stacks`](../../../komodo/owned-stacks),
  which CI deploys; `github-runner`, which the Procedure `deploy-runner` deploys; and `komodo` itself.
  §8 Phase 2 lists each adoption.
- **Changes to the estate** under this plan: the revocation of nine dead NPMplus bouncer keys (F14),
  and the additions from Phases 1 and 2 (§8). Phase 2 findings: **F19** to **F25**.

Finding: [SVC-2](../../architecture-review-2026-08-20.md#svc-2--portainer-ee--komodo). Also closes
[CPX-2](../../architecture-review-2026-08-20.md#cpx-2--four-deployment-mechanisms) partially (§7 says
exactly which parts), most of [CPX-1](../../architecture-review-2026-08-20.md#cpx-1--1500-lines-of-bash-inside-yaml)'s
remaining half, and [SEC-1](../../architecture-review-2026-08-20.md#sec-1--github-account-compromise-equals-nas-root)
step 4.

Structured after [caddy-migration.md](caddy-migration.md), which earned its shape the hard way: a
findings section recording where the written plan was wrong, an inventory enumerated from the live
system rather than the docs, a parallel-run phase whose config is byte-identical to the cutover, and
an acceptance test that had to pass unchanged. That plan was still wrong in fourteen places and
needed three further commits after it was declared done. **Budget for the same here.** This one has
a worse starting position: the acceptance test does not exist yet (§1), and nothing in §5 has been
measured (§5 is a to-do list, not a results table — that is the honest difference between this
document and the Caddy one at the same stage).

---

## 0. Do not start yet — and the evidence, not the calendar, says when

SVC-1 completed on 2026-09-07. Its final commit, [#283](https://github.com/drizzelat/NAS/pull/283),
merged at 11:09Z and the host picked it up at 11:11Z. Part 8 says steps 6 and 7 "should not start on
the same weekend as the other".

The planned two-week soak was skipped, so the edge has far less evidence behind it than "done"
suggests. Measured, not assumed:

This table was written at 2026-09-08 10:17Z, when three of the four rows were empty. Three of them
closed the same day; it is kept as written, with the closure beside it, because the *reason* the gate
exists is the first column, not the second.

| Evidence the soak was supposed to buy | At 2026-09-08 10:17Z | Now |
| --- | --- | --- |
| ~56 scheduled probe runs | **3.** `edge-access-policy` had run green on schedule three times since the cutover (09-07 12:34Z, 09-07 21:31Z, 09-08 04:37Z). Not 4/day — the cron was `17 */6 * * *` and GitHub drops and delays it | **Closed** — fixed at the trigger (gate 0), then 20 consecutive green cron-driven runs by 2026-09-12 10:17Z (gate 1) |
| A Renovate cycle | 0 since cutover | **Closed** — [#288](https://github.com/drizzelat/NAS/pull/288) merged and deployed 09:36Z |
| A reboot | **0.** `uptime` on the NAS read **57 days**. Caddy had never come up from cold, and neither had `docker-boot-guard` with a Caddy-owning edge | **Closed** — rebooted 09:25Z, came back clean, and immediately earned its keep: it produced **F14** |
| CrowdSec parsing steadily | ~1 day of evidence | **Closed** — a full week on one container from the reboot, 292.64k/292.64k lines parsed on 2026-09-15 (gate 5) |

And one thing the soak was not supposed to buy, which is worse:

> **The `caddy reload` hook has still never executed.** `grep -c 'caddy reload'
> /var/log/nas-repo-pull.log` on the NAS returns **0**, re-checked 2026-09-08. The host copy of
> `git-pull-nas.sh` was installed at 13:11:22 local on 09-07, *after* the 13:11:16 pull that brought
> in #283 — so the pull that delivered the hook ran the old script, and no Caddyfile has changed
> since. The mechanism this plan must preserve or replace has zero executions behind it.

The good news, verified by hand as instructed: the running host copy **does** match the repo.
`sha256sum /mnt/apps/scripts/git-pull-nas.sh /mnt/apps/scripts/nas/scripts/git-pull-nas.sh` returns
the same digest, `7a80a6bd…`. So the reload path is installed correctly — it has simply never been
exercised. That is a discipline (someone copied the file by hand), not a mechanism: **nothing in the
estate deploys `/mnt/apps/scripts/git-pull-nas.sh`, and nothing checks that it matches the repo.**
See F11.

### Start gate

**Gate item 0 is a fix, not a wait.** The original gate said "40 consecutive green *scheduled* probe
runs" and that is unmeetable: GitHub has been running `schedule` events 2.5–5.5 h late and mostly
dropping them since 2026-08-27, which is why
[#284](https://github.com/drizzelat/NAS/pull/284) already moved the nightly health check onto a host
cron firing `workflow_dispatch`. `edge-access-policy` is still on `schedule` and is therefore
**unreliable independently of this migration** — three runs where twelve were due.

0. ~~**Move `edge-access-policy.yml` to host-cron dispatch**, the same shape #284 used.~~
   **Done 2026-09-08, [#293](https://github.com/drizzelat/NAS/pull/293).**
   [`scripts/edge-probe-trigger.sh`](../../../scripts/edge-probe-trigger.sh) fires at `:17` every
   6 h on TrueNAS cron id 16; the GitHub `schedule:` dropped to `17 8 * * *` as a guarded fallback.
   Chain verified end to end — `midclt call -j cronjob.run 16` produced a green run, rather than
   waiting for a slot. Item 1's count starts from here.

Then do not begin Phase 1 until **all** of these hold:

1. ~~≥ 20 consecutive green `edge-access-policy` runs on the restored cadence (~5 days from
   2026-09-08).~~ **Done 2026-09-12 10:17Z**, the 20th green run counted from the first cron-driven
   one (09-08 10:17Z). The two hand dispatches earlier on 09-08 are not counted. By 2026-09-14
   16:17Z the streak was 32 runs, every one green, with no failure anywhere in between.
2. ~~≥ 1 full NAS reboot with Caddy, CrowdSec and all 17 `proxy_*` networks back clean.~~
   **Done 2026-09-08 09:25Z.** 41 containers up, 0 exited, 17 `proxy_*` networks present, no
   `docker-boot-guard` heal needed. One regression found that the skipped soak would have caught —
   see F14.
3. ~~≥ 1 Renovate cycle merged and deployed through `deploy-stacks` end to end.~~
   **Done 2026-09-08 09:36Z, [#288](https://github.com/drizzelat/NAS/pull/288).** Caddy image digest
   bump, `deploy-stacks` green, container restarted 09:37:34Z on `sha256:4fd00f38…`. The bump itself
   was churn: the Dockerfile pins both base images by digest and both plugins by version, so the new
   digest is Go build nondeterminism, not a plugin change. `xcaddy` is not reproducible; expect this
   PR to reappear on every rebuild.
4. ~~≥ 1 **real** Caddyfile change merged, and `/var/log/nas-repo-pull.log` showing `caddy reloaded`.~~
   **Done 2026-09-08 11:20:21 local, [#295](https://github.com/drizzelat/NAS/pull/295)** — a real
   change (client `Host` to the TrueNAS UI), so the no-op was not needed. `grep -c 'caddy reload'`
   went 0 → 1. The hook works; it had simply never been exercised.
5. ~~`cscli metrics show acquisition` still non-zero after a week on the Caddy log.~~
   **Done 2026-09-15 09:26:58Z**, a full week on one uninterrupted container: `crowdsec` had been up
   since the reboot (`StartedAt` 2026-09-08T09:25:38Z, `RestartCount` 0).
   `file:/var/log/caddy/access.log` read **292.64k lines, 292.64k parsed**, 0 unparsed. On 09-14
   ~18:00Z it was 263.81k/263.81k.
6. [`deploy-state-probe.yml`](../../../.github/workflows/deploy-state-probe.yml) green for **7 days**,
   counted from its first green dispatched run on `main`. §1's soak, decided 2026-09-11 to stay a
   full week rather than shrink to meet gates 1 and 5. **Open.**

**Phase 0 (§8) is exempt.** It touches no estate component and can start immediately: it is a Komodo
evaluation on a scratch host, which is exactly what the Caddy plan did before writing its Phase 0
(a Caddy 2.11.4 with stub upstreams on the A1, §5 of that plan). Gate item 0 and Phase 0 can run in
parallel — they share no component.

---

## 1. The acceptance test does not exist, and that is the first work item

**Status: built 2026-09-11** as [`deploy-state-probe.yml`](../../../.github/workflows/deploy-state-probe.yml)
([runbook](deploy-state-probe.md)). It departs from the deliverable below in one respect, on
purpose: between this section being written and the probe being built, the nightly health check
gained [`nas-health-image-drift.sh`](../../../.github/scripts/nas-health-image-drift.sh), which already
implements the digest row, orphan detection (F15) and unexplained compose projects (F13). The probe
**calls that script** instead of duplicating it, and adds what the health check lacks — placement,
health, `qdirstat`, caddy's networks, host copies — behind an exit code, because an adoption gate
cannot be a nightly model verdict. Not yet asserted: F12's `/home/ubuntu/agent/docker-compose.yml`
copies on the two VPSes (the probe has no SSH path there), and F15's Komodo-specific checks (Mongo
auth, periphery `core_public_keys` and `allowed_ips`), which have nothing to assert until Komodo is
on the estate.

SVC-1's single most valuable structural property was that
[`edge-access-policy.yml`](../../../.github/workflows/edge-access-policy.yml) existed, was green
against the **old** system, and had to stay green through the swap. Part 8 ordered step 1 before
step 6 for precisely this reason.

**SVC-2 has no equivalent.** There is nothing that asserts "every stack is deployed, on the right
host, running the digests this repo pins". Without it, a control-plane migration fails the same way
GAP-1 described: silently, and it stays failed.

The assertions already exist as *code*, just not as a *test*, scattered across the deploy path:

| Assertion | Lives today in |
| --- | --- |
| every `stacks/*/` folder is a stack in the control plane | `fire-webhooks.sh`, Pass 2's `exists` branch |
| on the expected host | `fire-webhooks.sh` `target_endpoint()` — a name-prefix `case` |
| running containers' `.Config.Image` digests ⊆ the repo's pins | `fire-webhooks.sh` reconcile pass **and** `verify-healthy.sh` `stale_containers()` |
| every container running or cleanly `Exited (0)`, none `unhealthy` | `verify-healthy.sh` `check_stack()` |

### Deliverable: `deploy-state-probe.yml`

A read-only workflow that asserts the four rows above for all 24 Portainer stacks (27 `stacks/`
folders, minus `portainer` and the two `*-vps-agent` stacks — F12) plus these, which are the things
that have actually gone wrong:

- **`qdirstat` has no running container.** It is `profiles: [manual]` + `restart: "no"` — a
  compose profile Portainer has no UI for. A replacement that resurrects it is a regression, and
  nothing would currently notice. See F8.
- **All 17 `proxy_*` networks exist and `caddy` holds an endpoint on each.** SVC-1 F2/#10 —
  compose only creates a network something attaches to, and a `down` that removes them is
  unrecoverable without a from-scratch bring-up.
- **The host copy of `git-pull-nas.sh` matches the repo** (F11).

Trigger it the way §0 gate item 0 fixes `edge-access-policy`: **host cron → `workflow_dispatch`**,
not `schedule`. A drift detector on a trigger GitHub drops is not a drift detector.

Build it against **Portainer**, prove it green, merge it alone, and leave it green for a week
**before Komodo exists** — the F1 discipline from SVC-1, which was right: amending or writing the
test while the old system is still the thing under test is what keeps it honest. Then the only
change it takes during the migration is its backend adapter (Portainer API → Komodo API), and a
per-stack `source:` field so it can assert a mixed estate mid-migration.

This is not optional scaffolding. It is the gate for every cutover step in §9, and it is the half of
the finding that git alone does not deliver.

---

## 2. Findings

From reading the live estate and Komodo's own source and compose templates. These change the plan;
they are not chores.

### F1 — Komodo is GPL-3.0, not MIT

The finding text says MIT. `gh api repos/moghtech/komodo --jq .license.spdx_id` returns
**`GPL-3.0`**, and the repository `LICENSE` is the GPLv3 text. Nothing about this blocks the
migration — self-hosting is not distribution, and the copyleft never triggers — but a licence claim
about a control plane should be right, and SVC-2's should be corrected in the same PR that lands
this plan.

### F2 — Komodo is at v2.3.3, and v2 is a breaking rewrite of the agent transport

Latest release `v2.3.3`, 2026-09-01 — six days ago. The v2 line changed:

- **`:latest` is deprecated; images ship as `:2`.** The estate already learned this failure mode:
  `portainer-ee` on `latest@sha256:` froze the control plane on one build and blinded Renovate
  ([portainer.md](../../services/portainer.md) → Notes). Pin `2.3.3@sha256:…` — a patch-level tag on
  a major-line stream, so Renovate keeps seeing the line.
- **PKI (noise handshake) replaces passkeys** for Core↔Periphery auth, with automatic rotation.
- **Outbound periphery** is new (F6).
- Docker Swarm support, pagination, a new UI.

Practical consequence: **most third-party Komodo material describes v1 and does not describe what
you would install.** Trust the repository's `compose/` templates and `config/*.toml`, which are the
canonical documentation, over blog posts.

Treat Komodo Core exactly as `portainer-ee` is treated today: `needs-manual-review` +
`control-plane` labels, on `MERGE_SKIP` in `renovate-pr-review.yml`, merged by hand after reading
release notes.

### F3 — Komodo Core needs a database the estate does not have

There is no SQLite option. The repository ships `mongo.compose.yaml` and `ferretdb.compose.yaml`
and nothing else; the docs call MongoDB "the recommended database" and FerretDB (Postgres +
DocumentDB) the alternative for hosts that cannot run current MongoDB.

The finding did not name this cost. The control plane goes from *one container plus a bind mount* to
**Core + a database + a periphery agent**, and the database is new stateful data that has to be
backed up. Concretely:

- **Decided 2026-09-08: MongoDB.** Komodo Core has a built-in dated database backup that writes to `/backups`;
  that is the documented and supported path. FerretDB's own compose file carries
  "🚨 Pin to a specific version. Updates can be breaking." **twice**, on two images, which is two
  more control-plane upgrade decisions per year for no gain here.
- `/mnt/apps/komodo/backups` must join the Cloud Sync chain
  ([backup.md](../backup-restore/backup.md)) and get a `docs/storage.md` row. It is **not**
  `pg-dump-backup.sh`'s problem with Mongo, and would be with FerretDB — one more reason for Mongo.
- New dataset `apps/komodo`. `apps` has 156 GiB free, so space is not a constraint.

### F4 — Periphery's default root directory is `/etc/komodo`, which a TrueNAS update deletes

Komodo's periphery config defaults `root_directory = "/etc/komodo"`, and its compose template warns
the mount "must be the same inside and outside the container, or docker will get confused".

SEC-1 step 4 already found what that means on this host: `/` and `/usr` are **read-only mounts
inside the boot environment `boot-pool/ROOT/<version>`**, and a TrueNAS update boots a *new* boot
environment — so `/usr/local/bin`, `/etc/sudoers.d` and `/home` all evaporate. That is why
`nashealth`'s scripts live on the `apps` pool and its home is `/mnt/apps/nas-health`.

So on the NAS the periphery root **must** be relocated:

```
PERIPHERY_ROOT_DIRECTORY=/mnt/apps/komodo
volumes:
  - /mnt/apps/komodo:/mnt/apps/komodo    # identical path inside and out
```

Get this wrong and the estate works perfectly until the next TrueNAS update, which silently orphans
every stack's working directory and every cloned repo. On the two Ubuntu VPSes `/etc/komodo` is
fine — but use `/etc/komodo` there and `/mnt/apps/komodo` on the NAS deliberately, and write it
down, rather than discovering the asymmetry later.

### F5 — repo-mode Stacks clone the whole repo *per stack* unless Repo Linking is used

Komodo clones the entire repository into `<root>/stacks/<stack_name>/<repo>` per Stack;
`run_directory` only says where `docker compose` runs, it does not narrow the clone. With 19 NAS
stacks that is 19 clones of this monorepo.

**Repo Linking (v1.18.3+) fixes it**: Stacks sharing one `Repo` resource share one clone per host.
The shape is therefore:

- one `Repo` resource — `drizzelat/NAS`, `refs/heads/main`, one `git_account` holding the token;
- every Stack sets `linked_repo` to it, `run_directory: stacks/<name>`,
  `file_paths: ["docker-compose.yml"]`.

Size is not the issue — the repo is small — **shared state is**. One clone per host is also what
makes §7's mechanism-4 collapse possible, and what makes the on-host break-glass in §10 real.

### F6 — outbound periphery reverses the tailnet direction and needs new ACL grants; inbound does not

Today Portainer sits on the NAS (a **user-owned, untagged** tailnet node) and dials the two VPSes
(**tagged** nodes) on `:9001`. Tailscale allows user→tagged by default, which is why that works with
no explicit rule.

Komodo v2's outbound mode reverses this: periphery dials Core. That is tagged→user, which
[tailscale.md](../../services/tailscale.md) documents as **denied by default** and needing an
explicit grant — and SVC-1's phase-1 record proved the current ACL is narrow: from the ingress VPS,
`80`/`443`/`8443` reach the NAS and `81`, `31015`, `10443`, `18443` all time out.

So:

- **Decided 2026-09-08: inbound periphery at cutover** (Core → `periphery:8120`, the default when
  `core_address` is unset). Same direction as today, one fewer variable in the cutover. Verify the
  existing grant is not port-`9001`-specific before assuming `8120` is reachable — measure it, do
  not infer it (§5 item 5).
- **Move to outbound later, as its own change.** It is genuinely better: no listening port on a
  public VPS at all. It needs two admin-console grants (`tag:vps` and `tag:a1-matrix` →
  `100.64.0.11:9120`), which is click-ops of the same class the estate already accepts for the
  Beszel hub on `:8090`.

### F7 — `destroy_before_deploy` must be **off** for `caddy`, or it takes the 17 networks down

Komodo runs real `docker compose` on the host, so everything SVC-1 established still holds:
`stacks/caddy` **defines** 17 `proxy_*` networks that 16 other stacks consume as `external: true`;
compose adopts an existing network carrying another project's labels with a cosmetic warning and no
recreate; and a `compose down` cannot remove a network that still holds endpoints.

But Komodo's Stack exposes `destroy_before_deploy` (`docker compose down` first), which Portainer's
webhook path never did. Turned on for `caddy` it would attempt exactly the `down` SVC-1 finding #6
identified as the thing that would have taken the network definitions with it. **Off for every
stack; explicitly documented as off for `caddy`.** Same class of problem the finding text predicted,
in a new place.

The 17 networks will keep `com.docker.compose.project=npm` labels forever (SVC-1 #11), so Komodo
will emit the same cosmetic warning on every `caddy` deploy that Portainer does.

### F8 — the qdirstat profile survives; its status check does not

`stacks/qdirstat/docker-compose.yml` is `profiles: [manual]` + `restart: "no"`. `docker compose up
-d` without `--profile manual` does not start it, so Komodo does **not** resurrect it — provided
nothing sets `COMPOSE_PROFILES` in Komodo's generated `.env` and `extra_args` carries no `--profile`.
Both are Stack fields; both must be left empty and asserted in review.

But Komodo judges Stack health against the compose service list, so `qdirstat` reads as a
permanently missing service. That is what `ignore_services` is for. Set it, and assert the
"no qdirstat container" case in the §1 probe so the guard is a test rather than a setting.

**Superseded 2026-09-15 (F24):** profiles did keep it stopped, but `compose up -d` with every service
profiled out fails, so Komodo could not deploy the stack at all. `qdirstat` was removed instead of
adopted, with its `ignore_services` entry and probe check.

### F9 — Komodo *can* deploy itself, if the periphery lives outside the Core stack

Portainer cannot deploy itself, which is the entire reason
[`deploy-portainer-app.yml`](../../../.github/workflows/deploy-portainer-app.yml) exists — 198 lines
driving TrueNAS `midclt app.update` (`custom_compose_config_string` is top-level, `app.update` needs
`-j`), with a last-known-good capture, a rollback, and a redeploy-API canary.

Komodo does not have that limitation. Because the **periphery** is what runs `docker compose`, and
periphery is a separate process from Core, a Stack that manages Core works: Core restarts mid-command
so the Update log reads as failed, but the periphery completes the redeploy and Core comes back on
the new version. The requirement is that **periphery is deployed outside the Core stack** — its own
compose project, or systemd.

**Decided 2026-09-08: self-managed Stack.** This is the largest single win available here, and it is
bigger than the finding claimed:

> **`NAS_SSH_KEY` has exactly one consumer.** `grep -rn NAS_SSH_KEY .github/ scripts/` finds it only
> in `deploy-portainer-app.yml`. It is `truenas_admin` with passwordless `sudo -n` — root on the NAS
> — and SEC-1's table has been narrowing the CI blast radius for three weeks. Deleting that workflow
> **removes the last root credential from CI**, finishing SEC-1's reduction list past where step 3
> could reach.

Cost, stated plainly: Core's own upgrade becomes **unverified**, exactly like `github-runner`'s
`DEFER_FIRE` deploy today. If Core comes up broken, nothing in CI can redeploy it. The recovery is a
hand-run `docker compose up -d` in the periphery's clone — which is real, because the files are on
disk at a known path (§10). Portainer has no such recovery: it never puts the compose file anywhere
usable.

### F10 — three of CPX-1's six accidental-complexity items die, one dies only with SEC-1 step 4, two survive

The finding says a pull-based agent makes them "all disappear together". That is too strong. Item by
item:

| CPX-1 item | Fate | Why |
| --- | --- | --- |
| webhook UUIDs discovered live from `/api/stacks` | **dies** | Komodo's listener is `/listener/github/stack/<name-or-id>/deploy`, derived from the name. No discovery call |
| git-credential-ID replay | **dies** | `git_account` is a Komodo resource, not a per-call field. The fast unlogged 500 stops being representable |
| endpoint-id prefix routing | **moves, improves** | Each Stack names its `server_id`. It stops being a `case` in bash and becomes a field — and via **ResourceSync** (TOML in this repo) it becomes reviewable in git, which the `case` never was. It does not vanish |
| `DEFER_FIRE` | **survives**, and gains a member | The runner still runs in a container the deploy can recreate, and F9 adds Core to the list. It dies **only** if the runner moves off Docker — which is SEC-1 step 4 (§6). That is the real argument for doing them together |
| `wait_converged` | **shrinks** | Komodo's deploy runs `docker compose up -d` and returns its output, so "did it land" becomes an exit code as predicted. "Is it healthy four minutes later" is a different question and still needs polling, because the auto-rollback depends on it |
| the reconcile pass | **survives, and moves into Komodo** | It exists because GitHub evicts *pending* runs from the concurrency group and a cancelled run has zero jobs and fires no webhook. That is a GitHub property, not a Portainer one. **Measured (§5 item 3, F16):** `poll_for_updates` and `KOMODO_RESOURCE_POLL_INTERVAL` do **not** redeploy on git drift. But `BatchDeployStackIfChanged` does, and it is a silent no-op when nothing is pending. So a scheduled Procedure replaces the bash. F16 also shows Komodo drops a deploy request that lands while the stack is busy, so the backstop is still required |

Net: `fire-webhooks.sh` gets materially smaller and `verify-healthy.sh` barely changes. Do not
promise the bash goes away.

### F11 — nothing deploys or checks `/mnt/apps/scripts/git-pull-nas.sh`

The running updater lives **outside** the clone on purpose, so a bad commit cannot break the updater.
The cost is that no mechanism updates it: #283 changed it in the repo and someone copied it to the
host by hand two minutes later. It matches today (verified, §0) — by discipline, not by design.

`nas-health-probe.sh` has a `repo-head` verb (`git rev-parse HEAD` of the on-host clone) but nothing
compares the host script to the repo. Add that comparison to the §1 probe. It is three lines and it
guards the mechanism the entire edge policy is delivered by.

### F12 — the "repo-tracked, hand-applied" pattern already exists, and periphery inherits it

Written after [#290](https://github.com/drizzelat/NAS/pull/290) and
[#291](https://github.com/drizzelat/NAS/pull/291) landed on 2026-09-08, which changed CPX-2
mechanism #3 under this plan's feet.

Both Portainer agents are now repo-tracked stacks — `stacks/micro-vps-agent/` and
`stacks/a1-vps-agent/` — pinned to `portainer/agent:2.45.0@sha256:…` (a multi-arch manifest list, so
one pin serves amd64 and arm64), with `docs/services/{micro,a1}-vps-agent.md` beside them. They are
on **both** `CREATE_SKIP` and `RECONCILE_SKIP` in
[`fire-webhooks.sh`](../../../scripts/deploy/fire-webhooks.sh), because *the agent is the transport
its own endpoint deploys through*: redeploying it through itself drops the tunnel mid-operation and
can leave the container created-but-not-started, taking the endpoint down with SSH the only way back.
The repo is source of truth; the host copy is applied over SSH as a deliberate step.

Three consequences for this plan:

1. **Komodo periphery inherits the pattern exactly.** Each periphery agent is the transport its own
   server deploys through, so `stacks/{micro-vps,a1-vps,nas}-periphery/` are repo-tracked,
   digest-pinned, documented, and never deployed by the control plane they serve. The precedent is
   established and written down — copy it rather than reinventing it.
2. **The NAS periphery is the same shape**, and F9 *requires* it to live outside the Core stack
   anyway. So "periphery outside Core" is not a Komodo quirk to work around; it is the estate's
   existing rule for transport containers, applied again.
3. **The two agent stacks survive the migration**, because §13 keeps Portainer as a read-only
   console (§10) and a console still needs its transport. They are not decommissioned in Phase 3;
   only their write path is. **Superseded 2026-09-17:** Portainer is removed completely, and both
   agents go with it (F27).

This also sharpens F11's point: `/home/ubuntu/agent/docker-compose.yml` is a *second* host file whose
source of truth is the repo and which nothing deploys. Same class as `git-pull-nas.sh`. The §1 probe
should assert all three host copies match the repo, not just one.

### F13 — the compose project name is load-bearing, and a mismatch does not fail loudly

**Measured on the A1, 2026-09-08.** Phase 0 item 1, tested against real `docker compose` v5.3.1
rather than reasoned about. Three cases, scratch stacks, cleaned up afterwards:

| Case | Result |
| --- | --- |
| Same project name, **different working directory** | **Adopted in place.** `Running`, identical container IDs, identical `com.docker.compose.config-hash`. No recreate |
| Different project name, service **has** `container_name:` | **Hard error.** `Conflict. The container name "/adopt-named" is already in use` — the deploy fails, nothing is duplicated |
| Different project name, service has **no** `container_name:` | **Silent duplication.** `dup-test-web-1` and `dup-test-komodo-web-1` both running the same image. Exit 0, no warning |

The first row is the good news, and it is the answer to §5 item 1: **the working directory does not
matter.** This was the real worry, because Portainer's `working_dir` label is not even stable
*within* one stack — on the A1, `matrix-synapse`, `matrix-element` and `matrix-caddy` each carry a
different `/data/compose/56/<sha>/…` path, one per redeploy. Komodo cloning to its own path is
therefore harmless. Adoption depends on the project name alone, and Portainer's project name **is**
the stack name (`a1-vps-matrix`, `a1-vps-kuma`, `a1-vps-beszel-agent` — verified from the labels).

The third row is the hazard, and it is worse than the "name and port collisions" the §5 row was
written to expect. Seven stacks have services with no `container_name:`:

`authentik` (3), `immich` (4), `filebrowser`, `portainer`, and the three transport stacks
`a1-vps-agent`, `micro-vps-agent`, `micro-vps-ingress`.

> **Re-counted 2026-09-14 from `origin/main`: six stacks now.** `filebrowser` became `files`, which
> has `container_name:` on every service, so it fails loudly and has left the list. The other six
> are unchanged; none of the stacks added since 2026-09-08 has an unnamed service. The analysis
> below still applies to `authentik` and `immich`.

For `authentik`, `immich` and `filebrowser` this composes into a genuine split brain, because two
other facts line up with it:

- They publish **no host ports**. There is no port bind to collide and stop the duplicate.
- Their `proxy_*` networks are `external: true`, so a duplicate joins the *same real network* as the
  original.
- **The Caddyfile addresses them by their compose-generated names** — `reverse_proxy
  https://authentik-server-1:9443`, `reverse_proxy http://immich-server-1:30041`.

So a Komodo deploy of `authentik` under any project name other than `authentik` produces
`<other>-server-1`, which Caddy is not configured to talk to. Caddy keeps routing to Portainer's
original container, which is still running. The result is two Authentik instances against one
Postgres volume, with the control plane reporting a successful deploy and the edge showing no error
at all. That is strictly worse than an outage: an outage is visible.

Consequences:

1. **Every Komodo Stack must assert its project name explicitly**, equal to the current Portainer
   stack name. Do not rely on Komodo's default derivation — verify it per stack (this is Phase 0's
   next measurement, and the only part of item 1 still open).
2. **§9 gains a mandatory pre-flight per adoption**: before deploying a stack from Komodo, capture
   `docker ps --format '{{.Names}} {{.Label "com.docker.compose.project"}}'` for it, and after the
   deploy assert the container IDs are unchanged. An adoption that *creates* anything is a failed
   adoption, even when it reports success.
3. **The project name is baked into the edge config.** Any future change to a stack's project name is
   a Caddyfile change in the same commit. Worth a comment in the Caddyfile at those three upstreams.
4. The `container_name:`-bearing stacks are the safe majority — they fail loudly. The four unnamed
   application stacks are the ones to adopt with the most care, and `authentik` is already scheduled
   into a maintenance window in §9.

### F14 — Caddy serves for ~65 s after a cold boot with no CrowdSec, and `depends_on` cannot fix it

Found on the 2026-09-08 reboot, which is exactly what gate item 2 was for.

Timeline from the container logs: `crowdsec` started 09:25:38Z, `caddy` 09:25:45Z — seven seconds
later, but CrowdSec's LAPI only finished starting at 09:26:34Z. In between, Caddy logged
`dial tcp 172.16.3.2:8080: connect: connection refused` against LAPI and `172.16.3.2:7422` against
AppSec, retrying every 10 s. Last error 09:26:50Z; recovered on its own, and
`caddy-bouncer@172.16.3.3` has pulled normally since.

Two halves, and only one of them is new:

- **AppSec is fail-open by deliberate policy.** The Caddyfile global block sets `appsec_fail_open`
  with the rationale written next to it: "crowdsec stops with its own stack, and a restart must not
  take all 25 sites down with it." That is a decision, not a regression, and it holds.
- **LAPI remediation is fail-open by accident.** The bouncer's decision cache is populated by
  `GET /v1/decisions/stream?startup=true`. Until that call succeeds the cache is *empty*, so every IP
  is allowed — including ones with active ban decisions. Nothing in the config chose this; it is a
  property of a streaming bouncer with no persisted cache.

**`depends_on: condition: service_healthy` does not fix this.** `depends_on` is a Compose-time
construct. On a host reboot the containers are restarted by dockerd from their `restart:
unless-stopped` policy, with no Compose process involved, and the daemon does not honour Compose
dependency ordering. Adding it would improve *redeploy* ordering only, and would read in the file as
if it had solved the boot case. `scripts/docker-boot-guard.sh` does not help either — it orders
dockerd against its ZFS data-root, not containers against each other.

What would actually close it, in increasing cost:

1. **Accept and document it.** ~65 s per boot, and boots are rare (57 days before this one). The
   window is degraded-but-serving, not open-to-anything: it affects known-bad IP remediation only.
2. **A POSTINIT step that waits for CrowdSec LAPI, then restarts Caddy.** Closes the window at the
   cost of a ~5 s full edge outage on every boot, plus another host script outside the clone — the
   exact class F11 complains about.
3. **A persisted decision cache**, if the bouncer supports one. Not investigated.

**Recommendation: option 1**, and it is recorded here rather than fixed. Option 2 trades 65 s of
degraded remediation for 5 s of hard downtime and a new unmanaged host script, which is a bad trade
on a home estate. Revisit if the edge ever starts rebooting often.

Two side notes from the same session, both closed:

- LAPI still held **nine** bouncer registrations from the decommissioned NPMplus (`npm-bouncer*`,
  `npmplus*`, all type `crowdsec-npmplus-bouncer`) — live API keys for a component that no longer
  exists. Deleted 2026-09-08; deleting a base name cascades to its `@<ip>` variants, confirming they
  share one key. Only `caddy-bouncer` remains, and it kept pulling throughout. A NPMplus rollback
  would now need `cscli bouncers add` first.
- Komodo periphery on the A1 will be **arm64** (`uname -m` = `aarch64`, 11.9 GiB RAM, 36 GiB free),
  which is where §5 item 4's arm64 RSS number comes from when it is measured.


### F15 — measured Komodo v2.3.3 behaviour, from a real instance

Scratch evaluation on the A1, 2026-09-08: Core + MongoDB as one compose project, Periphery as a
**separate** project (F9/F12), inbound mode, `core_public_keys` set. Core `9120` bound to the tailnet
address only; both ports verified unreachable from the internet (`8120` and `9120` refused from
outside, `443` reachable as the control). Matrix and Kuma on that host were untouched throughout.

**The commands Komodo actually runs**, captured from the update record — worth having verbatim,
because every claim below follows from them:

```
docker compose -p <project> -f compose.yaml config
docker compose -p <project> -f compose.yaml pull      # auto_pull, default true
docker compose -p <project> -f compose.yaml up -d
```

Plain `up -d`. No `--force-recreate`, and no `--remove-orphans`.

**Adoption costs exactly one recreate, once.** A container pre-created as project `adopt-probe` from
an unrelated directory, then deployed by a Komodo Stack of the same name:

| Deploy | Compose said | Container ID |
| --- | --- | --- |
| 1 (the adoption) | `Recreate` → `Recreated` | changed |
| 2 | `Running` | **same** |
| 3 | `Running` | **same** |

So the adoption is a **rolling recreate of every service in the stack**, and everything after it is
idempotent — the same steady-state behaviour Portainer has today. This is the number to plan the
maintenance windows around: not "will it duplicate" (it will not, given F13's project name), but
"every service in this stack restarts once, now". For `caddy` that is a brief edge drop; for
`adguard`, LAN DNS; for `tailscale`, the tailnet. Which is exactly the downtime already accepted in
§13, now with a known shape.

Confirmed by measurement, all previously assumed:

- **`project_name` is a first-class `StackConfig` field**, default `""`, derived from the stack name.
  F13's mitigation is therefore a one-line assertion per stack, not a workaround.
- **`destroy_before_deploy` defaults to `false`.** F7's requirement for `caddy` is the default, not
  something to remember to set. Still assert it explicitly.
- **A non-zero `post_deploy` fails the deploy** (`UPDATE success: False`, `Post Deploy` stage
  flagged). The `caddy reload` hook becomes *load-bearing and checked*, which is better than the
  current SVC-1 #13 behaviour where it silently no-ops.
- **`profiles:` are respected** — a `profiles: [manual]` service did not start. F8 holds; `qdirstat`
  stays dead without needing `ignore_services`.
- **`DestroyStack` is `docker compose -p <project> down`** — the same semantics as Portainer's Stop
  (SVC-1 finding #6), so the "down removes networks other stacks are attached to" hazard survives the
  migration unchanged. It is not a Portainer quirk being left behind.
- **Core is v2.3.3 and Periphery is v2.3.3**, confirming F2's breaking-agent-rewrite version.
- The `StackConfig` fields this plan depends on all exist: `project_name`, `destroy_before_deploy`,
  `ignore_services`, `pre_deploy`/`post_deploy`, `poll_for_updates`, `linked_repo`, `auto_pull`,
  `webhook_enabled`, `webhook_secret`, `run_directory`, `compose_cmd_wrapper`.

Two hazards found that the plan did not have:

1. **Komodo does not pass `--remove-orphans`.** Removing a service from a stack's compose file leaves
   its container running indefinitely, and the deploy reports success. Found by accident during the
   `profiles:` test. Add an orphan check to the §1 probe: any container whose
   `com.docker.compose.project` matches a managed stack but whose service is not in that stack's
   current compose file is an orphan.
2. **The official `mongo.compose.yaml` template silently produces an *unauthenticated* MongoDB if
   you start it wrong.** `env_file: ./compose.env` sets the *core service's* runtime environment,
   but `${KOMODO_DATABASE_USERNAME}` / `${KOMODO_DATABASE_PASSWORD}` in the YAML are **compose
   interpolation**, which reads `.env` — not `compose.env`. Start it without
   `--env-file compose.env` and Mongo gets empty root credentials, which Mongo treats as "no auth
   configured" and starts wide open on the compose network. Core then fails with
   `SCRAM failure: Authentication failed.`, which reads like a password typo rather than what it is.
   Hit during this evaluation. **The NAS deployment must pin `--env-file` in whatever applies the
   Core stack, and the §1 probe should assert Mongo requires auth.**

Also worth carrying, from the periphery config reference rather than from a test:

> `## If neither these nor passkeys provided, inbound connections will not be authenticated.`

`bind_ip` defaults to `[::]` and `allowed_ips` defaults to empty. So an inbound periphery started
without `core_public_keys` is an **unauthenticated Docker socket on `:8120`**, on every interface.
§13 chose inbound, so this is the estate's configuration: set `PERIPHERY_CORE_PUBLIC_KEYS` *and*
`PERIPHERY_ALLOWED_IPS` on all three, and have the §1 probe assert both. Passkeys still exist but are
marked `Deprecated. Legacy v1 compatibility.`

### F16 — git drift, busy stacks, pulls and self-deploy: the last three §5 items, measured

Measured on the A1 eval on 2026-09-14. All three items used a git-linked Stack on a throwaway public
repo, so no credential reached the eval host. Everything was torn down afterwards.

**Item 3: nothing Komodo schedules by default deploys a git change on its own.** A commit pushed
without a deploy, then:

| What ran | What it did |
| --- | --- |
| `RefreshStackCache` (what `KOMODO_RESOURCE_POLL_INTERVAL` drives) | Recorded the new commit as `latest_hash`, next to the old `deployed_hash`. No deploy |
| The `Global Auto Update` Procedure, run by hand (the thing `poll_for_updates` + `auto_update` hang off) | Nothing, while the image was current |
| The same Procedure with the running image made stale | **Redeployed the service, and the git pull came along**: the new commit's label went live |
| `DeployStackIfChanged` | Deployed the pending commit. With nothing pending it recreated nothing and wrote **no update record at all** |

So git drift only rides along with an image update. Otherwise it waits for a webhook.

`Global Auto Update` is not an interval. It is one of three Procedures a fresh Core creates with
schedules of its own: `Backup Core Database` at 01:00, `Global Auto Update` at 03:00 and
`Rotate Server Keys` at 06:00. Servers also default to `auto_prune: true`.

**Busy stacks drop requests, and the record lies.** A second execute sent while the stack was
still deploying was refused. The only trace is a Core log line, `ERROR: Resource is busy`. Its
update record said `status=InProgress success=true` with no logs, and stayed that way until the
next Core restart relabelled it a failure. A GitHub webhook that arrives mid-deploy is therefore
lost silently: the same class of loss as GitHub evicting pending runs, one layer down. **The
reconcile backstop is required, not optional (F10).** It should be a scheduled Procedure running
`BatchDeployStackIfChanged`, not bash.

A side effect: `auto_update` with `auto_pull: false` redeployed without pulling, so the stale image
stayed. The §4 table's `auto_pull: true` is load-bearing.

**Item 6: Komodo pulls in place, and the directory-mount rule stands.**

- **The pull:** a deploy runs `git checkout -f <branch>` then `git pull --rebase --force` inside the
  existing clone, and never re-clones.
- **The directories:** the clone directory and `probe/` kept their inodes across three pulls.
- **The file mount:** a container bind-mounting the changed file kept showing the **old** content.
- **The directory mount:** the same container's mount of the directory showed the new content.

§7's rule carries across verbatim.

**`stat -c %i` is not a valid test for this.** On the first pull the replaced file came back with
the **same** inode number, because the filesystem reused the number it had just freed. Only the second pull
showed a new one. Test with a real mount, as above.

**Item 7: self-deploy works, and its record says it failed.** A Stack of `project_name:
komodo-core-eval` pointed at Core's own compose, with a label change to force a recreate:

- **Adoption:** Core and Mongo were both recreated.
- **Recovery:** Core answered its API again within ~2 s, running the new config.
- **Periphery:** logged `Logged in to Komodo Core … websocket`.
- **Mongo:** still refused unauthenticated access afterwards.
- **The record:** `success=false`, with a single log stage: `Komodo shutdown during execution`.
- **A second deploy:** `Running`, nothing recreated.

F9 holds exactly as written, including its warning that the record will read as failed. Judge a
self-deploy by the containers.

### F17 — `PERIPHERY_ALLOWED_IPS` never sees the caller through a published port

Found in Phase 1, 2026-09-15. F15 said to set `PERIPHERY_ALLOWED_IPS` on all three peripheries. With
the ports published the usual way, it can only ever match the Docker bridge gateway:

- **On the NAS:** a throwaway container pair showed the caller arriving as `172.16.42.1`, the
  gateway of the *listener's* network, not its own `172.16.29.2`. Core reaches the NAS periphery
  through the published LAN port, so the same happens to it.
- **On the A1:** `tcpdump` showed the NAS's SYN arrive on `tailscale0` from `100.64.0.11`, then
  leave on the bridge from `172.22.0.1`. With `PERIPHERY_ALLOWED_IPS: 100.64.0.11`, both VPS
  Servers failed with `Failed to connect to websocket … HTTP error: 401 Unauthorized`.

What was done:

- **VPS peripheries:** `network_mode: host` with `PERIPHERY_BIND_IP` set to the tailnet IP. The
  periphery now sees `100.64.0.11`, the allowlist means something, and both Servers went `Ok`.
- **NAS periphery:** kept on a published port, with its subnet pinned to `172.31.120.0/24` and
  `172.31.120.1` allowed. That refuses the LAN but not other containers on the NAS. Core's key is
  the gate that matters there, and `nas-periphery.md` says so.

A `401` from a periphery means the same thing whether the IP was refused or no handshake was
offered, so a plain `curl` cannot tell you which. Test the allowlist from Komodo's Server state.

### F18 — the periphery's bundled compose cannot deploy on the NAS

Found in Phase 1, 2026-09-15, by the first self-deploy of the `komodo` Stack. Every stage passed
(secrets interpolated, private clone, `.env` written, `config`, `pull`) until `up`:

```
ParseAddr("fdd0:0:0:1b::1/64"): unexpected character, want colon (at "/64")
```

- **The cause:** the periphery image ships **docker compose 5.5.0**. TrueNAS 25.04 runs **Docker
  27.5.0**, which reports the IPv6 gateway of newer networks with its prefix length. Compose 5.5.0
  parses that strictly and aborts. Nothing was recreated, and the update record said `success=false`.
- **The reach:** 7 of the NAS's 45 networks have that format: `files_default`, `komodo_default`,
  `observability_net`, `periphery_default`, `proxy_files`, `proxy_komodo` and `proxy_observability`.
  So `komodo`, `caddy` (which defines the three `proxy_*` ones), `files` and `observability` could
  never have been adopted as shipped. The A1 (Docker 29.6.1) is not affected.
- **The test:** the host's own compose, **2.32.3**, bind-mounted into the same periphery image, ran
  `up --dry-run` clean for `komodo` (both containers `Running`, nothing to recreate) and for `caddy`.
- **The fix (decided 2026-09-15):** `nas-periphery` mounts
  `/usr/libexec/docker/cli-plugins/docker-compose` read-only over the bundled plugin. NAS deploys then
  use the compose that TrueNAS ships with its daemon, and it moves with TrueNAS updates. The VPS
  peripheries keep the bundled one.

Two things this also showed:

- **A secret Variable is masked everywhere in the logs.** The database username is `komodo`, so every
  `komodo` in the record read `<KOMODO__KOMODO_DATABASE_USERNAME>`, including the image name. That
  Variable is now not secret.
- **Every other stage worked** against the private repo, with the token added as a git account in the UI.

### F19 — Komodo's update history keeps Variable values in plaintext

Found in Phase 2, 2026-09-15, in the v2.3.3 source and confirmed on the live Core.

- **The cause:** `CreateVariable` logs the whole Variable with `{variable:#?}`, value included. For a
  secret Variable, `UpdateVariableValue` masks the old value and logs the new one in full. The masking
  that hides secrets in deploy logs does not apply to these records.
- **The evidence:** all six `KOMODO__*` Variables created in Phase 1 have their plaintext value in
  their `CreateVariable` record. Checked by length and shape only; no value was printed.
- **Who can read it:** admins, through `GetUpdate` or the UI. A non-admin, including the CI service
  user, is refused System-target updates (`user must be admin to view system updates`) and sees
  secret Variables as `#` masks. Admins can read the Variables directly anyway.
- **What it costs:** persistence. A rotated secret stays in Core's `updates` collection and in its
  daily backup. The offsite chain for that backup is encrypted
  ([storage.md](../../storage.md)).

Recorded, not fixed: there is no API to prune update records. Treat Core's database and its backups
as holding every secret the vault holds.

### F20 — the vault did not match Portainer's env for one stack

Found in Phase 2, 2026-09-15, before the first adoption. The vault is meant to be the source of truth
for every stack's env, and `resources.toml` was written on that assumption. But `secrets.sh push` is
the only thing that makes Portainer match the vault, so a hand edit in Portainer, or a vault edit
that was never pushed, is invisible.

- **Found:** a per-key hash compare of all 30 stacks, Portainer's `.Env` against the vault
  ciphertext, printing only key names. 29 stacks match exactly.
- **The one that did not:** `a1-vps-beszel-agent`'s `BESZEL_VPS_AGENT_TOKEN`. The vault's value
  (committed 2026-07-09) differed from the one Portainer and the running container used, and the
  lengths were the same.
- **What it would have done:** the adoption would have recreated the agent with the vault's token.
  Nothing would have failed loudly; the A1 would have dropped out of Beszel.
- **Fixed (decided 2026-09-15):** the vault took the live value, through `secrets.sh edit` with an
  EDITOR stand-in fed from a 0600 file ([#367](https://github.com/drizzelat/NAS/pull/367)).

Rule for every remaining adoption: hash-compare the vault with Portainer's env first. On 2026-09-15
the micro VPS and all 22 NAS stacks matched.

### F21 — a wildcard reconcile would adopt every Stack at once

Found in Phase 2, 2026-09-15, in the v2.3.3 source while designing the backstop (F16). In
`DeployStackIfChanged`, a Stack with no `deployed_contents` resolves to `FullDeploy`. A Stack the
ResourceSync declared, but that Komodo has never deployed, therefore counts as changed.

So once the sync created all 30 Stacks, a `BatchDeployStackIfChanged` over `*` would have adopted all
30 in one run: `caddy`, `tailscale` and `adguard` included, in parallel, with no pre-flight and no
health gate. The same goes for a GitHub webhook pointed at an unadopted Stack, because the listener
runs `DeployStackIfChanged` too.

Mitigations:

- **`reconcile-owned` lists the owned stacks by name.** An empty pattern matches nothing
  (`parse_string_list("")` is empty).
- **`scripts/komodo/check-owned.sh` in `compose-validate`** fails a PR whose pattern holds a wildcard,
  a regex or tags, or differs from `komodo/owned-stacks`.
- **No webhook points at Komodo.**

### F22 — recreating the ingress takes every public site down for ~11 s, set by Docker's stop timeout

Measured during the `micro-vps-ingress` adoption, 2026-09-15, with a 1 Hz sampler on the public path
and the host's `docker events`.

- **What happened:**
  - 14:47:26Z: compose sent `SIGQUIT`, the `nginx` image's `StopSignal`.
  - 14:47:36Z: Docker sent `SIGKILL` (exit 137), then the new container started.
  - `jellyfin`, straight to the VPS, was refused from 14:47:27.6Z to 14:47:38.5Z.
  - `files`, through Cloudflare, returned `521` on some samples in the same window.
- **The cause:** `SIGQUIT` is nginx's graceful shutdown. It closes the listeners at once, then waits
  for open connections to finish. This `stream` proxy carries long-lived tunnelled TCP, so they
  never finish, and the old container lives until Docker's 10 s timeout kills it. The port stays
  unbound the whole time.
- **The reach:** every recreate of this stack, not only the adoption. A `config-rev` bump or an
  image update costs the same ~11 s, and it cost the same under Portainer. The adoption only made
  it visible.
- **Not done:** `stop_grace_period` or `stop_signal: SIGTERM` (nginx's fast shutdown) on the
  service would shorten the gap, at the price of cutting open streams at once rather than after
  10 s. That is a stack change for its own PR. Before `caddy` (§9 order 29), check its stop signal
  and grace period the same way.

### F23 — `docker compose config` doubles every `$`, so a rendered inline config looks different from the live one

Found during the `micro-vps-ingress` pre-flight, 2026-09-15. Rendering the stack with the
periphery's compose 5.5.0 (`docker compose config --format json`) gave an `nginx.conf` that
differed from the one inside the running container. Only the `$` signs differed:
`config` writes them back as `$$`, so its output stays valid compose. With `$$` turned into `$`,
the two files were byte-identical, and `config --hash nginx` equalled the running container's
`com.docker.compose.config-hash`.

So compare an inline `configs:` block through `config --hash`, or unescape `$$` first. Otherwise a
correct render reads as drift. This matters again when Phase 3 turns that block into a real
`nginx.conf`.

### F24 — a stack whose every service is profiled out cannot be deployed by Komodo

Found on the first NAS adoption, `qdirstat` (§9 order 9), 2026-09-15. Its only service was
`profiles: [manual]`. Komodo's deploy runs `docker compose -p qdirstat -f docker-compose.yml up -d`,
and with nothing selected the NAS's compose 2.32.3 exits 1 with `no service selected`. The update
record showed `Compose Config` as `services: {}` and `Compose Up` failed. `deploy-stacks` run
34986692523 went red, nothing was created, and the §1 probe stayed green (34986877413). F8 and §5
item 8 had measured only that a profiled service does not *start* on a stack that also had an
unprofiled one.

A `--dry-run` on the NAS showed the alternative: `deploy.replicas: 0` instead of the profile
selects the service, creates no container and succeeds. It was not taken, because the stack was
no longer needed: it was removed (stack, vault file, Stack entry, probe check 4, Caddy vhost and
`proxy_qdirstat`), and the `qdirstat` Stack was deleted in Komodo after clearing its `server_id`.
Any future manual-start stack needs the `replicas: 0` shape, or an always-on service beside the
profiled one.

---
### F25 — on the NAS an adoption recreates nothing, because both control planes run the same compose

Found on the NAS adoptions, 2026-09-15. F15's "every service recreated once" held on the A1 and the
micro VPS, and every NAS stack came out `NO CHANGE` instead: Komodo's `Compose Up` reported each
container `Running`. The NAS periphery runs the host's compose 2.32.3 (F18), and it computes the
same `com.docker.compose.config-hash` for the rendered stack as Portainer's deploy did. The VPS
peripheries bundle compose 5.5.0, which hashes differently, so there every container was recreated.

What follows from it:

- **A NAS adoption costs no downtime.** It also changes no container, so the running containers keep
  Portainer's labels (`com.docker.compose.project.working_dir` is still
  `/data/compose/<id>/<sha>/stacks/<stack>`) until their next real change recreates them under
  `/mnt/apps/komodo/repos/nas`.
- **`NO CHANGE` is still proof against F13.** A project-name mismatch would have created a second set
  of containers under another project, and `adoption-check.sh verify` fails that as a duplicate.
- **Compose warns about the `proxy_*` networks on every `caddy` deploy:** `a network with name
  proxy_books exists but was not created for project "caddy"`. They still carry the `npm` project
  label from before the Caddy cutover (caddy-migration.md F2). Compose 2.32.3 only warns; a newer
  compose that refuses it would fail the deploy, so re-check after a TrueNAS update (F18).
- **The result can be predicted before deploying.** From the NAS, render the stack with the
  periphery's own compose and compare it with the running containers: `docker exec -w
  /mnt/apps/komodo/repos/nas/stacks/<stack> komodo-periphery docker compose -p <stack> -f
  docker-compose.yml --env-file <env> up -d --dry-run` prints `Running` or `Recreate` per
  container. Pass the env through a tmpfs file (`/dev/shm` inside the periphery) and remove it
  afterwards; `--env-file /dev/stdin` does not work, because compose reads the file more than once.
  `config --hash '*'` is not a substitute: it cannot resolve `network_mode: service:<name>` to
  that container's ID the way `up` does, so it reports every `downloads` service behind `gluetun`
  as changed when `up --dry-run` says `Running`.

### F26 — Portainer's canary redeployed a Komodo-owned stack

Found 2026-09-17, while reading for Phase 3. Renovate's portainer-ee 2.45.1 bump
([#425](https://github.com/drizzelat/NAS/pull/425)) ran `deploy-portainer-app` at 07:38Z, run
35195514621. After the app update, its write-path canary sent `PUT /api/stacks/67/git/redeploy` for
`files`, the default `PORTAINER_CANARY_STACK`, and got `200`. `files` has been Komodo's since
2026-09-15 (§9 order 16).

- **What it did:** nothing visible. The `files` container still dated from 2026-09-09 and still
  carried Portainer's `working_dir`, because both control planes hash the stack the same way (F25).
- **The reach:** every Portainer bump, and the canary's Sunday 06:00 UTC schedule, whose last run
  (2026-09-13) predates the adoption. If Portainer's stored env for `files` ever differs from the
  Komodo Variables, for example after `secrets.sh komodo-vars files` rotates its OIDC secret, the
  canary recreates `files` from Portainer's clone with the old env. Per §10 that hands the stack back
  to Portainer.
- **Why nobody listed it:** the canary guards `secrets.sh push`'s Portainer call, which no owned stack
  makes any more. Neither §8 nor §10 named the workflow's schedule as a write path.

Fixed by deleting the workflow (§8 Phase 3, PR 2).

### F27 — the plan contradicted itself twice, and both were settled by decision

Found 2026-09-17, while reading for Phase 3.

- **The VPS agents.** §8's Phase 3 list removed `agent-portainer_agent-1` from both VPSes. §10, F12
  point 3 and the end of §9 kept both `*-vps-agent` stacks, because a read-only console needs its
  transport. §8's bullet predated the console decision.
- **The runner.** §6 said both "delete `stacks/github-runner/`" and "the `github-runner` stack moves to
  `server_id` = the VM and keeps its compose file". A stack that `deploy-stacks` deploys still
  redeploys itself from inside its own job, on any host, so the second reading keeps `DEFER_FIRE`
  alive. F10's "dies only if the runner moves off Docker" is also imprecise: it dies when the runner
  stops being deployed by the job it runs.

**Decided 2026-09-17:**

- **Portainer is removed completely:** the TrueNAS app, both agents and its vhost. That is §10's
  rejected alternative. Its stack rows die with its database, so nothing can ever `compose down`
  through Portainer again. The cost is the console, plus §10's two Portainer rollback paths.
- **The runner deploys itself automatically, but never from its own job.** `github-runner` stays a
  Komodo Stack, on Server `runner-vm`, off `komodo/owned-stacks`. Its own hourly Procedure,
  `deploy-runner`, runs `BatchDeployStackIfChanged` for it alone. The Stack's `pre_deploy` waits until
  no job is running, so a recreate lands between jobs. `stacks/github-runner/` stays, because an
  automated deploy needs its compose in git.
- **Accepted risk:** a job can start in the seconds between the idle check and the recreate.

A broken runner bump is recovered by merging its revert in GitHub's UI. Komodo deploys that revert
without needing a runner.

### F28 — the `caddy` reload already runs, on the wrong clone, and a directory mount can go stale

Found 2026-09-17, in `komodo/resources.toml` and the v2.3.3 source.

- **The reload already exists.** The `caddy` Stack's `post_deploy` runs `caddy reload` on every
  deploy. The container still mounts `/mnt/apps/scripts/nas/stacks/caddy`, which `git-pull-nas.sh`
  pulls up to 15 minutes later. So today Komodo's reload applies the old Caddyfile and exits 0, and
  the cron's reload is the one that works. §7 #4a turns that round; it does not add a reload.
- **A pull can be five seconds old.** `lib/git/src/pull.rs` returns the previous pull's result when
  the same clone was pulled less than `PULL_TIMEOUT` (5,000 ms) ago.
- **A fresh clone orphans a directory mount.** A pull never re-clones. But `pull_or_clone` clones when
  the folder is missing, for example after a Repo rename or a hand clean-up. The bind mount keeps the
  deleted directory, and `caddy reload` exits 0 on it.

So after #4a the reload proves nothing on its own. `post_deploy` compares the container's Caddyfile
with the run directory's before reloading, and `deploy-stacks` checks that the Stack deployed a
commit at or after the one its run was for.

### F29 — CI can create exactly the new Stacks, through a filtered sync

Found 2026-09-17 in the v2.3.3 source. It closes the "not covered yet" gap under §8 Phase 2.

- **`RunSync` takes a filter.** It accepts `resource_type` and `resources`, and checks only Execute on
  the ResourceSync.
- **A filtered run touches nothing else.** With a filter set it skips Variables and user groups, and
  `komodo-resources` has `delete` off.

So the `deploy-stacks` service user needs Execute on that one ResourceSync, not admin. A new owned
stack becomes two filtered syncs, one for its Stack and one for `reconcile-owned`, then the normal
`DeployStack` with the health gate.

`ListStackServices` needs Read on the Stack, which Execute includes. `InspectStackContainer` needs Read
plus the Inspect permission. **Measured 2026-09-17** with a temporary key for the `deploy-stacks` user, after granting it Execute on
the ResourceSync `komodo-resources` and Inspect on Stacks:

- **The filtered sync ran as a non-admin.** `RunSync` filtered to `Stack` / `homarr` succeeded and
  logged `No Changes`.
- **The other reads work too.** `ListVariables` returns the Variable names with masked values;
  `ListStacks` with a names query returns `[]` for a missing Stack; `InspectStackContainer` answers.

### F30 — the NAS has no LAN bridge for the runner VM

Found 2026-09-17 with `ip -br link` on the NAS. The only bridges are Docker's and `incusbr0`: NAT on
`10.100.184.0/24`, down, no instances.

- **§6's "bridged to the LAN"** means building a bridge over the NAS's only NIC.
- **macvlan** cannot reach its own host, and the runner needs the host: Caddy, SSH as `nashealth`.
- **On NAT,** Caddy's `@lan` matcher (`192.168.178.0/24 172.16.25.1 100.64.0.0/10`) aborts the VM's
  requests to `komodo.example.com`.

**Decided 2026-09-17: NAT**, with `10.100.184.0/24` added to `@lan` in its own edge PR, proven green
before the VM depends on it. **Reversed the same day (F33):** the VM is a classic VM bridged onto the
LAN. The address the VM's periphery sees Core arrive from is measured when it
is built, not assumed (F17).

### F31 — seven config mounts come out of the auto-pulled clone, not two

Found 2026-09-17, in the pre-flight for §8 Phase 3's PR 3.

§3 counted two directory mounts out of `/mnt/apps/scripts/nas`, and §7 #4a, CPX-2 and Phase 3's brief
all named only `caddy` and `authentik`. That count was right on 2026-09-08 and wrong a week later.
`grep -rn /mnt/apps/scripts stacks/` finds seven:

- `caddy`: 1.
- `authentik`: 1.
- `observability`: 4 — `vector`, `victoriametrics`, `grafana/provisioning` and `grafana/dashboards`.
- `files`: its `/config`.

The same mechanism delivers config to all seven, so moving only the two named mounts would have left
CPX-2 #4a open while its record said closed. **Decided 2026-09-17:** the other five move in their own
PR (3b), straight after the edge change.

### F32 — Komodo's list calls stop at 50 and say nothing

Found 2026-09-17, while moving the §1 probe off Portainer (§8 Phase 3, PR 4).

- **What happened:** `read/ListAllContainers` returned **50** containers. The estate runs 77: 58 on
  the NAS, 5 on the micro VPS and 14 on the A1. There was no error, no `next` field and no warning.
- **The cause:** every paginated list call falls back to Core's `default_pagination_limit` when the
  request names no `limit`, and the default is 50. `read/ListStacks` is paginated the same way; it
  returned all 30 only because the estate has fewer than 50 Stacks.
- **The fix:** `"limit":0` returns everything. `read/ListDockerContainers` per Server is not paged.
- **Why it matters here:** a probe built on the capped call would have passed while not reading a
  third of the estate. That is the dump-truncation class of failure again: a partial result that
  reads as a whole one.

Every Komodo list call in this repo passes `"limit":0`.

### F33 — the runner VM is a classic VM on a bridge, and the first bridge cost 108 s

Found 2026-09-17, building §8 Phase 3's PR 10. F30's NAT decision did not survive it.

**Incus was the wrong backend.** TrueNAS 25.04.2 brought back the libvirt **Virtual Machines** screen,
and its release notes say new VMs are created there. The Incus feature became **Containers**. VMs made
on it before 25.04.2 no longer autostart, and TrueNAS urges moving them off. §3's "SEC-1 step 4 is
genuinely available" read `virt.global.config` and stopped there.

**A classic VM's NIC attaches to an interface or a bridge, nothing else.** Attached to `enp2s0` it
is macvtap, and a macvtap guest cannot reach its own host. The runner needs the host: Caddy for
Komodo, SSH as `nashealth`. `incusbr0` is not offered. So the NAS's LAN address had to move onto a
bridge over its only NIC, which F30 had ruled out as the riskier option.

**The first bridge took the NAS off the network for about 108 s.** `interface.commit` with
`rollback` and a 90 s `checkin_timeout`, from the workstation:
- **A new MAC.** TrueNAS gave `br0` a random MAC, `d6:09:5b:49:52:c3`. The FritzBox knew `.111` by
  `enp2s0`'s MAC, so DHCP handed `br0` `192.168.178.33`.
- **STP on**, TrueNAS's default for a new bridge.
- **The rollback.** The check-in was addressed to `.111` and never arrived. At 90 s TrueNAS
  reverted to `enp2s0` on DHCP, and Caddy answered again at 11:50:50Z. The NAS was unreachable from
  11:49:02Z.

**The retry kept the address static.** Same guard, with `br0` on `192.168.178.111/24` and
`stp: false`. The gateway and DNS were already static. About 2 s of loss, checked in at 11:57:13Z,
and the estate was green after both attempts.

What the bridge changed, measured afterwards:
- **No global IPv6 on `br0`**, only link-local. Nothing on the NAS used one.
- **EEE on `enp2s0` still `disabled`.**
- **The VM is at `192.168.178.34`**, pinned in the FritzBox. That is already inside `@lan`, so PR 9's
  widening had nothing left to admit and was reverted in [#442](https://github.com/drizzelat/NAS/pull/442).
- **Core reaches the VM's periphery as the NAS's LAN address**, masqueraded out of its container.
  `PERIPHERY_ALLOWED_IPS: 192.168.178.111` gave `Ok`, and `192.168.178.1` gave `NotOk`.

Two TrueNAS 25.04.2 API traps, for the next rebuild:
- **`vm.create` rejects `devices`** ("Extra inputs"). Create the VM, then `vm.device.create` each device.
- **A device cannot be deleted from a running VM**, so dropping the seed CD-ROM needs a stop and start.

**Decided 2026-09-17:** a classic VM on `br0`, static `.111` on the bridge, and decision 14 reversed.

### F34 — a runner deploy that waits shows as `deploying`, and fails the job it waits for

Found 2026-09-17, verifying §8 Phase 3's PR 11 with a comment-only compose change
([#445](https://github.com/drizzelat/NAS/pull/445)).

- **What happened:** `deploy-runner` was run while a dispatched probe job was on the runner. The
  guard worked: `Pre Deploy` ran 13:15:25–13:16:16Z and logged `idle (no Runner.Worker) after 50s`.
  The job ended at 13:16:08Z, and compose ran at 13:16:17Z. But the probe job it had waited for failed
  (run 35225898207): `FAIL  stack github-runner is deploying in Komodo, not running`.
- **The cause:** Komodo holds a Stack in `deploying` for the whole deploy, `pre_deploy` included. The
  runner holds one job at a time, so the waited-on job is the one reading that state. The health
  check's check 14 reads it too, so a runner change landing at `:53` during the nightly check would
  have failed it.
- **The fix,** [#447](https://github.com/drizzelat/NAS/pull/447): both accept `deploying` for `github-runner` only, and print a note. Re-run
  with a plain `DeployStack` sent mid-job: the job ended at 13:20:07Z green with the note, and
  `Pre Deploy` released at 13:20:12Z.

**The guard's first draft failed open.** It asked `docker top <c> -eo args`, which Docker refuses
(`Couldn't find PID field in ps output`), and it read any `docker top` failure as "not running". It
would have deployed through every job. The error came out when the guard was run on the NAS runner,
before merge. The guard now checks `.State.Running` with `docker inspect`, and a `docker top` error
fails the deploy.

### F35 — the runner VM resolved names only through AdGuard

Found 2026-09-17, in PR 11's pre-flight.

- **The VM took the FritzBox's DHCP answer:** AdGuard on `192.168.178.111`, alone.
- **The NAS runner had resolved through the NAS host:** `1.1.1.1`, then `192.168.178.111`.
- **What that would have broken:** a broken AdGuard would have cut CI off from GitHub. AdGuard is a
  Stack CI deploys, so fixing it would have needed a deploy by hand.

**Decided and done 2026-09-17:** the VM's netplan ignores DHCP DNS and uses `1.1.1.1`, then
`192.168.178.111`, like the NAS host ([#444](https://github.com/drizzelat/NAS/pull/444), applied live first). No job relies on a LAN
name; each passes `--resolve`.

## 3. Host inventory — enumerated from the live estate

Sources: Portainer `/api/endpoints` and `/api/stacks`, `docker ps` on all three hosts, `midclt`, and
`tailscale status`. Not the docs.

| # | Host | Tailnet | Arch | RAM | Endpoint | Stacks |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | NAS (TrueNAS SCALE 25.04.2.6) | `100.64.0.11` (user-owned) | x86_64 | 31 GiB, 4 cores | 3, local socket | **22** |
| 2 | AMD micro VPS | `100.64.0.12` (`tagged`) | x86_64 | **954 MiB, 373 MiB free, no swap** | 4, agent `:9001` | 2 (+ its agent, F12) |
| 3 | Ampere A1 | `100.64.0.13` (`tagged`) | **aarch64** | 11.9 GiB, 2 cores | 5, agent `:9001` | 6 (+ its agent, F12) |
| 4 | **Runner VM** — built 2026-09-17 (F33) | none; LAN only, `192.168.178.34` | x86_64 | 2 GiB, 2 cores; classic VM on zvol `apps/runner-vm` | Komodo Server `runner-vm` | 1 (github-runner) (+ its periphery, F12) |
| 5 | **Raspberry Pi** — planned, secondary DNS | tailnet | **arm64 required** | see §14 | — | 1 (adguard-secondary) |

**The three-node cap is now a real blocker, not a hypothetical.** Hosts 4 and 5 are both planned
(§13 decisions 2 and 6). portainer-ee free tier covers three; the estate is at three and going to
five. This is the finding's headline driver and it holds.

24 Portainer stacks against 25 `stacks/` folders — `portainer` itself is the TrueNAS custom app and
is correctly absent. Every stack has a webhook and `Authentication: true`.

> **Re-enumerated 2026-09-14 from `/api/stacks`: 30 stacks, not 24.**
>
> - **By host:** 22 on the NAS, 2 on the micro VPS, 6 on the A1.
> - **Added since 2026-09-08:** `conduit`, `observability` and `snowflake` on the NAS; `a1-vps-ntp`,
>   `a1-vps-tor-bridge` and `a1-vps-webtunnel` on the A1.
> - **Renamed:** `filebrowser` is now `files`.
> - **Folders:** 33 `stacks/` folders against 30 stacks. The three not in Portainer are `portainer`
>   and the two `*-vps-agent` transports (F12).
>
> The table, the lists below and the §9 order are updated to match.
> "24 adoptions" anywhere in this plan now means 30.

**NAS (21):** adguard, arr, authentik, beszel, books, caddy, conduit, downloads, files, games,
github-runner, homarr, immich, jellyfin, kuma, mealie, observability, paperless, romm, snowflake,
tailscale (`qdirstat` removed 2026-09-15, F24)
**micro-vps (2):** micro-vps-ingress, micro-vps-beszel-agent
**A1 (6):** a1-vps-matrix, a1-vps-kuma, a1-vps-beszel-agent, a1-vps-ntp, a1-vps-tor-bridge, a1-vps-webtunnel

Facts that constrain the plan:

- **Both Komodo images are multi-arch.** `ghcr.io/moghtech/komodo-core:2` and `komodo-periphery:2`
  publish `linux/amd64` **and** `linux/arm64`. The A1 is covered; verified against the ghcr manifest
  list, not assumed.
- **The micro VPS has 373 MiB free and no swap.** Periphery is a small Rust binary and
  `agent-portainer_agent-1` goes away in exchange, so this is probably neutral — **probably** is not
  good enough on a host with no swap that is the estate's only public front door. Measure both RSS
  side by side before removing anything (§5).
- **`virt.global.config` is `INITIALIZED`** on pool `apps`, dataset `apps/.ix-virt`, network
  `10.100.184.1/24`, with **zero instances**. `virt.instance.image_choices` offers 46 VM-capable
  images including `ubuntu/noble/default`. SEC-1 step 4 is genuinely available on this host (§6). **Not as an Incus VM (F33).**
- **13 cron jobs**, 12 of which execute scripts from `/mnt/apps/scripts/nas/scripts/`. Only
  `git-pull-nas.sh` runs from outside the clone, at `7,22,37,52 * * * *`. This is mechanism #4 and
  §7 is about what happens to it.
- **Two directory bind mounts come out of the clone**, and no file-shaped bind mount exists anywhere
  in `stacks/` (checked by parsing all 25 compose files, not by grep):
  `/mnt/apps/scripts/nas/stacks/caddy:/etc/caddy:ro` and
  `/mnt/apps/scripts/nas/stacks/authentik/blueprints:/blueprints/nas:ro` (**seven by 2026-09-17**, F31). The single-file-inode trap
  from SVC-1 #13 is currently closed estate-wide. **Any Komodo design must keep it closed** — a
  config mount is always the directory.

---

## 4. The Komodo shape

```
NAS
├── komodo stack  (deployed by Komodo itself — F9)
│   ├── mongo         labels: {komodo.skip: }        # never stopped by StopAllContainers
│   ├── core          :9120, KOMODO_DATABASE_ADDRESS=mongo:27017
│   └── (no periphery here — see below)
├── komodo-periphery  (separate compose project, deployed by hand / systemd)
│   └── periphery     PERIPHERY_ROOT_DIRECTORY=/mnt/apps/komodo   # F4
│                     /var/run/docker.sock, /proc
└── /mnt/apps/komodo/
    ├── repos/nas/  one shared clone of this repo (F5 Repo Linking, measured path)
    └── backups/  dated DB backups → Cloud Sync chain (F3)

micro-vps, A1
└── komodo-periphery  PERIPHERY_ROOT_DIRECTORY=/etc/komodo
                      inbound on :8120 (F6), replacing agent-portainer_agent-1
```

Resource model, one `Repo` + 24 `Stack`s:

| Field | Value | Note |
| --- | --- | --- |
| `linked_repo` | the one `Repo` resource | F5 — one clone per host, not 19 |
| `server_id` | NAS / micro-vps / A1 | replaces `target_endpoint()`'s name-prefix `case` (F10) |
| `run_directory` | `stacks/<name>` | the monorepo layout, unchanged |
| `file_paths` | `["docker-compose.yml"]` | |
| `environment` | per-stack env, Variables/Secrets interpolated | replaces Portainer stack env vars |
| `env_file_path` | `.env` (default) | Komodo writes it and passes `--env-file` |
| `webhook_enabled` | true | listener `/listener/github/stack/<name>/deploy`, HMAC on `KOMODO_WEBHOOK_SECRET` |
| `destroy_before_deploy` | **false, everywhere** | F7 |
| `extra_args` | **empty** | F8 — no `--profile` |
| `ignore_services` | none since `qdirstat`'s removal (F24) | F8 |
| `auto_pull` | true | matches the pre-pull the deploy does today |
| `post_deploy` | `caddy` only, see §7 | the reload hook |

Declare all of it as **ResourceSync** TOML in this repo. That is the piece Portainer has no
equivalent of: today "which endpoint does `a1-vps-matrix` deploy to" is a `case` in a bash script and
a row in Portainer's database, and the two are only in agreement by convention. As TOML it is one
reviewable file with the same CI treatment as everything else — which is the same argument SVC-1 made
for the Caddyfile, applied to the control plane.

**Drafted 2026-09-14, applied 2026-09-15: [`komodo/resources.toml`](../../../komodo/resources.toml).**
It declares 3 servers, the one `Repo`, the `reconcile-owned` Procedure and all 30 Portainer stacks in
§9 cutover order. The ResourceSync `komodo-resources` reads it (`delete` and `managed` off, Variables
and user groups excluded) and is executed by hand after its pending diff is read. The first run
created the 30 Stacks and the Procedure, and changed nothing else. Declaring a Stack deploys nothing. What review should hold every entry to:

- **`project_name` equals the stack name, written out.** Adoption is a project-name match, and a
  derived name silently duplicates `authentik`, `immich` and `files` (F13).
- **`destroy_before_deploy = false` everywhere** (F7). **`extra_args` is never set** (F8).
- **`environment` names Komodo Variables, never values.** The form is `KEY=[[<STACK>__<KEY>]]`, for
  example `PG_PASS=[[AUTHENTIK__PG_PASS]]`. `scripts/secrets.sh push` will write those Variables as
  secrets from the vault. The key names were taken from the vault and match Portainer's env for
  every stack.
- **Deliberately absent:**
  - `portainer`, which is never adopted (§10).
  - The two `*-vps-agent` stacks (F12).
  - Komodo's own stack and the peripheries, which arrive with `stacks/komodo` (F9).

Measured against the A1 eval with a ResourceSync built from this exact file. It was created, its
pending diff was read, and it was deleted without running:

- **It parses, with no pending error.** The diff was exactly 3 Server, 1 Repo and 30 Stack creates.
  `post_deploy.command` on `caddy` and `ignore_services` on `qdirstat` both survived into it.
- **A misspelt field is dropped silently.** `ignore_servicez = ["x"]` parsed clean and was simply
  missing from the proposed resource. Review a changed entry in the sync's pending view, not only
  in the TOML.
- **A Variable named with `__` interpolates, and a secret one stays masked.** `[[PFX_TEST__SECRET_KEY]]`
  reached the container's environment, and the value appeared nowhere in the update log.
- **Repo Linking clones to `<root>/repos/<repo name>`, not `stacks/`.** Two linked stacks shared one
  clone at `/etc/komodo/repos/scratch`. The second deploy ran `git pull` there rather than cloning,
  and both containers' working dir was `…/repos/scratch/probe`. On the NAS that is
  `/mnt/apps/komodo/repos/nas/stacks/<name>`.

**Authentication: local admin only, permanently (decided 2026-09-08).** `KOMODO_LOCAL_AUTH=true`,
one user seeded by `KOMODO_INIT_ADMIN_USERNAME` / `_PASSWORD`, 2FA on (a passkey, as set up 2026-09-15),
`KOMODO_DISABLE_USER_REGISTRATION=true`, and every OAuth/OIDC provider left `false`. No Authentik
integration, now or later. The consequence is deliberate and worth stating: **the control plane stays
independent of every stack it deploys**, so a broken Authentik can never lock you out of the thing
that fixes Authentik. The cost is that Komodo is the one service outside the estate's SSO. Its
credentials belong in Bitwarden alongside the TrueNAS ones, not in the vault.

**Secrets stay in one place.** Komodo Core has built-in Variables and Secrets, so
`secrets.enc/portainer-env/*.env.age` → `scripts/secrets.sh push` keeps its shape: one command from
the workstation, writing into the control plane, with CI holding no vault key (SEC-1 step 2 stands).
Only the API call changes. This is a real advantage over §11's Option B.

---

## 5. What must be measured before Phase 1 — none of it has been

The Caddy plan had a measured results table here before it was written, from a real Caddy 2.11.4 with
stub upstreams on the A1. **All eight are now measured** against a real Komodo v2.3.3 on the A1:
items 1, 2, 4, 5 and 8 on 2026-09-08 (F15), and items 3, 6 and 7 on 2026-09-14 with a git-linked
Stack (F16). Item 4's amd64 half was measured on the micro VPS in Phase 1, on 2026-09-15.

| # | Question | Why it decides something | How |
| --- | --- | --- | --- |
| 1 | ~~**Does Komodo's `compose up` adopt Portainer's existing containers, or create duplicates?**~~ | The whole parallel-run story | **Answered — F13 and F15.** It adopts. `project_name` is a real `StackConfig` field and Komodo derives it from the stack name. Adoption costs **exactly one recreate per container**, once; every deploy after that is idempotent |
| 2 | ~~Does a `post_deploy` non-zero exit fail the Komodo deploy?~~ | Whether the `caddy reload` hook can be trusted, or silently no-ops as it did in SVC-1 #13 | **Measured: yes, it fails.** `post_deploy: "exit 7"` produced `UPDATE success: False` with the `Post Deploy` stage flagged. **This is strictly better than what SVC-1 has today** |
| 3 | ~~Does `poll_for_updates` redeploy on **git** drift, or only on image updates?~~ | Whether the reconcile pass survives (F10) | **Measured: images only.** A pushed commit sat as `latest_hash` through a cache refresh and a `Global Auto Update` run. It went live only when an image update triggered a redeploy, or through `DeployStackIfChanged`. That call is the reconcile replacement, and Komodo drops a request that lands while the stack is busy, so the backstop stays — F16 |
| 4 | ~~Periphery RSS, arm64 and amd64~~ | The micro VPS has 373 MiB and no swap | **arm64 measured, idle: periphery 9.7 MiB vs `agent-portainer_agent-1` 16.5 MiB — periphery is *lighter than the agent it replaces*.** Core 47.5 MiB, Mongo 97.1 MiB. **amd64 measured 2026-09-15 on the micro VPS, idle, both running side by side: periphery 13.4 MiB summed process RSS (22.5 MiB cgroup) vs the agent 20.8 MiB (23.9 MiB cgroup).** `MemAvailable` went from 384 to ~355 MiB with both running. The RAM worry is unfounded on both architectures. **Under a deploy, measured 2026-09-15** at 2 Hz during the `micro-vps-beszel-agent` adoption, the micro's first Komodo deploy (a full clone of the 5.8 MiB repo, plus pull and recreate): `MemAvailable` never fell below **341 MiB**, against ~360 idle. The periphery cgroup peaked at **167 MiB** of its 256 MiB limit, almost all page cache (2.4 MiB anon), with 0 OOM events. That is the headroom §9 asks for before `micro-vps-ingress` |
| 5 | ~~Is the tailnet grant NAS→VPS port-specific?~~ | F6 — whether `8120` is reachable at all | **Measured 2026-09-08: no, it is not port-specific.** `nc -vz 100.64.0.12 8120` from the NAS returns `Connection refused`, not a timeout, while `:22` on the same host succeeds. A refusal means the SYN reached the host and was answered with an RST, so the ACL permits arbitrary ports NAS→VPS; nothing is listening on `8120` yet. **F6's inbound-periphery design works as decided** |
| 6 | ~~Does Komodo pull with `reset --hard` (new inode) or in place?~~ | Whether the directory-mount rule from SVC-1 #13 still applies | **Measured: `git pull --rebase --force` in place, and the rule applies.** Directory inodes are stable. A file bind mount kept the old content while a directory mount of the same path showed the new one. `stat -c %i` alone misleads: an inode number was reused on one pull — F16 |
| 7 | ~~Core restart mid-self-deploy — does the periphery finish?~~ | F9's whole premise | **Measured: yes.** Core recreated itself and was back in ~2 s on the new config; the next deploy was idempotent. The update record reads `success=false`, "Komodo shutdown during execution", exactly as F9 warned — F16 |
| 8 | ~~Does Komodo respect `profiles:`?~~ | F8 — that qdirstat stays dead | **Measured: yes.** A `profiles: [manual]` service did not start. But the same test found Komodo does **not** pass `--remove-orphans` — see F15 |

Item 1 gated everything, and it is now answered: Komodo **can** adopt in place, so this stays a
per-stack migration rather than 24 outages. Two caveats came with the answer, and both are in the
findings rather than here: a project-name mismatch does not fail loudly on the stacks that matter
most (**F13**), and adoption is not free — it costs one container recreate per service, once
(**F15**). Read both before Phase 1. F13 adds a mandatory pre-flight to every adoption in §9; F15
sets the expectation for what each adoption actually does to a running service.

**Nothing is left to measure before Phase 1.** The A1 eval has no purpose left.

> **Tear it down when this line merges.** The §1 probe allows the eval's containers only while
> this section still says items 3, 6 and 7 are unmeasured, so leaving it running turns every probe
> run red. Teardown: `docker compose -p komodo-core-eval down -v`, the same for
> `komodo-periphery-eval`, then `rm -rf /opt/komodo-eval /etc/komodo`.

---

## 6. SEC-1 step 4 — the runner into a VM

Fold in, because F10 shows it is not merely convenient: **`DEFER_FIRE` dies only if the runner stops
being a Docker stack on the host it deploys to.** That is the same reason `fire-deferred.sh` exists
and why `github-runner` is on `CREATE_SKIP` and `RECONCILE_SKIP`.

The host supports it: Incus is initialised on `apps`, no instances exist, and `ubuntu/noble/default`
is available as a **VM** (not only a container) — 46 of 78 images offer the VM type.

Shape:

- `virt.instance.create` a VM, 2 vCPU / 2 GiB, on `apps/.ix-virt`, bridged to the LAN so it can reach
  Komodo Core, GitHub and the tailnet.
- Docker inside the VM; the runner as a normal container there, **still with no `docker.sock` from
  the NAS host**. Today's `security_opt: no-new-privileges` and 1 GiB limit stay.
- Delete `stacks/github-runner/`. It stops being a stack, so `DEFER_FIRE`, `CREATE_SKIP` and
  `RECONCILE_SKIP` all lose their only member and the special-casing in three places goes.
- The VM is the **fourth Docker host**, which portainer-ee's free tier cannot take. **Decided
  2026-09-08: it is built second — Komodo → runner VM → Pi (§14).** Building it before Komodo would
  mean buying a Portainer licence for a node that is about to be migrated anyway.
- It is onboarded as an ordinary Komodo Server: periphery in the VM, `stacks/runner-vm-periphery/`
  repo-tracked and hand-applied per F12. The `github-runner` stack moves to `server_id` = the VM and
  keeps its compose file almost unchanged.

Cost, honestly: a VM is a new thing to patch, back up and boot-order. The runner's failure mode
becomes "the VM did not come up" rather than "the container did not come up", which is strictly
harder to diagnose from the TrueNAS UI. And an Incus VM on `apps/.ix-virt` is a dataset nothing in
[storage.md](../../storage.md) or the health check knows about yet.

> **Two corrections, 2026-09-17.** The bullets above disagree about the runner stack (F27).
> `stacks/github-runner/` is **not** deleted. It becomes a Komodo Stack on `runner-vm`, deployed by
> its own Procedure between jobs rather than by `deploy-stacks`. That is what retires `DEFER_FIRE`.
> ~~And the VM is not bridged to the LAN: it sits on `incusbr0` NAT, with `@lan` widened for it (F30).~~
> **Reversed the same day (F33):** a classic VM on the Virtual Machines screen, bridged to the LAN
> through `br0`, on a zvol, not on `apps/.ix-virt`.

---

## 7. CPX-2 — which mechanisms collapse, and which do not

Answering the question directly, because the finding's "collapses the first three toward one" is
optimistic.

| # | Mechanism | Verdict |
| --- | --- | --- |
| 1 | Portainer GitOps webhook | **Replaced, not collapsed.** Komodo Stack listener. Better — the URL is derived from the name, HMAC-authenticated, and Komodo filters on branch |
| 2 | TrueNAS `midclt app.update` (the control plane deploying itself) | **Dies**, given F9's constraint that periphery lives outside the Core stack. `deploy-portainer-app.yml` deleted, and `NAS_SSH_KEY` — the last root credential in CI — with it. This is the finding's best claim and it holds |
| 3 | Manual bootstrap | **Changes name, not nature — and #290 already renamed it.** Since 2026-09-08 this is no longer "manual bootstrap" but **repo-tracked, hand-applied** (F12): the agents are digest-pinned stacks with service docs, on `CREATE_SKIP`/`RECONCILE_SKIP`, applied over SSH. Komodo periphery inherits that pattern unchanged. What *does* die is the **break-glass nginx copy at `/home/ubuntu/docker-compose.yml`**: Komodo materialises the whole repo on the VPS, so the break-glass copy *is* the clone. That also removes the reason `micro-vps-ingress` inlines its nginx config as a `configs:` block |
| 4 | Auto-pulled repo clone, 15-min cron | **Splits.** See below |

### Mechanism #4 splits, and this is the part to get right

It does two unrelated jobs today:

**(a) It delivers config files to running containers** — `stacks/caddy/` → `/etc/caddy`, and
`stacks/authentik/blueprints` → `/blueprints/nas`. **This collapses into #1.** Point the mounts at
Komodo's clone instead of `/mnt/apps/scripts/nas`, and the same webhook that deploys the stack also
delivers its config. The 15-minute window becomes seconds, and `git-pull-nas.sh`'s reload branch moves
into the Stack's `post_deploy` — where it is in git, reviewable, and versioned with the Caddyfile it
applies, instead of in a script that nothing deploys (F11).

> **Done 2026-09-17**, for all seven mounts (§8 Phase 3 PRs 3 and 3b, F31). No container mounts
> `/mnt/apps/scripts/nas` any more. Each Stack's `post_deploy` also checks that its containers see the
> clone's content (F28): `caddy` with `cmp` before its reload, the other three with
> `scripts/komodo/mount-matches.sh`.

**PR #283 moved this mechanism precisely because the estate's edge policy is applied by #4, not #1.**
That does not change under Komodo; what changes is that #1 and #4 become the same pull. Two rules
carry across verbatim and must not be rediscovered:

- **The mount stays the directory.** Komodo's pull replaces files the same way `git reset --hard`
  does, so a single-file mount would hold the old inode exactly as SVC-1 #13 documented. **Measured
  (§5 item 6, F16):** a file mount stayed stale across a Komodo pull, and a directory mount did not.
- **`post_deploy` is required, not optional.** `compose up` sees no change to the `caddy` service and
  leaves the container running — the same green no-op. And this time **there is no 15-minute cron
  behind it**. Collapsing #4 removes the backstop that currently saves you, so the reload has to be
  load-bearing and its failure has to fail the deploy (§5 item 2).

**(b) It delivers host scripts for 12 cron jobs.** **This does not collapse, and should not.**
`git-pull-nas.sh` runs from outside the clone on purpose, so a bad commit cannot break the updater;
repointing cron at Komodo's clone would mean a Komodo outage freezes every host script — the SMART
tests, the backups, the dumps, the heartbeat. Keep `/mnt/apps/scripts/nas` exactly as it is, with two
clones of the same repo on the NAS. That redundancy is the property that keeps the estate recoverable
while the control plane is down, and it costs 29 MB.

**One-time hazard:** the moment the caddy mount moves to Komodo's clone, `git-pull-nas.sh`'s reload
branch must be deleted **in the same change**, or two reload paths race on two clones at different
commits. That is a single commit that touches a repo file and a host file that nothing deploys (F11)
— the exact shape of change this estate has already got wrong once.

**Score: one dies (#2), one is replaced (#1), one keeps its shape under a better name (#3, F12), one
half-collapses (#4a) and one half stays (#4b).** Four mechanisms become three, not one.

The honest reading is that #3 is the one the finding was most wrong about. It called it "manual
bootstrap" and expected it to fold into the control plane; #290 instead made it *rigorous* —
pinned, documented, CI-skipped on purpose — which is the right answer and is not going away. Every
control plane needs a transport, and a transport cannot deploy itself. Komodo does not change that;
it just adds a third instance of it (§14 makes it a fifth).

---

## 8. Phases

Each phase before the cutover is reversible by doing nothing.

### Phase 0 — evaluate and measure (no estate impact; can start today)

1. Stand up Komodo Core + Mongo + periphery **on the A1**, in a scratch compose project, exactly as
   the Caddy plan stood up a Caddy with stub upstreams there. Not a stack, not in git.
2. Answer every row of §5. Any row that comes back differently from the assumption above changes this
   plan **before** Phase 1, and gets written into a findings section like this one.
3. Write and merge `deploy-state-probe.yml` against **Portainer** (§1). Leave it green for a week.
4. Correct SVC-2's licence claim (F1).
5. Exercise the `caddy reload` hook with a deliberate no-op Caddyfile change (§0 gate item 4).

Phase 0 produces a **decision**, not a deployment. If item 1 of §5 fails, stop here.

### Phase 1 — parallel control planes (no estate impact)

Komodo Core and Portainer both running, both able to reach all three hosts, **nothing adopted**.

- `apps/komodo` dataset, `/mnt/apps/komodo` root (F4).
- Komodo stack on the NAS, bootstrapped by hand once, then self-managing (F9).
- Periphery on all three hosts alongside `portainer_agent` — both keep running. Measure §5 item 4 on
  the micro VPS before deciding anything.
- Core on `:9120`. Add `komodo.example.com` as a LAN-only Caddy vhost. **That means adding the name
  to `LAN_ONLY_HOSTS` and `network.md`, which changes the edge probe — so it lands as its own PR,
  merged and proven green first.** Same discipline as SVC-1 F1.
- ResourceSync TOML committed, describing all 24 stacks, **not applied**.

**Progress, 2026-09-15** (started ahead of start gate 6, by decision):

- [x] `apps/komodo` dataset, with `apps/komodo/backups` as its own leaf so the Cloud Sync chain
  carries only the dated dumps (F3).
- [x] `komodo.example.com` and `proxy_komodo`, in their own PR first:
  [#360](https://github.com/drizzelat/NAS/pull/360). `edge-access-policy` and `deploy-state-probe` were
  both green on it before anything else landed.
- [x] `stacks/komodo` plus `stacks/{nas,a1-vps,micro-vps}-periphery`:
  [#352](https://github.com/drizzelat/NAS/pull/352). Merging deployed nothing (all on `CREATE_SKIP`).
- [x] Core bootstrapped by hand on the NAS (`docker compose -p komodo --env-file`, env removed with
  `shred` afterwards). Mongo healthy and refusing unauthenticated `listDatabases`.
- [x] A periphery on all three hosts, beside `portainer_agent`. `core.pub` was written to each VPS
  before first start, so no periphery trusted Core on first use. All three Servers `Ok`, created with
  `auto_prune: false` (decided 2026-09-15: nothing prunes images before Komodo owns the stacks).
- [x] §5 item 4, amd64 half. See the §5 table.
- [x] §1 probe green with all five new containers: 77 containers, 0 failures.
- [x] Git account `github.com/drizzelat` (a read-only token, added in the UI), the `nas` Repo, and
  six `KOMODO__*` Variables from the vault (the database username not secret, F18).
- [x] **Self-managing `komodo` Stack (F9).** After the F18 fix
  ([#361](https://github.com/drizzelat/NAS/pull/361)), `DeployStack` succeeded at 11:32Z: `git pull`
  into `/mnt/apps/komodo/repos/nas`, `.env` written from the Variables, and `up` found both containers
  `Running`. `adoption-check.sh verify komodo` said `NO CHANGE`: the hand-bootstrap and Komodo produce
  the same compose config, so adoption cost nothing here. F9's restart-mid-deploy path is therefore
  still unexercised on the NAS; the first real change to `stacks/komodo` will exercise it.
- [x] Admin password changed in the UI and kept in Bitwarden, with **passkey** 2FA (Bitwarden) rather
  than TOTP. An API key for scripted calls is in the vault (`komodo.md` → Environment variables).

The parallel-run property SVC-1 had to engineer (alternate ports, byte-identical config) is free
here: both control planes drive the same Docker API against the same compose projects. What is *not*
free is §5 item 1 — that is what has to be true for this to be a parallel run at all.

### Phase 2 — adopt, one stack at a time (§9)

**The three missing pieces, decided and built 2026-09-15:**

- [x] **Deploy trigger:** the NAS runner calls Komodo's API. `deploy-stacks` sends `DeployStack` for a
  stack in `komodo/owned-stacks`, and never its Portainer webhook. The health gate and auto-rollback
  are unchanged. The credential is the service user `deploy-stacks`, with Execute on Stacks only
  ([#364](https://github.com/drizzelat/NAS/pull/364)). A GitHub webhook was rejected: it needs a
  public path into the LAN-only Core, and it would lose the health gate.
- [x] **Reconcile backstop:** the hourly Procedure `reconcile-owned`, running
  `BatchDeployStackIfChanged` over the owned stacks by name (F21), with `check-owned.sh` in CI
  ([#365](https://github.com/drizzelat/NAS/pull/365)).
- [x] **The self-hosting runner:** an owned `DEFER_FIRE` stack (`github-runner`) gets Komodo's
  `DeployStack` as the job's last step, after one idle check and without waiting
  ([#386](https://github.com/drizzelat/NAS/pull/386)). Before it, `fire-webhooks.sh` refused to deploy an owned `DEFER_FIRE` stack.
- [x] **Variables:** `scripts/secrets.sh komodo-vars` writes what resources.toml references, and
  `push` deploys an owned stack through Komodo ([#366](https://github.com/drizzelat/NAS/pull/366)).
- [x] ResourceSync `komodo-resources` created, its diff read (31 creates, no update or delete), then
  executed. §1 probe green afterwards, run 34975418121.

**How each adoption ran:**

1. Hash-compare the vault with Portainer's env (F20).
2. `secrets.sh komodo-vars <stack>`.
3. A PR adding the name to `komodo/owned-stacks` and the Procedure. It deploys nothing.
4. `deploy-stacks` dispatched with `komodo_dry_run`.
5. `adoption-check.sh capture`.
6. `deploy-stacks` dispatched for real, with the health gate.
7. `adoption-check.sh verify`.
8. The stack's own health.
9. Execute the sync. Its diff must be the one Procedure update.
10. A dispatched §1 probe, green before the next stack.

**Progress** (all three hosts, 2026-09-15; every deploy through the NAS runner as `deploy-stacks`):

| # | Stack | PR | Deploy run | Verdict | Own health | §1 probe |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `a1-vps-beszel-agent` | [#367](https://github.com/drizzelat/NAS/pull/367) | 34976328891 | ADOPTED (2/2) | `WebSocket connected` to the hub | 34976514141 |
| 2 | `a1-vps-ntp` | [#368](https://github.com/drizzelat/NAS/pull/368) | 34976860586 | ADOPTED (2/2) | Leap Normal, stratum 4, serving | 34976988746 |
| 3 | `a1-vps-tor-bridge` | [#369](https://github.com/drizzelat/NAS/pull/369) | 34977249092 | ADOPTED (1/1) | Bootstrapped 100%, ORPort reachable | 34977372964 |
| 4 | `a1-vps-webtunnel` | [#370](https://github.com/drizzelat/NAS/pull/370) | 34977668336 | ADOPTED (1/1) | Bootstrapped 100%, WebSocket upgrade `101` through matrix-caddy | 34977776777 |
| 5 | `a1-vps-matrix` | [#371](https://github.com/drizzelat/NAS/pull/371) | 34978309752 | ADOPTED (5/5) | synapse `/health` OK, client and federation `200`, Element `200`, bridge connected, webtunnel `101` | 34978476847 |
| 6 | `a1-vps-kuma` | [#372](https://github.com/drizzelat/NAS/pull/372) | 34978811975 | ADOPTED (1/1) | `302` on the tailnet port, no monitor errors | 34978925224 |
| 7 | `micro-vps-beszel-agent` | [#374](https://github.com/drizzelat/NAS/pull/374) | 34982838258 | ADOPTED (2/2) | `WebSocket connected`; the hub's system `VPS` is `up` | 34983232518 |
| 8 | `micro-vps-ingress` | [#376](https://github.com/drizzelat/NAS/pull/376) | 34983984493 | ADOPTED (1/1) | `nginx -t` OK, SNI allowlist live, public names `200`/`302` and LAN-only `525` from the A1; `edge-access-policy` 34984215335 green. Public sites down ~11 s (F22) | 34984399355 |
| 9 | `qdirstat` | [#379](https://github.com/drizzelat/NAS/pull/379), removed in [#380](https://github.com/drizzelat/NAS/pull/380) | 34986692523 | **deploy failed** (F24), nothing created | — | 34986877413, after removal 34988510119 |
| 10 | `beszel` | [#381](https://github.com/drizzelat/NAS/pull/381) | 34988881317 | NO CHANGE (3/3) | hub: `NAS`, `VPS`, `a1-matrix` `up` | 34989122641 |
| 11 | `homarr` | [#382](https://github.com/drizzelat/NAS/pull/382) | 34989509720 | NO CHANGE (1/1) | `200`, healthy | 34989682372 |
| 12 | `mealie` | [#383](https://github.com/drizzelat/NAS/pull/383) | 34990042899 | NO CHANGE (2/2) | `200`, both healthy | 34990209004 |
| 13 | `romm` | [#384](https://github.com/drizzelat/NAS/pull/384) | 34990520824 | NO CHANGE (2/2) | `200`, both healthy | 34990692620 |
| 14 | `books` | [#385](https://github.com/drizzelat/NAS/pull/385) | 34990979302 | NO CHANGE (1/1) | shelfmark `200`, healthy | 34991149362 |
| 15 | `games` | [#387](https://github.com/drizzelat/NAS/pull/387) | 34991431263 | NO CHANGE (2/2) | `200` | 34991602514 |
| 16 | `files` | [#388](https://github.com/drizzelat/NAS/pull/388) | 34991913170 | NO CHANGE (1/1) | `200`, healthy | 34992077723 |
| 17 | `paperless` | [#389](https://github.com/drizzelat/NAS/pull/389) | 34992347651 | NO CHANGE (3/3) | `302` to login, all healthy | 34992555617 |
| 18 | `immich` | [#390](https://github.com/drizzelat/NAS/pull/390) | 34992854919 | NO CHANGE (4/4), no F13 duplicate | `200`, `/api/server/ping` `200` | 34993018000 |
| 19 | `arr` | [#391](https://github.com/drizzelat/NAS/pull/391) | 34993332570 | NO CHANGE (10/10) | sonarr, radarr, prowlarr `302`; bazarr, questarr `200` | 34993499205 |
| 20 | `downloads` | [#392](https://github.com/drizzelat/NAS/pull/392) | 34993751961 | NO CHANGE (6/6) | qbittorrent `200`, sabnzbd `303`, gluetun healthy | 34993918583 |
| 21 | `jellyfin` | [#393](https://github.com/drizzelat/NAS/pull/393) | 34994798234 | NO CHANGE (3/3) | `/health` `200`, seerr `307` | 34994958238 |
| 22 | `conduit` | [#394](https://github.com/drizzelat/NAS/pull/394) | 34995279516 | NO CHANGE (1/1) | running | 34995448465 |
| 23 | `snowflake` | [#395](https://github.com/drizzelat/NAS/pull/395) | 34995724062 | NO CHANGE (1/1) | running | 34995886458 |
| 24 | `observability` | [#396](https://github.com/drizzelat/NAS/pull/396) | 34996128647 | NO CHANGE (5/5) | grafana `/api/health` `200` | 34996287996 |
| 25 | `kuma` | [#397](https://github.com/drizzelat/NAS/pull/397) | 34996551064 | NO CHANGE (1/1) | `302`, healthy | 34996710713 |
| 26 | `authentik` | [#398](https://github.com/drizzelat/NAS/pull/398) | 34997024879 | NO CHANGE (3/3), no F13 duplicate | auth `302` to its flow; files and immich `200` as before | 34997184068 |
| 27 | `adguard` | [#399](https://github.com/drizzelat/NAS/pull/399) | 34997492812 | NO CHANGE (1/1) | `302`; `proxy_adguard` gateway still `172.16.25.1`; DNS resolves | 34997650361 |
| 28 | `tailscale` | [#400](https://github.com/drizzelat/NAS/pull/400) | 34998677196 | NO CHANGE (1/1) | `Running`, 2 peers online; all three Servers `Ok`; public names from the A1 unchanged | 34998836257 |
| 29 | `caddy` | [#401](https://github.com/drizzelat/NAS/pull/401) | 34999190318 | NO CHANGE (2/2) | `post_deploy` reload OK; `edge-access-policy` 34999439179 green; public names from the A1 unchanged | 34999354025 |
| 30 | `github-runner` | [#402](https://github.com/drizzelat/NAS/pull/402) | 34999755180 | NO CHANGE (1/1) | deferred `DeployStack` (#386) record `success`; runner online | 34999861670 |

On the A1 and the micro VPS, every adoption recreated each of its containers once, as F15
predicted, including the stacks whose env and compose were identical. None came out as `NO CHANGE`. Both VPS clones now live at
`/etc/komodo/repos/nas`, and the running containers' `working_dir` points there.

On the micro VPS, the vault matched Portainer for `micro-vps-beszel-agent` and the running
container (F20). `micro-vps-ingress` has no env on either side, so it has no Variables. Before its
adoption, the periphery's compose rendered the stack to the same config hash as the running
container (F23), and `up --dry-run` said `Recreate`.

On the NAS every adoption came out `NO CHANGE`: its periphery hashes a stack the same way Portainer
did, so nothing restarted and no NAS adoption cost downtime (F25). `qdirstat`, order 9, failed its
first Komodo deploy and was removed instead (F24). Before each load-bearing stack (26–30),
`up --dry-run` through the periphery predicted `Running` for every container, and each extra gate
held: no F13 duplicate on `authentik`, the `adguard` gateway unchanged, the tailnet and all three
Servers up after `tailscale`, `edge-access-policy` green after `caddy`. Every vault env matched
Portainer's (F20). The leaves ran as automated chains that stopped at the first failed gate; none
stopped.

**Not covered yet:** a **new** `stacks/` folder is still created as a Portainer stack by
`fire-webhooks.sh`, because nothing creates a Stack in Komodo from CI. An owned name with no Komodo Stack
fails instead (`no Komodo Stack named …`). Until Phase 3 handles it, add a new stack's folder, its
`komodo/resources.toml` entry and its `komodo/owned-stacks` line in one PR merged with `[skip ci]`,
run `secrets.sh komodo-vars` if it has env, execute the sync, then dispatch `deploy-stacks` for it.
Phase 3 closes this gap with a filtered sync (F29).

**Next: Phase 3**, once the §1 probe has been green for two weeks from 2026-09-15.

### Phase 3 — decommission

Planned as: only after every stack is Komodo-owned and the §1 probe has been green for two weeks.
**Started 2026-09-17 instead, by decision**, two days after Phase 2, with the probe green on every
run since.

The list first written here was four bullets, and it was wrong in three ways. It removed the VPS
agents that §10 kept (F27). It had no answer for new stacks (F29). And it left out CPX-2 #4a (§7) and
the write paths §10 named. This is the list that replaced it, approved 2026-09-17.

**Rules for every PR:**

- **Work in a worktree:** `git worktree add -b <branch> ../NAS-<topic> origin/main`. Never push to
  `main` directly.
- **Gate:** after each merge, a dispatched `deploy-state-probe` and `edge-access-policy`, both green.
- **A PR that changes a stack** merges with `[skip ci]`. Then execute the ResourceSync by hand after
  reading its diff, and dispatch `deploy-stacks` for that one stack.
  - Keep clear of `:23`. `reconcile-owned` deploys a merged compose change on its own, unwatched.
  - Run the periphery's `up --dry-run` pre-flight first (F25).
  - A dispatched run never auto-rolls back, so every rollback below is a deliberate step.
- **Irreversible steps are confirmed one at a time**, when reached: deleting a repo secret, deleting
  the Portainer app or its data, and removing anything from a VPS.

**The PRs, in order:**

- [x] **1. This plan.** [#428](https://github.com/drizzelat/NAS/pull/428). F26 to F30, the 2026-09-17 decisions in §13, this list.
- [x] **2. Delete `deploy-portainer-app.yml`**, which removes F26's canary, then the repo secret
  `NAS_SSH_KEY` (F9). Close any open Portainer bump PR unmerged.
  [#429](https://github.com/drizzelat/NAS/pull/429). `NAS_SSH_KEY` deleted on 2026-09-17, together with
  three unreferenced secrets confirmed the same day: `AGE_IDENTITY`, `RENOVATE_TOKEN` and
  `PORTAINER_WEBHOOKS`. SEC-1 had recorded the first two as removed on 2026-08-22, but only their
  workflow references had gone.
- [x] **3. CPX-2 #4a (§7).** [#430](https://github.com/drizzelat/NAS/pull/430). `caddy` recreated at 09:00:20Z;
  the LAN path to Caddy was down from 09:00:03Z to 09:00:20Z (a 1 Hz sampler). Both `Post Deploy` stages succeeded;
  the `git-pull-nas.sh` host copy was installed by hand at 09:01Z and matched by sha256. The push path's reload is
  proven by PR 9, which is a real Caddyfile change.
  - `caddy` mounts `/mnt/apps/komodo/repos/nas/stacks/caddy` and the `authentik` worker mounts
    `…/stacks/authentik/blueprints`, both as directories.
  - `post_deploy` compares the container's content with the run directory's, then reloads. A
    mismatch or a failed reload fails the deploy (F28).
  - `git-pull-nas.sh` loses its reload branch in the same PR. The host copy at `/mnt/apps/scripts/` is
    replaced by hand straight after the `caddy` deploy and checked by sha256.
  - Host cron scripts stay on `/mnt/apps/scripts/nas` (§7 #4b).
- [x] **3b. The other five config mounts** (F31): [#431](https://github.com/drizzelat/NAS/pull/431). All four `Post Deploy`
  stages succeeded; `vector`, `victoriametrics`, `grafana` and `files` were each recreated once. `observability` ×4 and `files`, onto Komodo's clone
  the same way.
- [x] **4. `deploy-state-probe` off Portainer.** [#432](https://github.com/drizzelat/NAS/pull/432). Green on the runner, run 35205510677.
  - It reads through a new Komodo service user `probe-read`, with Read plus Inspect (F32 found along the way).
  - Proven by running both backends side by side, and by a fault injected on the A1.
- [x] **5. `nas-health-check` off Portainer**, through the same user. [#433](https://github.com/drizzelat/NAS/pull/433).
- [x] **6. The deploy path Komodo-only.** [#434](https://github.com/drizzelat/NAS/pull/434). Proven on 2026-09-17:
  - **Creation.** `deploy-canary` ([#435](https://github.com/drizzelat/NAS/pull/435)): the push created the Stack, refreshed the
    Procedure, deployed it and passed its health gate (run 35207342139).
  - **Removal.** [#436](https://github.com/drizzelat/NAS/pull/436): the push warned and called nothing; the probe failed on the
    orphan exactly as documented. The teardown by hand worked: filtered Procedure sync, `DestroyStack`, clear Server,
    `DeleteStack`. The probe went green again.
  - `fire-webhooks.sh`, `verify-healthy.sh`, `fire-deferred.sh` and `deploy-stacks.yml` lose every
    Portainer call. **Pass 1's `DELETE /api/stacks/{id}` is deleted, not retargeted:** a removed
    folder triggers no API call, only a warning and the teardown steps.
  - A new owned stack is created through F29's filtered syncs. It is proven end to end with a
    throwaway stack, created and then removed.
- [x] **7. `secrets.sh` Komodo-only.** `push` writes the Variables and deploys through Komodo.
- [x] **8a. Portainer off the NAS.** [#438](https://github.com/drizzelat/NAS/pull/438). Done 2026-09-17:
  - Snapshot `apps/portainer@pre-removal-2026-09-17` taken, and the app stopped. Only
    `ix-portainer-portainer-1` went away: 58 running containers became 57, and `:31015` closed.
  - `portainer-image-guard.sh` taken out of cron 8 and init script 3; cron 9 deleted.
  - The push deployed `caddy` through Komodo, and `post_deploy` reloaded without the vhost. That was
    the first Caddyfile change applied by the push path's reload.
  - `nas-health-probe.sh` re-installed without `app-config`; `nashealth` lost that sudo line.
  - Deleted, each confirmed: the repo secret `PORTAINER_API_TOKEN`, the variable `PORTAINER_URL`, and
    the TrueNAS app (`remove_ix_volumes: false`). Running containers were unchanged. The workstation's
    three Portainer credential files were shredded.
  - A ZFS snapshot of `apps/portainer`, then the app stopped. Its stacks are never touched.
  - The repo loses `stacks/portainer`, its vhost and `LAN_ONLY_HOSTS` entry
    (`ORDER_PROBE_HOST` → `komodo`), `portainer-image-guard.sh` and its cron job, and the health
    check's app comparison.
  - Then the repo secret `PORTAINER_API_TOKEN`, and the TrueNAS app itself. Its data is kept until a
    separate decision.
- [x] **8b. The VPS agents.** Done 2026-09-17, each step confirmed:
  - **The micro VPS agent:** `compose -p agent down`, `/home/ubuntu/agent` removed. MemAvailable went
    from 401 to 431 MiB, and public names from the A1 stayed `200`/`302`.
  - **The A1 agent:** the same; Synapse and Element stayed `200`.
  - **The micro VPS break-glass copy** (`/home/ubuntu/docker-compose.yml` + `nginx.conf`): removed
    after `config --hash nginx` from the Komodo clone equalled the running container's.
  - Each agent is brought down and its `/home/ubuntu/agent` removed, micro VPS first.
  - The micro VPS's `/home/ubuntu/docker-compose.yml` break-glass copy goes too, once its `config
    --hash` from the Komodo clone matches the running ingress (F23).
  - The `*-vps-agent` stacks are archived.
- [x] **9. `@lan` widened by `10.100.184.0/24`** (F30), as an edge change on its own.
  [#441](https://github.com/drizzelat/NAS/pull/441), green. **Reverted in
  [#442](https://github.com/drizzelat/NAS/pull/442)** once the VM was on `br0` (F33): the push
  deployed `caddy`, and from the ingress VPS `10.100.184.50` was aborted while `192.168.178.34` got
  `200`. Edge policy green.
- [x] **10. The runner VM** (§6, F33). Built 2026-09-17:
  - **The bridge:** `br0` over `enp2s0`, static `.111`, STP off. The first attempt rolled itself back
    after about 108 s (F33).
  - **The VM:** `runnervm`, 2 cores and 2 GiB, UEFI, autostart. Its disk is the zvol `apps/runner-vm`,
    written from the verified Ubuntu 24.04 cloud image, and its NIC is on `br0`. The seed is
    [`vm/runner-vm/`](../../../vm/runner-vm/); the key pair is in the vault.
  - **Its address:** `192.168.178.34`, a FritzBox reservation.
  - **The periphery:** `stacks/runner-vm-periphery`, hand-applied (F12). The Server `runner-vm` is
    `Ok`. A wrong allowlist gave `NotOk`, and it came back `Ok` after a VM restart.
  - **The repo:** the `[[server]]` entry, a `storage.md` row, the [runbook](runner-vm.md), and
    nightly OS updates.
  - **The gates:** the deploy-state probe requires the Server, and the health check discovers it.
    Main's probe was red for one run in between, on `NO REPO COMPOSE server runner-vm project
    periphery`, because the Server existed before its compose was merged.
- [x] **11. The runner into the VM** (F27). [#444](https://github.com/drizzelat/NAS/pull/444), 2026-09-17:
  - **The merge** went through the push path. Its run, still on the NAS runner, logged a notice for
    `github-runner` and deployed nothing.
  - **The NAS runner:** confirmed, then `DestroyStack github-runner` on `nas` with the runner idle.
    The container and `github-runner_default` were removed.
  - **Filtered syncs:** Stack `github-runner` (Server `runner-vm`, `pre_deploy`), Procedure
    `reconcile-owned` (28 names), and the new Procedure `deploy-runner` (`:53`). The pending diff held
    exactly those three; the `runner-vm` Server matched.
  - **`deploy-runner` run by hand:** `Pre Deploy` logged "not running", then pull and up on the VM.
    GitHub lists `runner-vm` online with label `nas`. No mounts, no `docker.sock`,
    `no-new-privileges`, 1 GiB.
  - **The gates:** the first probe on the VM was green, placement 30/30 with `github-runner` on
    `runner-vm`. Edge policy green.
  - **Between jobs:** proven with [#445](https://github.com/drizzelat/NAS/pull/445). Its push ran on the VM and logged a notice.
    `deploy-runner`, sent mid-job, waited 50 s and ran compose 9 s after the job ended. A comment does
    not change the container, so compose recreated nothing. The run found F34, fixed in
    [#447](https://github.com/drizzelat/NAS/pull/447) and proven again.
  - **Deleted:** `DEFER_FIRE`, `fire-deferred.sh` and the sweep's runner-last ordering. `CREATE_SKIP`
    and `RECONCILE_SKIP` had already gone in PR 6.
  - **DNS:** the VM resolves like the NAS host (F35).
- [x] **12. Close-out.** SVC-2, CPX-2 and SEC-1 closed in the review. The SEC-1 secrets table matches
  `gh secret list` on 2026-09-17. What Phase 3 got wrong is below.

#### What Phase 3 got wrong

1. **Its first list was four bullets and wrong three ways**: the VPS agents, new stacks, and CPX-2
   #4a (F27, F29). Rewritten before any PR, as twelve.
2. **Portainer still redeployed a Komodo-owned stack** (F26). Phase 2 recorded that Portainer deploys
   none of the 29. On the 2.45.1 bump, `deploy-portainer-app`'s canary redeployed `files` anyway.
3. **Komodo's Caddy reload already ran, and applied the old Caddyfile** (F28). The container mounted
   the auto-pulled clone, so the reload that worked was the cron's, up to 15 minutes later. And
   `caddy reload` exits 0 on a stale mount, so a reload alone proves nothing.
4. **Seven config mounts, not two** (F31). §3's count was right on 2026-09-08 and wrong a week later.
   Every document downstream copied the old number.
5. **Komodo's list calls stop at 50 without a word** (F32). The new probe would have passed while
   reading 50 of 77 containers.
6. **SEC-1 recorded two secrets as removed that still existed.** `AGE_IDENTITY` and `RENOVATE_TOKEN`
   lost their workflow references on 2026-08-22. The repo secrets, and `PORTAINER_WEBHOOKS`, were
   deleted on 2026-09-17. "Removed" had meant "unreferenced".
7. **§10 named two of `PORTAINER_API_TOKEN`'s four consumers.** The probe and `deploy-portainer-app`
   used it too.
8. **The runner VM's network was decided one reading short** (F30, F33). NAT won on "no change to the
   NAS's NIC". Then Incus VMs turned out to be legacy on this TrueNAS, and a classic VM reaches its own
   host only through a bridge. The decision was reversed the same day.
9. **An edge change shipped for a network nothing ever used.** PR 9 ([#441](https://github.com/drizzelat/NAS/pull/441)) widened
   `@lan` by `10.100.184.0/24` and was proven green. It was reverted ([#442](https://github.com/drizzelat/NAS/pull/442)) the same
   afternoon: the range was admitted from about 11:39Z to 12:29Z, on a bridge that was down and had no
   instances. Keeping the edge change in its own PR made the revert exact.
10. **The first bridge took the whole NAS offline for about 108 s** (F33). A new bridge got a random
    MAC, DHCP moved the NAS to `.33`, and STP was on. The 90 s check-in rollback worked as designed.
    The retry, static and with STP off, cost 2 s.
11. **The Server went live before its compose merged.** Creating `runner-vm` through the API ahead of
    PR 10 turned main's probe red for one run (`NO REPO COMPOSE`).
12. **The idle guard's first draft failed open** (F34). A `docker top` error would have counted as
    idle.
13. **A waiting runner deploy failed the job it waited for** (F34). No plan text had asked what the
    waited-on job sees.
14. **The VM would have depended on AdGuard to reach GitHub** (F35).
15. **The rule "a PR that changes a stack merges with `[skip ci]`" stopped being followed after PR 3b.**
    From PR 8a on, stack changes went through the push path, which PR 6 had proven, and each was
    gated. The rule itself was never updated. This list is where that is written down.
16. **Item 11 named `CREATE_SKIP` and `RECONCILE_SKIP` for deletion.** PR 6 had already deleted both.
17. **PR 6 deleted the workflow's reconcile pass, and two docs kept pointing at it.** The health check's
    drift advice and `renovate-pr-review.md` said to run `gh workflow run deploy-stacks.yml` with no
    input, which now deploys nothing. Both were fixed in the close-out.

**Follow-up, not Phase 3:** `micro-vps-ingress`'s inline `configs:` block becomes a real `nginx.conf`.
Recreating the ingress takes every public site down for ~11 s (F22), and `docker compose config`
doubles every `$` (F23).

**Also left after Phase 3, each a separate decision:**
- **`apps/portainer`'s data** and its snapshot `pre-removal-2026-09-17` are kept ([storage.md](../../storage.md)).
- **The Kuma monitor "Portainer UI"** is still configured in Kuma's UI.
- **The `RENOVATE_TOKEN` classic PAT** is gone from the repo but not revoked in GitHub.
- **`.bak-20260917` copies** remain on the hosts: `git-pull-nas.sh` and `nas-health-probe.sh` on the NAS,
  the netplan file on the runner VM.

---

## 9. Cutover order, per host

**The adoption procedure, for every stack, is: never stop the Portainer stack.**

SVC-1 finding #6: Portainer's stack **Stop is `docker compose down`** — containers removed, names
freed, and networks the stack defines survive only if something else holds an endpoint. "Stop it in
Portainer, then let Komodo take over" is therefore an outage per stack, and for `caddy` it is
potentially the loss of 17 network definitions. Instead: let Komodo `compose up -d` over the running
project in place (subject to §5 item 1), and simply **stop firing Portainer's webhook** for that
stack. Portainer keeps the stack row, its env and its git credential — which is what makes rollback
one click.

**Cadence: one stack at a time, no batching (decided 2026-09-08).** Every adoption gets its own
probe run, its own rollback window and its own commit, so a bad adoption is unambiguously
attributable. 29 adoptions (`qdirstat` was removed, F24). Dispatch the §1 probe on demand between them (`gh workflow run`) rather
than waiting on its cron — the gate is a green run, not a scheduled one.

**Downtime is accepted, in windows you choose.** Decided 2026-09-14: **no fixed windows.** Each
load-bearing adoption happens when there is time to watch it, one at a time; the schedule is
availability, not the calendar. The four load-bearing NAS stacks each drop something
real — LAN DNS, the tailnet, the edge, every public login — and the decision is to take that
deliberately at a time nobody depends on the service, rather than engineering the adoption to be a
guaranteed no-op. That removes a large amount of preparation from this plan. It does **not** remove
the ordering constraints below, which exist because of what breaks *other* things, not because of
downtime.

**Pre-flight, mandatory on every adoption (F13).** The adoption is a project-name match, and a
mismatch is silent on four of the stacks below. Before deploying a stack from Komodo:

```sh
# 1. Record what Portainer owns. Note the container IDs, not just the names.
docker ps -a --filter "label=com.docker.compose.project=<stack>" \
  --format '{{.ID}} {{.Names}} {{.Label "com.docker.compose.project"}}'
```

Deploy from Komodo, then assert **the same container IDs are still there and nothing new appeared**:

```sh
# 2. Any container this command lists that was not in step 1's output is a failed
#    adoption — even though Komodo reported success.
docker ps -a --format '{{.ID}} {{.Names}} {{.Label "com.docker.compose.project"}}' \
  | grep -E '<stack>'
```

**What a correct adoption looks like (measured, F15): the container IDs change exactly once, the
names and the project label do not.** The first Komodo deploy of a stack recreates every service in
it — that is the adoption — and every deploy after that reports `Running` and changes nothing. **On
the NAS the adoption itself is `NO CHANGE` (F25)**: its periphery hashes the stack like Portainer did.
So:

- IDs changed, names and project unchanged → **correct**, this is the adoption. Expect the services
  to have restarted; that is the downtime being spent.
- Nothing changed at all → the stack was already adopted. Fine, but check you deployed what you meant.
- A **new project name** appears → stop. Roll back per §10 before the duplicate accumulates state.
  On `authentik`, `immich` or `filebrowser` this is the F13 split brain and it will not announce
  itself.
- A container from a service you removed is still running → Komodo does not pass `--remove-orphans`
  (F15). Remove it by hand.

**Scripted: [`scripts/komodo/adoption-check.sh`](../../../scripts/komodo/adoption-check.sh).** Run
it from the workstation, in the repo root:

```sh
scripts/komodo/adoption-check.sh capture <stack>   # before the Komodo deploy
scripts/komodo/adoption-check.sh verify  <stack>   # after it; exit 1 = failed adoption
```

It picks the host from the stack name, as `fire-webhooks.sh` does, and runs only `docker ps -a`
there. The verdicts:

- **`ADOPTED`**: every container was recreated once, under the same names.
- **`NO CHANGE`**.
- **`PARTIAL`**: a warning.
- **`FAILED`**: a container disappeared, stopped, or appeared in another project that owns this
  stack's working directory or name.

All four were proven on the A1 eval on 2026-09-14. The failing case was a real Komodo stack under a
derived project name. Komodo reported `success=true` for it, and the script exited 1 with
`F13 duplicate`.

Gate after every single stack: the §1 probe green, plus the stack's own health check.

### A1 first — lowest blast radius, and it proves arm64

| Order | Stack | Why here |
| --- | --- | --- |
| 1 | `a1-vps-beszel-agent` | one container, no dependents, failure is a missing metrics row |
| 2 | `a1-vps-ntp` | added 2026-09-14. Two containers, no dependents in the estate |
| 3 | `a1-vps-tor-bridge` | added 2026-09-14. A leaf; a recreate costs the bridge a reconnect |
| 4 | `a1-vps-webtunnel` | added 2026-09-14. Reached through `a1-vps-matrix`'s Caddy, so take it **before** matrix: matrix's adoption recreates that Caddy, and that recreate is the one that touches webtunnel |
| 5 | `a1-vps-matrix` | self-contained: synapse, postgres, its own caddy, bridges. Nothing else depends on it except webtunnel's path |
| 6 | `a1-vps-kuma` | **last on this host** — it is the external watchdog. Breaking it blinds you to the rest of the migration, so it moves only once the host is proven |

### micro-vps second — two stacks, one of them the public front door

| Order | Stack | Why here |
| --- | --- | --- |
| 7 | `micro-vps-beszel-agent` | trivial, and it proves periphery on a 954 MiB host under real load |
| 8 | `micro-vps-ingress` | **the public entry point for the whole estate.** Take it only after §5 item 4 says the RAM headroom is real. Do not convert the inline `configs:` block in the same change |

### NAS last — 21 stacks, in dependency order

**Leaves first**, orders 9–25 (nothing depends on them; a failure is one service):
~~`qdirstat`~~ (removed 2026-09-15 instead of adopted, F24; the order numbers are kept), `beszel`, `homarr`,
`mealie`, `romm`, `books`, `games`, `files`, `paperless`, **`immich`**, `arr`, `downloads`,
`jellyfin`, `conduit`, `snowflake`, `observability`, `kuma`.

`immich` is bold because it is an **F13 silent-duplication stack**: no `container_name:`, no
published ports, `external: true` proxy networks, and Caddy addressing it by compose-generated
name. A project-name mismatch reports success and changes nothing visible, and would leave two
instances against one Postgres. `filebrowser` used to be here too; as `files` every service is
named, so it now fails loudly (F13, re-counted 2026-09-14). The pre-flight
(`scripts/komodo/adoption-check.sh`) runs on every leaf anyway. `conduit`, `snowflake` and
`observability` were added after this plan was written. `observability` is last among the leaves
because it scrapes several of them, and a gap in its metrics during their adoptions is expected
noise.

**Then the load-bearing ones**, one at a time, each with its own gate:

| Order | Stack | Specific risk |
| --- | --- | --- |
| 26 | `authentik` | every public name authenticates through it, and `files` is the outpost, never filebrowser directly (SVC-1 F4). Verify `files` **redirects** — not that it loads. Also an **F13 silent-duplication stack**, and the worst one: three unnamed services, no published ports, and Caddy pinned to `authentik-server-1`. A mismatch here is two Authentik instances on one Postgres with a green deploy. Pre-flight is not optional |
| 27 | `adguard` | the LAN's only resolver, and it pins `172.16.25.0/24`. A recreate that renumbers the gateway breaks Caddy's `allow 172.16.25.1` and silently kills Kuma's internal checks and Homarr's tiles while all 25 sites still look fine from a browser. Verify the gateway address after |
| 28 | `tailscale` | host-network, and the transport for both VPS periphery connections **and** the public path. Restarting it cuts the ingress and disconnects the agents you are migrating with. Do it deliberately, never as a side effect |
| 29 | `caddy` | **last.** The thing the estate is reachable through. `destroy_before_deploy: false` (F7), `post_deploy` reload wired and proven (§7), and `edge-access-policy.yml` green as the gate — the same gate SVC-1 used |
| 30 | `github-runner` | after everything. §6 then moves it into the VM ~~and deletes the stack~~ — kept as a Stack (F27), moved to `runner-vm` 2026-09-17 |

`portainer` (the TrueNAS app) is never adopted — it stays as a read-only console (§10, §13 decision
5). The two `*-vps-agent` stacks (F12) are never adopted either: they are Portainer's transport and
the console still needs them.

---

## 10. Rollback, and how the circularity breaks

### Per-stack rollback: one click, for the whole migration

Portainer still holds the stack, its webhook, its env and its git credential. Rolling one stack back
is firing its Portainer webhook. That stays true until Phase 3, which is why Phase 3 is gated on two
weeks of green probe.

**Since Phase 2 there is a second half, and it is not optional.** Ownership is the name in
[`komodo/owned-stacks`](../../../komodo/owned-stacks) plus the `reconcile-owned` Procedure in
`komodo/resources.toml`. Firing the Portainer webhook restores the containers. Until the name is
also gone from both, with the ResourceSync executed, the next change deploys through Komodo again,
and the hourly Procedure deploys the same project as Portainer
([komodo.md](../../services/komodo.md#adopted-stacks-phase-2)).

### Whole-migration rollback

Stop the Komodo stack; re-enable the Portainer webhook fires in `fire-webhooks.sh`; the estate is
back on the old control plane with no container ever having been stopped. Nothing in DNS, Cloudflare,
Authentik or the VPS ingress changes at any point in this plan — the same property that made SVC-1's
rollback cheap.

### The trap Phase 3 must not walk into

`fire-webhooks.sh` Pass 1 deletes a removed stack with `DELETE /api/stacks/{id}`, and SVC-1 #(also
confirmed) recorded that this ran `compose down` for project `npm`. **Deleting the Portainer stack
rows at the end would `compose down` live, Komodo-managed containers** — the project label is the
stack name either way, so Portainer does not know or care who deployed last.

**Decided 2026-09-08: Portainer stays as a read-only console.** So the Portainer stack rows are
never deleted, and the trap above is never sprung — nothing ever calls
`DELETE /api/stacks/{id}` again. What changes instead is the *write path*:

- Demote the admin user and mint a read-scoped API key via portainer-ee RBAC.
- `PORTAINER_API_TOKEN` is deleted from the repository secrets once `deploy-stacks` no longer uses
  it. `nas-health-check.yml` is its other consumer and must be retargeted to Komodo first.
- Portainer keeps three endpoints against a three-node cap, which is fine **because hosts 4 and 5
  are never added to it** (§3). That is the whole reason the cap stops mattering.
- The two `*-vps-agent` stacks (F12) stay deployed and stay pinned — a console needs its transport.
- Write into [`portainer.md`](../../services/portainer.md) in large letters: *a write-capable user
  pressing **Stop** on a stack here is a `compose down` on a live service Komodo owns.* Read-only is
  what makes the console safe, and it is the only thing that does.

The rejected alternative, recorded so it is a decision rather than an omission: deleting the
`portainer` TrueNAS app entirely would let the stack rows die with its database, so nothing could
ever run `compose down` by accident. Cleaner, and it forfeits the console. Not chosen.

> **Reversed 2026-09-17: chosen.** Portainer is removed completely: the TrueNAS app, both VPS agents
> and its vhost (F27, §8 Phase 3 PRs 8a and 8b). The trap above still holds until the app is gone,
> so the order matters:
>
> 1. **Stop the app.** Never its stacks.
> 2. **Delete the app.** That takes the stack rows with the database.
>
> Nothing calls `DELETE /api/stacks/{id}` at any point. The demoted admin and the read-scoped key
> above are not needed. Both rollback paths in this section end with PR 8a: after it, Komodo is the
> only way to deploy a stack, and rolling one back is a revert through `deploy-stacks`.

### Breaking the circularity — three layers

The replacement must be able to deploy `caddy` without being reachable only through `caddy`.

1. **Core publishes a host port.** `:9120` on the NAS, LAN-reachable, exactly inheriting Portainer's
   `:31015` bootstrap exception that [network.md](../../network.md) already documents and justifies
   ("needed *before* the proxy/DNS exist"). `komodo.example.com` is for daily use;
   `https://192.168.178.111:9120` is the path when Caddy is down. Port `9120` is free — checked
   against the ports table, per the repo's own rule.
2. **The periphery does not need Core to run compose.** The repo is on disk at
   `/mnt/apps/komodo/stacks/…`. With Core down, `cd` there and `docker compose up -d`. This is a
   *better* break-glass than Portainer's, and it is the same property that makes the VPS
   `/home/ubuntu/` copy redundant (§7 #3).
3. **`caddy` is adopted last** (§9), after the edge probe has been green under Komodo for other
   stacks, so the edge is never the experiment.

And the ordinary case: Komodo Core down ≠ estate down. Containers keep running under Docker, exactly
as they do when Portainer is down. `portainer.md` already documents that; `komodo.md` will say the
same.

---

## 11. The alternatives, costed

### Option A — Komodo (recommended, conditional on §5 item 1)

**Cost.** A new control plane *and* a new database (F3). Three periphery agents. 24 Stack resources
plus a Repo and ResourceSync TOML. `fire-webhooks.sh` and `verify-healthy.sh` rewritten against a
different API. A new auth surface (Core's UI — put it behind Authentik OIDC, which Komodo supports).
A second thing that can break at 03:00. And a v2 line that is six days old at its current release.

**Gain.** The node cap goes. Credential replay, webhook discovery and endpoint-id routing go (F10).
`deploy-portainer-app.yml` and the last root credential in CI go (F9). The repo is materialised on
every host, which kills the VPS break-glass copy and the inline-`configs:` constraint. Secrets stay
centralised, so SEC-1 step 2 is not undone. GPL, not proprietary. A console.

### Option B — per-host systemd timers, `git pull && docker compose up -d`

The finding calls it the most robust option with no control plane at all, and it is right about the
deploy path. It is also **already how the estate delivers its edge policy** — mechanism #4 plus the
reload hook is exactly this.

**Where it is cheaper than it looks.** `verify-healthy.sh` talks to
`/api/endpoints/N/docker/containers/…`, which is a thin passthrough to the Docker API. Retargeting it
at a Docker socket directly is *less* code, not more. Health checks and auto-rollback survive intact.

**Where it is expensive, and this is decisive.** **Secrets.** Portainer holds every stack's env
today, and SEC-1 step 2 deliberately took the vault key *off* CI so a single job could no longer
decrypt every stack env and every host SSH key. With no control plane, each host needs its own env —
which means the age vault, or plaintext `.env` files pushed over SSH, on three hosts. That enlarges
exactly the blast radius SEC-1 spent effort shrinking. There is no cheap fix; it is inherent to
having no central secret store.

Secondary costs: no cross-host view; deploy latency becomes the timer interval unless a webhook
receiver is added back (which is a control plane wearing a hat).

**Verdict: B is the better answer if and only if the secrets problem has an answer you like.** It is
worth an hour's thought before committing to A, because B's failure modes are all ones this estate
already understands.

### Option C — Dockge

Single-host; does not cover the VPSes; manages a directory it owns rather than a git monorepo.
Rejected in one line, as the finding says.

### Option D — do nothing

**Rejected 2026-09-08, and the reason changed.** The draft of this plan argued the cap was not a real
driver because no fourth host was planned. That is no longer true: a **Raspberry Pi as secondary
backup DNS** is planned (§14), and the runner VM (§6) is a fifth. portainer-ee's free tier covers
three. So the cap is a hard blocker on work that is already intended, and "do nothing" means either
paying for a licence or leaving the estate's single-resolver weakness open — the one
[NIT-1](../../architecture-review-2026-08-20.md#nit-1--small-items) already flagged as unredundant.

The supporting case stands on its own regardless: proprietary software in the most load-bearing
position in the estate; a version (2.39.5) that silently broke
`PUT /api/stacks/{id}/git/redeploy` and cost 16 days of unnoticed secret-sync failure; and CPX-1's
bash, of which F10 says three items die and three do not.

---

## 12. What stays click-ops afterwards

| Still click-ops | Why |
| --- | --- |
| Periphery install on each host | one-time bootstrap per host, same as `portainer_agent` today |
| Komodo Core's first admin user, git account, webhook secret | bootstrap; `KOMODO_INIT_ADMIN_*` seeds the first user, the rest is UI or API |
| Tailscale ACL grants, if outbound periphery is adopted (F6) | no API-managed tailnet config in this repo |
| Cloudflare records, AdGuard rewrites | unchanged by this; GAP-1's remainder |
| TrueNAS Incus VM creation (§6) | `virt.instance.create` is scriptable but not GitOps |

What *stops* being click-ops: which host each stack deploys to, and every stack's existence — both
become ResourceSync TOML in this repo with the same review path as everything else.

---

## 13. Decisions — settled 2026-09-08

| # | Decision | Choice | Consequence |
| --- | --- | --- | --- |
| 1 | Direction (§11) | **Komodo** | Accepts a new control plane and a new database. Option B (systemd timers) was rejected on the secrets argument alone: no central store means the age vault or plaintext `.env` on five hosts, re-enlarging exactly what SEC-1 step 2 shrank |
| 2 | Fourth host | **Yes — a Raspberry Pi as secondary backup DNS**, not yet bought | The three-node cap becomes a hard blocker rather than a hypothetical, and Option D dies (§11). Closes the single-resolver weakness NIT-1 flagged. Hardware requirement in §14 |
| 3 | Database (F3) | **MongoDB** | Komodo's own dated-backup path targets it. FerretDB would add two more pinned images whose own compose file warns updates are breaking. `/mnt/apps/komodo/backups` joins the Cloud Sync chain |
| 4 | Periphery transport (F6) | **Inbound at cutover** (Core → `:8120`) | Same direction Portainer already uses, so no tailnet ACL change is needed to start. Outbound is a later change with its own two admin-console grants |
| 5 | Core deploy path (F9) | **Self-managed Komodo Stack**, periphery outside it | `deploy-portainer-app.yml` and **`NAS_SSH_KEY` — the last root credential in CI — are deleted.** Cost accepted: Core's own upgrade is unverified, recovered by a hand-run `compose up -d` in the on-disk clone |
| 6 | Portainer afterwards (§10) | ~~**Read-only console**~~ **Removed completely (reversed 2026-09-17)** | Was: stack rows never deleted, token demoted to read scope. Now: the app, both VPS agents and the vhost go, and the stack rows die with the database. Stop the app first and never its stacks (§10). `PORTAINER_API_TOKEN` is deleted, not demoted. The console is forfeited |
| 7 | Sequencing (§6, §14) | **Komodo → runner VM → Pi** | The two new nodes are onboarded onto a control plane that has already proven itself on 24 real stacks. Leaves the DNS single point of failure open longest — accepted |
| 8 | Core authentication (§4) | **Local admin only, permanently** | No OIDC, now or later. The control plane stays independent of every stack it deploys, so a broken Authentik can never lock you out of the thing that fixes it. Komodo is the one service outside the estate's SSO; its credentials go in Bitwarden |
| 9 | Cutover cadence (§9) | **One stack at a time, no batching** | 30 adoptions (24 when decided), each with its own probe gate, rollback window and commit. Slowest, and the only shape where a bad adoption is unambiguously attributable |
| 10 | Downtime (§9) | **Accepted, in windows chosen per stack** | Removes a large amount of preparation: adoptions need not be proven no-ops first. Does **not** relax §9's ordering, which is about what breaks *other* things. **2026-09-14: no fixed windows** — each adoption is taken when there is time to watch it |
| 11 | Start gate (§0) | **Fix the probe trigger first, then gate on evidence** | `edge-access-policy.yml` moves to host-cron dispatch like #284, restoring a real 4/day cadence; then 20 green runs, a reboot, a Renovate cycle, and a proven `caddy reload`. Earliest realistic start ~2026-09-15, not a fixed date |
| 12 | Phase 3 start (§8) | **2026-09-17, overriding the two-week soak** (decided 2026-09-17) | The probe had been green on every run since Phase 2. Every Phase 3 PR still gates on a green probe and edge policy |
| 13 | Runner deploy path (§6, F27) | **A Komodo Stack deployed between jobs by its own Procedure** (decided 2026-09-17) | Automated after a one-time VM and periphery setup. `stacks/github-runner/` stays. `DEFER_FIRE` and the skip lists die because no job deploys its own runner. A job can start in the seconds between idle check and recreate — accepted |
| 14 | Runner VM network (§6, F30, F33) | ~~**`incusbr0` NAT, `@lan` widened by `10.100.184.0/24`**~~ **A classic VM bridged to the LAN through `br0` (reversed 2026-09-17)** | Was: no change to the NAS's NIC. Now: Incus VMs are legacy from TrueNAS 25.04.2, and a classic VM reaches its own host only through a bridge. The NAS's address moved onto `br0`; the widening was reverted (#442) |

---

## 14. The Raspberry Pi — requirement, not accommodation

Not bought yet (decision 2), so this plan specifies what it must be rather than working around what
it is. It is **host 5**, onboarded last (decision 7), and it is a separate project from this one — but
its requirements are set here because they are set by Komodo, not by DNS.

| Requirement | Why |
| --- | --- |
| **Pi 4 or Pi 5** | Enough RAM for periphery + AdGuard with headroom. A Pi 3 / Zero 2 W at 512 MB–1 GB is the same no-swap squeeze the micro VPS already is (§3) |
| **64-bit OS — arm64, mandatory** | `ghcr.io/moghtech/komodo-periphery:2` publishes `linux/amd64` and `linux/arm64` **only**. There is no armv7 image. A 32-bit Raspberry Pi OS cannot run a periphery agent at all, and the Pi would have to fall back to systemd-timer GitOps — a fifth deployment mechanism, against a plan whose point is to reduce them |
| **USB SSD, not an SD card** | AdGuard writes query logs continuously; SD wear is a real failure mode and a resolver that dies silently is worse than no second resolver |
| **On the tailnet** | It is how Core reaches its periphery (decision 4, inbound `:8120`). It is a *user-owned* node like the NAS, not tagged, unless there is a reason otherwise |

Two things to settle when the project starts, both out of scope here:

- **AdGuard's config is UI state** — GAP-1's remaining half. A secondary resolver whose rules drift
  from the primary is worse than none, so the two need a config sync story before the Pi is useful.
  That is a real design question and it is not answered by this plan.
- **DNS failover shape.** Whether the Pi is a second entry in DHCP, a keepalived VIP, or a manual
  fallback determines whether it helps during an unattended outage or only during an attended one.

---

## Last updated

2026-09-17 — **Done.** Phase 3 PR 11 (#444, #445, #447): the runner in its VM, deployed between jobs by `deploy-runner`; F34, F35; what Phase 3 got wrong; the close-out.

2026-09-17 — Phase 3 PR 10: the runner VM, a classic VM on `br0` (F33); decision 14 reversed and PR 9's `@lan` widening reverted (#442).

2026-09-17 — Phase 3 started ahead of its soak, by decision. F26 to F30. Portainer is removed completely (decision 6 reversed); the runner deploys between jobs through its own Procedure; the runner VM goes on NAT. §8 Phase 3 rewritten as twelve PRs.

2026-09-15 — Phase 2 done: the 21 NAS stacks adopted (#381–#402), all `NO CHANGE` (F25); the deferred Komodo path for `github-runner` (#386); new stacks are not yet created in Komodo.

2026-09-15 — Phase 2 on the NAS: `qdirstat`'s adoption failed and the stack was removed instead (F24).

2026-09-15 — Phase 2: the two micro VPS stacks adopted (#374, #376), §5 item 4 measured under a deploy, F22 and F23.

2026-09-15 — Phase 2: the deploy trigger, reconcile Procedure and Variables built (#364–#366), the ResourceSync applied, and the six A1 stacks adopted (#367–#372). F19, F20, F21.

2026-09-15
