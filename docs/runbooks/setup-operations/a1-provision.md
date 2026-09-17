# Runbook: Provision an Oracle Ampere A1 as a tailnet Komodo Server

Build a fresh **Oracle Cloud Ampere A1** (arm64, always-free) host, harden it, put it on the
tailnet, and add it to Komodo as a **Server** with its own periphery — the reusable foundation the
[Matrix deploy](matrix-deploy.md) builds on. Stop after whichever phase you need; that runbook
picks up from here.

> **Status: PLAN** (reusable guide). Values in `<ANGLE_BRACKETS>` are filled in as you provision.
> The A1 always-free allocation is a **single pool of up to 4 OCPU / 24 GB** — you can run one big
> instance or split it into several small ones. Plan the split before you start (see the sizing note
> in Phase 1).

## Provisioned instance (as-built) — `a1-matrix`

First run of this runbook, 2026-07-08. This host is provisioned and is the Komodo Server
`a1-vps` (a Portainer node, endpoint 5, until 2026-09-17). Besides its periphery and Tailscale it runs the `a1-vps-*` stacks: its
original role, the [Matrix host](matrix-deploy.md), plus the external
[Uptime Kuma](../../services/a1-vps-kuma.md) watchdog, a [Beszel agent](../../services/a1-vps-beszel-agent.md),
two Tor bridges ([obfs4](../../services/a1-vps-tor-bridge.md), [WebTunnel](../../services/a1-vps-webtunnel.md)) and an
[NTP Pool server](../../services/a1-vps-ntp.md). The Komodo Phase 0 evaluation ran here until 2026-09-15
([komodo-migration](komodo-migration.md)). The public ingress stays on the AMD micro
(the once-considered plan to move ingress onto this A1 was dropped). The node was **renamed
`a1-ingress` → `a1-matrix`** to match its role — on the host,
`sudo tailscale up --hostname=a1-matrix --accept-routes --ssh`, then re-approve in the Tailscale
admin console if prompted. Connections use the tailnet IP `100.64.0.13` (Komodo periphery) and
`100.64.0.11` (NAS backup target), not the hostname, so the rename is cosmetic — nothing else
breaks.

| Field | Value |
| --- | --- |
| Instance | `instance-20260708-0942`, `VM.Standard.A1.Flex` |
| Account / region | **Pay-As-You-Go**, home region. Created within the always-free A1 cap, so **$0** expected — verify in Cost Analysis after ~24h (a fresh instance reads $0 regardless). |
| Shape | **2 OCPU / 12 GB** (resized in place 2026-07-08 from the as-built 1 OCPU / 5.8 GB) for its role, the [Matrix host](matrix-deploy.md) (Synapse + Postgres + bridges). Not ingress despite the hostname; the public front door stays on the AMD micro. |
| Image | Ubuntu 24.04 LTS **aarch64**, `-oracle` kernel flavour (patched and rebooted automatically, see OS updates below) |
| Storage | 46.6 GB boot (`/dev/sda`) + **100 GB block volume** (`/dev/sdb`) mounted `/opt/matrix` **by UUID** (added 2026-07-08 for Matrix data; see the as-built note on `oraclevda`) |
| Public IP | `198.51.100.20` |
| Tailnet IP | `100.64.0.13` (hostname `a1-matrix`, `--accept-routes`, **`--accept-dns=false`** — see deviation) |
| SSH | `ssh -i secrets/ssh/ssh-a1-key.key -p 2222 ubuntu@198.51.100.20` — **port 2222** (moved 2026-07-08), key-only, public IP only |
| SSH key | vault `secrets.enc/ssh/ssh-a1-key.key.age` → `unlock` restores to `secrets/ssh/` ([secret-sync.md](secret-sync.md)) |
| Firewall (host) | iptables `ACCEPT` 80/443/2222 (and 22, now unused) before the Oracle `REJECT`, persisted via `netfilter-persistent` |
| Firewall (cloud) | Security List **shared with the micro's subnet** → 80/443/22/2222 allowed, plus 4443/9443 for the Tor bridge and 123/udp for the [NTP server](../../services/a1-vps-ntp.md) (Docker DNATs those, so they need no host rule) |
| Hardening | `PasswordAuthentication no` (image default) + `PermitRootLogin no` via `/etc/ssh/sshd_config.d/99-hardening.conf`; **fail2ban** active; **rpcbind** masked |
| OS updates | automatic every night: `unattended-upgrades` at 22:15 UTC (security, `-updates`, Docker 29.x), reboot at **23:15 UTC** when one is required — [os-updates.md](os-updates.md) |
| Docker | 29.x + Compose v5 (arm64, docker.com apt repo), enabled at boot; point releases install automatically, majors are held; `ubuntu` **not** in `docker` group (`sudo docker`) |
| Tailscale | native pkg, updates itself (`AutoUpdate.Apply: true`) |
| Komodo periphery | version-pinned in repo [`stacks/a1-vps-periphery/`](../../../stacks/a1-vps-periphery/) (source of truth), listening tailnet-only on `100.64.0.13:8120`, the Komodo Server `a1-vps`. Applied over SSH, never by Komodo — see [a1-vps-periphery](../../services/a1-vps-periphery.md). The Portainer agent it replaced was removed on 2026-09-17 |

**As-built notes (resolved during the Matrix build, 2026-07-08):**

- **SSH moved to 2222** (was port 22). Ubuntu 24.04 ssh is **socket-activated** — set the port in
  `ssh.socket` (drop-in `/etc/systemd/system/ssh.socket.d/override.conf`), **not** `sshd_config Port`
  (Phase 3 below now says so). Use explicit `ListenStream=0.0.0.0:2222` **and**
  `ListenStream=[::]:2222`; a bare `ListenStream=2222` binds IPv6-only and refuses all IPv4/public
  SSH. See [matrix-deploy.md](matrix-deploy.md) Deployment log for the full gotcha.
- **Resized to 2 OCPU / 12 GB** in place (was 1 OCPU / 5.8 GB) — reboot survived it.
- **100 GB block volume added**, mounted `/opt/matrix` for Matrix data (attach is a console action).
- **`tailscale set --accept-dns=false`** — MagicDNS was hijacking system DNS to a dead resolver and
  breaking `docker pull` + all public lookups. NAS is reached by IP, so MagicDNS isn't needed.
- **`/opt/matrix` mounts by UUID** (since 2026-09-16; it was `/dev/oracleoci/oraclevda`). Oracle's
  udev rule gives `oraclevda` to the boot disk **and** the data volume, and the link follows
  whichever udev event ran last. From 2026-09-01 it pointed at the boot disk, so a reboot could
  have left Docker down. See [os-updates.md](os-updates.md#prerequisite-mount-data-volumes-by-uuid).

## Why A1 over the current AMD micro

| | AMD micro (`instance-20260417-1014`) | Ampere A1 |
| --- | --- | --- |
| RAM | 954 MiB, **no swap** | up to 24 GB (free), swap as configured |
| vCPU | 2 (x86_64) | up to 4 OCPU (arm64) |
| Cost | always-free | always-free (separate allocation) |
| Headroom | none — can't host anything but the featherweight nginx stream | comfortable for Matrix + Postgres + bridges |

The micro is fine as a pure TCP stream-forwarder but has zero room to grow. The A1 is the same
price with 25× the RAM — the natural home for the Matrix homeserver
([matrix-deploy.md](matrix-deploy.md)), which is what this host is for.

## Phase 0 — Prerequisites

| You need | Notes |
| --- | --- |
| Oracle Cloud account with A1 capacity | Separate always-free pool from the AMD micro. Capacity is often region-limited — see the Phase 1 fallback. |
| SSH key | Reuse `secrets/ssh/ssh-key-vps.key` or mint a dedicated key and store it in the age vault ([secret-sync.md](secret-sync.md)). |
| Tailscale admin access | To approve the new node. |
| Komodo reachable | Core on the NAS, `https://komodo.example.com` (LAN-only), and the admin API key from the vault. |

## Phase 1 — Create the instance

1. **Launch.** Oracle Cloud → Compute → Instances → Create.
   - Shape: **Ampere A1 Flex**. Size for the workload out of the shared 4 OCPU / 24 GB pool:
     - **Ingress only** (nginx stream + agent): **1 OCPU / 6 GB** is generous — it barely uses
       anything.
     - **Matrix host** ([matrix-deploy.md](matrix-deploy.md)): **2 OCPU / 12 GB** (Synapse +
       Postgres + a few bridges fit with headroom).
   - Image: **Ubuntu 24.04 LTS (aarch64)**.
   - Boot volume: default (~47 GB) is fine for the OS. Put heavy service data on a block volume
     (Phase 2, optional — skip for ingress-only).
   - Add your **SSH public key**.
   - **Capacity fallback:** if launch fails with *"Out of host capacity"* (common for A1), retry in
     another AD/region, script a capacity-notification poll, **or** provision a **Hetzner CAX11**
     (arm, 2 vCPU / 4 GB, ~€3.8/mo) — every phase below is identical (arm64, Ubuntu, Docker,
     Tailscale).

2. **(Optional) Attach a block volume for data.** Skip for ingress-only (the nginx stream is
   stateless). For Matrix or anything with a real dataset, create a volume (always-free includes up
   to 200 GB), attach paravirtualized, then:
   ```sh
   lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS     # the new disk: right size, no FSTYPE, e.g. sdb
   sudo mkfs.ext4 /dev/sdX
   sudo mkdir -p /opt/<app>
   echo "UUID=$(sudo blkid -s UUID -o value /dev/sdX) /opt/<app> ext4 defaults,_netdev,nofail,x-systemd.required-by=docker.service,x-systemd.before=docker.service 0 2" | sudo tee -a /etc/fstab
   sudo systemctl daemon-reload
   sudo mount /opt/<app>
   ```
   Mount **by UUID**, never by `/dev/oracleoci/oraclevd*` or `/dev/sdX`: on `a1-matrix` the boot
   disk and the data volume both carry `oraclevda`, and the link changes between boots.
   The `x-systemd.*` options keep Docker from starting if the volume fails to mount — otherwise
   containers silently write to the boot volume under the empty mountpoint. `nofail` still lets
   the host boot so you can SSH in and fix it.

## Phase 2 — Firewall (BOTH layers)

Oracle Ubuntu images ship a restrictive host **iptables** *and* the cloud **Security List / NSG**.
Ports must be open in **both** — opening only one is the classic Oracle gotcha (it bit the micro).

1. **Cloud Security List** (VCN → Security Lists → default → ingress rules) — allow the ports the
   host will actually serve. For an ingress/general node:
   - TCP `<SSH_PORT>` (non-standard, key-only — the micro uses `2222`)
   - TCP `80`, TCP `443` (only if this host serves public HTTP/S — ingress or Caddy)
2. **Host iptables** — persist the same set (Oracle images use `netfilter-persistent`):
   ```sh
   sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT
   sudo iptables -I INPUT -p tcp --dport 80  -j ACCEPT
   sudo iptables -I INPUT -p tcp --dport <SSH_PORT> -j ACCEPT
   sudo netfilter-persistent save
   ```
   > `8120` (Komodo periphery) is **not** opened here — it binds the tailnet IP only (Phase 5).

## Phase 3 — Harden SSH

1. `PasswordAuthentication no` + `PermitRootLogin no` in
   `/etc/ssh/sshd_config.d/99-hardening.conf`. The **port** does not go there: Ubuntu 24.04's ssh
   is socket-activated, so set it in a `ssh.socket` drop-in
   (`/etc/systemd/system/ssh.socket.d/override.conf`) — an empty `ListenStream=` to clear the
   default, then **both** `ListenStream=0.0.0.0:<SSH_PORT>` and `ListenStream=[::]:<SSH_PORT>`. A
   bare `ListenStream=<SSH_PORT>` binds IPv6 only and refuses every IPv4 client.
   `sudo systemctl daemon-reload && sudo systemctl restart ssh.socket`, and keep your current
   session open until a new one works on the new port from an external IPv4 address.
2. Install **fail2ban** — the micro lacks it; don't repeat that gap:
   ```sh
   sudo apt update && sudo apt install -y fail2ban
   ```
3. Mask rpcbind if present (public `:111`): `sudo systemctl mask --now rpcbind rpcbind.socket`.

## Phase 4 — Docker + Tailscale

1. **Docker + Compose** (arm64):
   ```sh
   curl -fsSL https://get.docker.com | sudo sh
   sudo systemctl enable --now docker
   ```
   Leave `ubuntu` **out** of the `docker` group (use `sudo docker`) — matches the micro/NAS
   convention.
2. **Join the tailnet** (native package):
   ```sh
   curl -fsSL https://tailscale.com/install.sh | sudo sh
   sudo tailscale up --accept-routes --ssh      # visit the printed URL to authenticate
   sudo tailscale ip -4                          # -> <A1_TAILNET_IP>
   ```
   `--accept-routes` picks up the NAS subnet route (`192.168.178.0/24`). Approve the new node in the
   Tailscale admin console. Verify: `tailscale ping nas` (NAS peer = `100.64.0.11`).
3. **Automatic OS updates.** Ubuntu installs security updates by default but never reboots, and
   skips `-updates` and Docker. Add the three files from [os-updates.md](os-updates.md#what-runs)
   with an update and reboot slot no other host uses.

## Phase 5 — Add to Komodo as a Server

The periphery is **applied over SSH, never by Komodo** — Komodo deploys stacks *through* it, so it
must never be torn down by its own deploys (plan F12). Bind it to the **tailnet IP only**, never
public.

1. **Periphery compose** — the repo is the source of truth:
   [`stacks/a1-vps-periphery/`](../../../stacks/a1-vps-periphery/) for this host. For another host,
   add a new `stacks/<host>-periphery/` copy with that host's tailnet IP as `PERIPHERY_BIND_IP`, and
   the same version pin as Core. Write Core's public key to `/etc/komodo/keys/core.pub` **before**
   the first start, then apply it as in
   [a1-vps-periphery → Applying a change](../../services/a1-vps-periphery.md#applying-a-change):

   ```sh
   sudo ss -tlnp | grep 8120               # confirm bound to <A1_TAILNET_IP>, not 0.0.0.0
   ```
2. **Register in Komodo**: a `[[server]]` entry in `komodo/resources.toml` with address
   `https://<A1_TAILNET_IP>:8120` and `auto_prune = false`, merged, then the ResourceSync executed
   after reading its diff. The Server should show **`Ok`**.

## Phase 6 — Verify

- [ ] SSH works on `<SSH_PORT>` with the key; password auth refused.
- [ ] `sudo tailscale status` shows the node online and `tailscale ping nas` succeeds.
- [ ] `sudo docker ps` shows `komodo-periphery` up; `8120` bound to `<A1_TAILNET_IP>` only.
- [ ] The Server is **`Ok`** in Komodo.
- [ ] Reboot the host → periphery + docker return (`restart: unless-stopped` + docker enabled at boot).

## What this host is now

A hardened, tailnet-joined Docker host that Komodo can deploy stacks to. From here:

- **Deploy Matrix on it** → [matrix-deploy.md](matrix-deploy.md) — this is what `a1-matrix` is
  for; its Phase 1 is this runbook (already done here), so continue from its Phase 2.

> **Record the facts.** When you actually provision, capture `<A1_PUBLIC_IP>`, `<A1_TAILNET_IP>`,
> `<SSH_PORT>`, and the instance name in [docs/network.md](../../network.md) → Cloud hosts as part
> of whichever follow-on runbook you run — don't leave them only here.

## Last updated

2026-09-17 — Phase 5 adds a Komodo periphery instead of a Portainer agent (SVC-2 Phase 3).

2026-09-11
