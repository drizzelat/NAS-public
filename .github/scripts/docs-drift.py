#!/usr/bin/env python3
"""Check that the docs still describe what the stacks actually do.

AGENTS.md makes three promises about every stack in `stacks/`:

  * it has a service doc at `docs/services/<stack>.md`,
  * every LAN-exposed port is listed in the ports table in `docs/network.md`,
  * every host bind mount is a row in the mount table in `docs/storage.md`.

Two more keep the edge probe and the offsite backup from silently missing a service:

  * the hostnames and held images in `.github/estate.yml` match every list that copies them: the
    Caddyfile, the SNI allowlist, the edge probe's host lists, the Cloudflare records, network.md,
    `MERGE_SKIP_IMAGES` (both copies) and renovate.json's hold rules. A host in the Caddyfile that
    estate.yml lacks is a vhost the probe never asserts,
  * every `/mnt/data/*` bind mount is under `DATA_INCLUDE` in cloudsync-chain.sh,
    or listed as deliberately unbacked in the backup runbook's "NOT backed up" table.

Nothing enforced them, so drift only surfaced when a human went looking. This
runs in CI on pull requests (see .github/workflows/compose-validate.yml) and is
runnable by hand: `python3 .github/scripts/docs-drift.py`.

Deliberately NOT part of the nightly health check: none of this can change on
the host, only in a commit, so a pull request is the right place to catch it.

Exit 0 = no drift, 1 = drift (each finding printed as a GitHub error
annotation), 2 = the script itself could not run.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STACKS = ROOT / "stacks"
SERVICE_DOCS = ROOT / "docs" / "services"
NETWORK_DOC = ROOT / "docs" / "network.md"
STORAGE_DOC = ROOT / "docs" / "storage.md"
CADDYFILE = STACKS / "caddy" / "Caddyfile"
EDGE_WORKFLOW = ROOT / ".github" / "workflows" / "edge-access-policy.yml"
CLOUDSYNC_CHAIN = ROOT / "scripts" / "cloudsync-chain.sh"
BACKUP_DOC = ROOT / "docs" / "runbooks" / "backup-restore" / "backup.md"
ESTATE = ROOT / ".github" / "estate.yml"
NGINX_CONF = STACKS / "micro-vps-ingress" / "nginx" / "nginx.conf"
DNS_RECORDS = ROOT / "cloudflare" / "dns-records.json"
RENOVATE_REVIEW = ROOT / ".github" / "workflows" / "renovate-pr-review.yml"
RENOVATE_JSON = ROOT / "renovate.json"

# Stacks on the Oracle VPS hosts, not the NAS: only the service-doc check applies.
OFF_NAS_PREFIXES = ("micro-vps-", "a1-vps-")

findings = []


def finding(path, msg):
    findings.append((path, msg))


def section(doc, heading_re):
    """The body of the markdown section whose heading matches, up to the next
    heading of the same or higher level. Scoping the lookups to the right table
    matters: `80` and `/mnt/apps/immich` both appear elsewhere in these docs
    for unrelated reasons, so a whole-file substring search always passes."""
    text = doc.read_text()
    m = re.search(rf"^(#{{1,6}})\s*{heading_re}.*$", text, re.M)
    if not m:
        print(f"{doc.name}: no section matching /{heading_re}/ — has it been renamed?",
              file=sys.stderr)
        sys.exit(2)
    rest = text[m.end():]
    nxt = re.search(rf"^#{{1,{len(m.group(1))}}}\s", rest, re.M)
    return rest[: nxt.start()] if nxt else rest


def table_column(body, col=0):
    """First-column cells of every markdown table row in `body`, backticks and
    formatting stripped."""
    cells = set()
    for line in body.splitlines():
        line = line.strip()
        if not line.startswith("|"):
            continue
        parts = [c.strip() for c in line.strip("|").split("|")]
        if col >= len(parts):
            continue
        cell = parts[col].strip("`* ")
        if cell and not set(cell) <= set("-: "):
            cells.add(cell)
    return cells


def load_yaml(path):
    """Parse a compose file. Falls back to `docker compose config` if PyYAML is
    missing, so this runs on a bare runner as well as a dev box."""
    try:
        import yaml  # noqa: PLC0415 — optional dependency, probed on purpose
    except ImportError:
        out = subprocess.run(
            ["docker", "compose", "-f", str(path), "config", "--format", "json"],
            capture_output=True, text=True, check=False,
        )
        if out.returncode != 0:
            print(f"cannot parse {path}: no PyYAML and docker compose failed", file=sys.stderr)
            sys.exit(2)
        return json.loads(out.stdout)
    with path.open() as fh:
        return yaml.safe_load(fh)


def host_ports(compose):
    """Host ports a stack publishes to the LAN.

    Skips loopback-bound publishes (`127.0.0.1:<port>:<port>` — reachable only on
    the host, so not a LAN port) and container-only entries.
    """
    ports = set()
    for svc in (compose.get("services") or {}).values():
        for entry in svc.get("ports") or []:
            if isinstance(entry, dict):          # long syntax
                if entry.get("published") is None:
                    continue
                host_ip = str(entry.get("host_ip") or "")
                published = str(entry["published"])
            else:                                 # short syntax "[ip:]host:container[/proto]"
                parts = str(entry).split("/")[0].split(":")
                if len(parts) < 2:                # "3000" — random host port, nothing to document
                    continue
                host_ip = ":".join(parts[:-2])
                published = parts[-2]
            if host_ip.startswith("127."):
                continue
            for p in published.split("-"):        # a range documents as its endpoints
                if p.isdigit():
                    ports.add(p)
    return ports


def host_paths(compose):
    """Host bind-mount paths under /mnt (the ZFS pools) used by a stack."""
    paths = set()
    for svc in (compose.get("services") or {}).values():
        for entry in svc.get("volumes") or []:
            if isinstance(entry, dict):
                src = entry.get("source") or ""
                if entry.get("type") not in (None, "bind"):
                    continue
            else:
                src = str(entry).split(":")[0]
            if src.startswith("/mnt/"):
                paths.add(src.rstrip("/"))
    return paths


def workflow_env(path):
    """Top-level `env:` of a workflow as {name: value}, folded `>-` blocks joined.
    A regex, not PyYAML, so it runs on a bare runner like the rest of this script."""
    env, key, in_env = {}, None, False
    for line in path.read_text().splitlines():
        if not in_env:
            in_env = line.rstrip() == "env:"
            continue
        if line and not line[0].isspace():
            break                                 # next top-level key ends the block
        m = re.match(r"^  ([A-Z_][A-Z0-9_]*):\s*(.*)$", line)
        if m:
            key, val = m.group(1), m.group(2).strip()
            env[key] = "" if val in (">", ">-", "|", "|-") else val.strip("'\"")
        elif key and line.startswith("    ") and not line.strip().startswith("#"):
            env[key] = f"{env[key]} {line.strip()}".strip()
    return env


def caddy_hosts(path, domain):
    """Subdomains with a site block of their own. Only column-0 lines open a site
    block; the `*.<domain>` catch-all is the default-deny, not a service."""
    hosts = set()
    for line in path.read_text().splitlines():
        if not line.rstrip().endswith("{") or line[:1] in ("", " ", "\t", "#", "(", "{"):
            continue
        for addr in line.rstrip()[:-1].split(","):
            addr = re.sub(r"^\w+://", "", addr.strip()).split(":")[0]
            if addr.endswith("." + domain):
                name = addr[: -len(domain) - 1]
                if name != "*":
                    hosts.add(name)
    return hosts


def caddy_site_kinds(path, domain):
    """{subdomain: True if its site block imports a lan_only snippet}. A name with two blocks (the
    :443 one and its :8443 twin) is lan-only only if every block is."""
    kinds, names, lan = {}, [], False

    def close():
        for name in names:
            kinds[name] = kinds.get(name, True) and lan

    for line in path.read_text().splitlines():
        if not names:
            if not line.rstrip().endswith("{") or line[:1] in ("", " ", "\t", "#", "(", "{"):
                continue
            lan = False
            for addr in line.rstrip()[:-1].split(","):
                addr = re.sub(r"^\w+://", "", addr.strip()).split(":")[0]
                if addr.endswith("." + domain) and addr[: -len(domain) - 1] != "*":
                    names.append(addr[: -len(domain) - 1])
        elif line.startswith("}"):
            close()
            names = []
        elif re.match(r"^\s+import\s+lan_only", line):
            lan = True
    return kinds


def folded_lists(path, key):
    """Every `key: >-` folded block in a workflow, as a set of its words."""
    lines, blocks = path.read_text().splitlines(), []
    for i, line in enumerate(lines):
        m = re.match(rf"^(\s*){key}:\s*>-?\s*$", line)
        if not m:
            continue
        words = set()
        for nxt in lines[i + 1:]:
            if nxt.strip() and len(nxt) - len(nxt.lstrip()) <= len(m.group(1)):
                break
            if nxt.strip() and not nxt.strip().startswith("#"):
                words |= set(nxt.split())
        blocks.append(words)
    return blocks


def renovate_held(path):
    """Images renovate.json holds back from auto-merge for every update type."""
    held = set()
    for rule in json.loads(path.read_text()).get("packageRules", []):
        if (rule.get("automerge") is False and "needs-manual-review" in rule.get("labels", [])
                and "matchUpdateTypes" not in rule):
            held |= {re.sub(r"^docker\.io/(library/)?", "", n) for n in rule.get("matchPackageNames", [])}
    return held


def check_estate(env, domain):
    """Every consumer of .github/estate.yml agrees with it, in both directions."""
    estate = load_yaml(ESTATE)
    cf = set(estate["hosts"]["public"]["cloudflare"])
    direct = set(estate["hosts"]["public"]["direct"])
    lan = set(estate["hosts"]["lan_only"])
    public = cf | direct
    held = set(estate["held_images"])

    def same(path, what, have, want):
        for n in sorted(want - have):
            finding(path, f"{what}: {n} is in .github/estate.yml but not here")
        for n in sorted(have - want):
            finding(path, f"{what}: {n} is here but not in .github/estate.yml")

    edge = ".github/workflows/edge-access-policy.yml"
    for var, want in (("PUBLIC_HOSTS", public), ("CF_ONLY_HOSTS", cf), ("DIRECT_PUBLIC_HOSTS", direct),
                      ("GREY_CLOUD_HOSTS", direct), ("LAN_ONLY_HOSTS", lan)):
        same(edge, var, set(env.get(var, "").split()), want)

    kinds = caddy_site_kinds(CADDYFILE, domain)
    same("stacks/caddy/Caddyfile", "public vhosts (no lan_only import)",
         {n for n, is_lan in kinds.items() if not is_lan}, public)
    same("stacks/caddy/Caddyfile", "lan_only vhosts", {n for n, is_lan in kinds.items() if is_lan}, lan)

    keys = re.findall(r'^\s*"([01]):([a-z0-9-]+)\.' + re.escape(domain) + '"', NGINX_CONF.read_text(), re.M)
    nginx = "stacks/micro-vps-ingress/nginx/nginx.conf"
    same(nginx, 'SNI map "1:" (every public host)', {n for f, n in keys if f == "1"}, public)
    same(nginx, 'SNI map "0:" (non-Cloudflare sources)', {n for f, n in keys if f == "0"}, direct)

    records = {r["name"]: r for r in json.loads(DNS_RECORDS.read_text()) if r.get("type") in ("A", "AAAA", "CNAME")}
    for name in sorted(public | lan):
        rec = records.get(f"{name}.{domain}")
        if name in direct and not (rec and rec.get("proxied") is False):
            finding("cloudflare/dns-records.json",
                    f"{name} is a direct (gray-cloud) host in .github/estate.yml but has no DNS-only record; the proxied wildcard would cover it")
        elif name not in direct and rec and rec.get("proxied") is not True:
            finding("cloudflare/dns-records.json",
                    f"{name} has a DNS-only record, which publishes the origin IP, but it is not a direct host in .github/estate.yml")

    access = section(NETWORK_DOC, r"Access control")
    for name in sorted(public | lan):
        if f"`{name}`" not in access:
            finding("docs/network.md", f"the Access control section never names `{name}`, a host in .github/estate.yml")

    for blk in folded_lists(RENOVATE_REVIEW, "MERGE_SKIP_IMAGES") or [set()]:
        same(".github/workflows/renovate-pr-review.yml", "MERGE_SKIP_IMAGES", blk, held)
    same("renovate.json", "held packageRules (automerge false, needs-manual-review, no matchUpdateTypes)",
         renovate_held(RENOVATE_JSON), held)


def data_include(path):
    m = re.search(r"^DATA_INCLUDE\s*=\s*\(([^)]*)\)", path.read_text(), re.M)
    if not m:
        print(f"{path.name}: no DATA_INCLUDE tuple — has it been renamed?", file=sys.stderr)
        sys.exit(2)
    return set(re.findall(r"[\"']([^\"']+)[\"']", m.group(1)))


def unbacked_datasets(body):
    """Datasets named in the first column of the "NOT backed up" table."""
    names = set()
    for line in body.splitlines():
        if line.strip().startswith("|"):
            first = line.strip().strip("|").split("|")[0]
            names |= {n.rstrip("/*") for n in re.findall(r"`([^`]+)`", first)}
    return names


def under(dataset, prefixes):
    return any(dataset == p or dataset.startswith(p + "/") for p in prefixes)


def main():
    if not STACKS.is_dir():
        print("no stacks/ directory — wrong working directory?", file=sys.stderr)
        return 2

    documented_ports = table_column(section(NETWORK_DOC, r"Exposed ports"))
    documented_paths = table_column(section(STORAGE_DOC, r"Shares / bind mounts"))
    backup_covered = data_include(CLOUDSYNC_CHAIN) | unbacked_datasets(
        section(BACKUP_DOC, r"What is intentionally NOT backed up"))

    env = workflow_env(EDGE_WORKFLOW)
    domain = env.get("DOMAIN")
    if not domain:
        print(f"{EDGE_WORKFLOW.name}: no DOMAIN in env", file=sys.stderr)
        return 2
    check_estate(env, domain)

    for stack_dir in sorted(p for p in STACKS.iterdir() if p.is_dir()):
        name = stack_dir.name
        compose_path = stack_dir / "docker-compose.yml"
        if not compose_path.is_file():
            continue

        doc = SERVICE_DOCS / f"{name}.md"
        if not doc.is_file():
            finding(
                f"stacks/{name}/docker-compose.yml",
                f"no service doc — create docs/services/{name}.md from docs/services/_template.md",
            )

        if name.startswith(OFF_NAS_PREFIXES):
            continue

        compose = load_yaml(compose_path)
        if not isinstance(compose, dict):
            continue

        for port in sorted(host_ports(compose)):
            if port not in documented_ports:
                finding(
                    f"stacks/{name}/docker-compose.yml",
                    f"publishes LAN port {port}, which is not in the ports table in docs/network.md",
                )

        for path in sorted(host_paths(compose)):
            # A documented ancestor covers its children. Pool roots do NOT count — they are in
            # the table only as whole-pool views.
            ancestors = {path} | {
                str(p) for p in Path(path).parents if len(p.parts) > 3  # /mnt/<pool>/<x>
            }
            if not (ancestors & documented_paths):
                finding(
                    f"stacks/{name}/docker-compose.yml",
                    f"bind-mounts {path}, which is not in the mount table in docs/storage.md",
                )
            if path.startswith("/mnt/data/"):
                dataset = path[len("/mnt/"):]
                if not under(dataset, backup_covered):
                    finding(
                        f"stacks/{name}/docker-compose.yml",
                        f"bind-mounts {path}, which is neither under DATA_INCLUDE in "
                        f"scripts/cloudsync-chain.sh nor in the NOT-backed-up table in "
                        f"docs/runbooks/backup-restore/backup.md",
                    )

    # A removed stack's doc goes with it (AGENTS.md), so flag the leftovers.
    for doc in sorted(SERVICE_DOCS.glob("*.md")):
        if doc.name in ("README.md", "_template.md"):
            continue
        if not (STACKS / doc.stem).is_dir():
            finding(
                f"docs/services/{doc.name}",
                f"documents '{doc.stem}', which has no stacks/{doc.stem}/ — remove it",
            )

    for path, msg in findings:
        print(f"::error file={path}::{msg}")
    print(f"\ndocs drift: {len(findings)} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
