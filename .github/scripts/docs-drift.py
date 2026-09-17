#!/usr/bin/env python3
"""Check that the docs still describe what the stacks actually do.

AGENTS.md makes three promises about every stack in `stacks/`:

  * it has a service doc at `docs/services/<stack>.md`,
  * every LAN-exposed port is listed in the ports table in `docs/network.md`,
  * every host bind mount is a row in the mount table in `docs/storage.md`.

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

# Stacks on the Oracle VPS hosts, not the NAS: only the service-doc check applies.
OFF_NAS_PREFIXES = ("micro-vps-", "a1-vps-")

findings = []


def finding(path, msg):
    findings.append((path, msg))


def section(doc, heading_re):
    """The body of the markdown section whose heading matches, up to the next
    heading of the same or higher level. Scoping the lookups to the right table
    matters: `80` and `/mnt/apps/paperless` both appear elsewhere in these docs
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

    Skips loopback-bound publishes (`127.0.0.1:42375:2375` — reachable only on
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


def main():
    if not STACKS.is_dir():
        print("no stacks/ directory — wrong working directory?", file=sys.stderr)
        return 2

    documented_ports = table_column(section(NETWORK_DOC, r"Exposed ports"))
    documented_paths = table_column(section(STORAGE_DOC, r"Shares / bind mounts"))

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

    # Service docs are allowed to outlive a stack only if the stack is gone on
    # purpose; AGENTS.md says to remove/archive the doc, so flag the leftovers.
    for doc in sorted(SERVICE_DOCS.glob("*.md")):
        if doc.name in ("README.md", "_template.md"):
            continue
        if not (STACKS / doc.stem).is_dir():
            finding(
                f"docs/services/{doc.name}",
                f"documents '{doc.stem}', which has no stacks/{doc.stem}/ — remove or archive it",
            )

    for path, msg in findings:
        print(f"::error file={path}::{msg}")
    print(f"\ndocs drift: {len(findings)} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
